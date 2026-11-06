-- Experimental component/segment scheduler. Submit one file at a time.
-- No stop/busy API: only not-yet-submitted files can be cancelled.
local Audio={}
Audio.__index=Audio
local VOICE_GAP=.350
local ERROR_TONE_SECONDS=.120
local EPSILON=.00004
local WHOLE_KEYS={"nbLearning","nbLearningNumbered","nbShort","nbShortNumbered","nbExpert","nbExpertNumbered",
  "enLearning","enLearningNumbered","enShort","enShortNumbered","enExpert","enExpertNumbered"}

local function finite(v) return type(v)=="number" and v==v and v~=math.huge and v~=-math.huge end
local function integer(v) return finite(v) and v==math.floor(v) end
local function field(value,key) if type(value)=="table" then return value[key] end end
local function catalogHeader(catalog)
  if type(catalog)~="table" or catalog.schema~=3 then return nil,"Unsupported audio catalog" end
  return true
end
local function clipInfo(catalog,hash)
  if type(hash)~="string" or hash=="" then return nil,"Missing audio clip reference" end
  local clips=field(catalog,"clips")
  if type(clips)~="table" then return nil,"Invalid audio clips table" end
  local clip=clips[hash]
  if type(clip)~="table" then return nil,"Missing audio clip: "..hash end
  if type(clip.file)~="string" or not clip.file:match("^audio/[%w_/-]+%.wav$")
    or clip.file:find("//",1,true) then return nil,"Invalid audio filename: "..hash end
  if not finite(clip.duration) or clip.duration<=0 then return nil,"Invalid audio duration: "..hash end
  return clip
end
-- Startup work stays constant in library size. deep=true is offline catalog QA;
-- selected clips and actual WAV headers are checked again immediately before use.
function Audio.validateCatalog(catalog,deep)
  local ok,error=catalogHeader(catalog)
  if not ok then return nil,error end
  for _,name in ipairs({"programs","clips","numbers","common"}) do
    if type(catalog[name])~="table" or next(catalog[name])==nil then return nil,"Invalid audio "..name.." table" end
  end
  local function reference(hash) return type(hash)=="string" and hash~="" and type(catalog.clips[hash])=="table" end
  for _,language in ipairs({"nb","en"}) do
    local numbers,common=catalog.numbers[language],catalog.common[language]
    if type(numbers)~="table" or next(numbers)==nil then return nil,"Invalid figure-number audio: "..language end
    if type(common)~="table" then return nil,"Invalid common audio: "..language end
    if not reference(common.ready) or not reference(common.audioError) then return nil,"Missing common audio: "..language end
  end
  if deep~=true then return true end
  for hash in pairs(catalog.clips) do
    local clip,clipError=clipInfo(catalog,hash)
    if not clip then return nil,clipError end
  end
  local function sequence(ref)
    if reference(ref) then return true end
    if type(ref)~="table" or #ref==0 then return false end
    for i,k in ipairs(ref) do if not reference(k) then return false end end
    return true
  end
  local function entry(value)
    return type(value)=="table" and sequence(value.nbLearning) and sequence(value.enLearning)
      and (value.title==nil or reference(value.title))
      and (value.title_nb==nil or reference(value.title_nb))
  end
  for programId,program in pairs(catalog.programs) do
    if type(programId)~="string" or programId=="" or type(program)~="table" or next(program)==nil then return nil,"Invalid audio program" end
    for stepId,value in pairs(program) do
      if type(stepId)~="string" or stepId=="" or not entry(value) then return nil,"Invalid audio point" end
      if value.variants~=nil then
        if type(value.variants)~="table" then return nil,"Invalid audio variants: "..stepId end
        for variantId,variant in pairs(value.variants) do
          if type(variantId)~="string" or variantId=="" or not entry(variant) or variant.variants~=nil then return nil,"Invalid audio variant: "..stepId end
        end
      end
    end
  end
  for _,language in ipairs({"nb","en"}) do
    for number,hash in pairs(catalog.numbers[language]) do
      if not integer(number) or number<1 or not reference(hash) then return nil,"Invalid figure-number audio: "..language end
    end
    for name,hash in pairs(catalog.common[language]) do
      if type(name)~="string" or not reference(hash) then return nil,"Invalid common audio: "..language end
    end
  end
  return true
end
local function rootPath(root)
  assert(type(root)=="string" and root~="","Audio requires an absolute script root")
  return root:sub(-1)=="/" and root or root.."/"
end
local function validator(root,provided)
  if type(provided)=="function" then return provided end
  if type(provided)=="table" and type(provided.inspect)=="function" then return provided.inspect end
  local ok,chunk=pcall(loadfile,root.."lib/wav.lua")
  if not ok or type(chunk)~="function" then return nil end
  local loaded,module=pcall(chunk)
  if loaded and type(module)=="table" and type(module.inspect)=="function" then return module.inspect end
end
function Audio.new(root,catalog,notify,inspect)
  root=rootPath(root)
  return setmetatable({root=root,catalog=catalog,notify=notify or function() end,inspect=validator(root,inspect),
    active=nil,inFlight=nil,tail=0,status="idle",pauseActive=false,awaitingManual=false,
    pending=false,waitingForPrevious=false,waitingUntil=nil,errorTone=false,lastError=nil,lastNow=nil,requestId=0,
    metrics={calls=0,files=0,segments=0,fileChecks=0,errors=0,cancellations=0,
      updates=0,maxUpdateInterval=0,maxUpdateCost=0}},Audio)
end
function Audio:_notify(kind,message) pcall(self.notify,kind,message) end
function Audio:_clock(now)
  if not finite(now) then now=os.clock() end
  if self.lastNow and now<self.lastNow then
    if now<self.lastNow-.5 then
      if self.inFlight then
        self.inFlight.expectedEnd=now+math.max(0,self.inFlight.expectedEnd-self.lastNow)
        self.tail=self.inFlight.expectedEnd
      else self.tail=now end
      self.active=nil;self.errorTone=false;self.awaitingManual=true
    else now=self.lastNow end
  end
  self.lastNow=now
  return now
end
function Audio:_expire(now)
  -- This is a duration estimate, not evidence that the Ethos/global FIFO is free.
  if self.inFlight and now>=self.inFlight.expectedEnd then self.inFlight=nil end
end
function Audio:_state(now)
  local active,flight=self.active,self.inFlight
  self.pending=active~=nil and active.item<=#active.sequence
  self.waitingForPrevious=self.pending and flight~=nil and flight.requestId~=active.requestId
  self.waitingUntil=self.pending and math.max(active.waitUntil,flight and flight.expectedEnd or now)
    or (flight and flight.expectedEnd or nil)
  if self.pauseActive or self.awaitingManual then self.status="paused"
  elseif self.lastError then self.status="error"
  elseif active then self.status=self.waitingForPrevious and "waiting" or "playing"
  elseif flight then self.status="finishing"
  else self.status="idle" end
end
function Audio:stop(reason)
  local now=self:_clock()
  self:_expire(now)
  if self.active then self.metrics.cancellations=self.metrics.cancellations+1 end
  self.active=nil;self.errorTone=false;self.stopReason=reason
  self:_state(now)
  -- The one already submitted segment is deliberately retained, not stopped.
end
function Audio:pause(active,now)
  now=self:_clock(now);self:_expire(now)
  active=active==true
  if active==self.pauseActive then return end
  self.pauseActive=active;self.awaitingManual=true
  self:stop(active and "pause-source" or "pause-source-released")
end
function Audio:_fail(message)
  self:stop("audio-error")
  self.lastError=tostring(message);self.metrics.errors=self.metrics.errors+1
  self.awaitingManual=self.pauseActive;self.errorTone=not self.pauseActive
  self:_state(self.lastNow)
  self:_notify("error",self.lastError)
  return false,self.lastError
end
function Audio:_clip(hash) return clipInfo(self.catalog,hash) end
function Audio:_sequence(programId,step,profile)
  local valid,catalogError=catalogHeader(self.catalog)
  if not valid then return nil,catalogError end
  if type(programId)~="string" then return nil,"Missing program ID" end
  if type(step)~="table" or type(step.id)~="string" then return nil,"Missing program point" end
  profile=profile or {}
  if type(profile)~="table" then return nil,"Invalid audio profile" end
  local language,mode=profile.language or "nb",profile.mode or "learning"
  if language~="nb" and language~="en" then return nil,"Unsupported speech language" end
  if mode~="learning" and mode~="expert" then return nil,"Unsupported call mode" end
  local entry=field(field(self.catalog.programs,programId),step.id)
  if type(entry)~="table" then return nil,"Missing audio for "..programId.." / "..step.id end
  if step.variantId then
    if type(step.variantId)~="string" then return nil,"Invalid audio variant ID" end
    entry=field(entry.variants,step.variantId)
    if type(entry)~="table" then return nil,"Missing variant audio: "..step.variantId end
  end
  local sequence={}
  local function add(ref,voice,gap)
    local refs=type(ref)=="table" and ref or {ref}
    if #refs==0 then return nil,"Missing audio recipe" end
    for i,hash in ipairs(refs) do
      local clip,error=self:_clip(hash)
      if not clip then return nil,error end
      sequence[#sequence+1]={hash=hash,voice=voice,gap=i==1 and (gap or 0) or 0}
    end
    return true
  end
  local ok,error
  if step.kind~="figure" then
    ok,error=add(entry[language.."Learning"],language,0)
  else
    if profile.number~=false then
      ok,error=add(field(field(self.catalog.numbers,language),step.number),language,0)
      if not ok then return nil,"Missing figure-number audio: "..tostring(step.number) end
    end
    local titleLanguage=language=="nb" and profile.titleLanguage=="nb" and "nb" or "en"
    local titleKey=titleLanguage=="nb" and "title_nb" or "title"
    local titleGap=profile.number~=false and language~=titleLanguage and VOICE_GAP or 0
    ok,error=add(entry[titleKey],titleLanguage,titleGap)
    if ok and mode~="expert" then ok,error=add(entry[language.."Learning"],language,VOICE_GAP) end
  end
  if not ok then return nil,error end
  return sequence
end
function Audio:_begin(sequence,now)
  if self.pauseActive then return false,"Audio paused by source" end
  if not self.inspect then return self:_fail("Audio validator unavailable") end
  now=self:_clock(math.max(now,os.clock()));self:_expire(now)
  self.requestId=self.requestId+1
  self.active={sequence=sequence,item=1,waitUntil=now,requestId=self.requestId}
  self.awaitingManual=false;self.errorTone=false;self.lastError=nil
  self.metrics.calls=self.metrics.calls+1;self:_state(now);self:_notify("clear")
  return true
end
function Audio:call(programId,step,profile,now)
  now=self:_clock(now);self:_expire(now)
  if self.pauseActive then return false,"Audio paused by source" end
  self:stop("new-call")
  local sequence,error=self:_sequence(programId,step,profile)
  if not sequence then return self:_fail(error) end
  return self:_begin(sequence,now)
end
function Audio:confirmation(name,language,now)
  now=self:_clock(now);self:_expire(now)
  if self.pauseActive then return false,"Audio paused by source" end
  self:stop("confirmation")
  local valid,catalogError=catalogHeader(self.catalog)
  if not valid then return self:_fail(catalogError) end
  if type(name)~="string" then return self:_fail("Invalid confirmation name") end
  language=language=="en" and "en" or "nb"
  local hash=field(field(self.catalog.common,language),name)
  local clip,error=self:_clip(hash)
  if not clip then return self:_fail(error) end
  return self:_begin({{hash=hash,voice=language,gap=0}},now)
end
function Audio:_submit(now)
  local active=self.active
  if not active or self.inFlight or now<active.waitUntil then return end
  local item=active.sequence[active.item]
  if not item then self.active=nil;return end
  local clip,error=self:_clip(item.hash)
  if not clip then return self:_fail(error) end
  local path=self.root..clip.file
  self.metrics.fileChecks=self.metrics.fileChecks+1
  local ok,info,problem=pcall(self.inspect,path)
  if not ok then return self:_fail("Cannot validate audio: "..path.." ("..tostring(info)..")") end
  if type(info)~="table" then return self:_fail(problem or ("Invalid audio file: "..path)) end
  if not finite(info.duration) or math.abs(info.duration-clip.duration)>EPSILON then return self:_fail("Audio duration mismatch: "..path) end
  if type(system)~="table" or type(system.playFile)~="function" then return self:_fail("Ethos audio unavailable") end
  local requestedAt=self:_clock(math.max(now,os.clock()))
  local played,playError=pcall(system.playFile,path)
  if not played then return self:_fail("Cannot play audio: "..path.." ("..tostring(playError)..")") end
  self.inFlight={hash=item.hash,path=path,requestedAt=requestedAt,expectedEnd=requestedAt+clip.duration,
    duration=clip.duration,requestId=active.requestId,kind="file"}
  self.tail=self.inFlight.expectedEnd
  self.metrics.files=self.metrics.files+1;self.metrics.segments=self.metrics.files -- historical diagnostic alias
  active.item=active.item+1
  local following=active.sequence[active.item]
  active.waitUntil=self.tail+(following and following.gap or 0)
end
function Audio:update(now)
  local began=os.clock();local previous=self.lastUpdate
  now=self:_clock(now);self:_expire(now)
  self.lastUpdate=now;self.metrics.updates=self.metrics.updates+1
  if previous and now>=previous then self.metrics.maxUpdateInterval=math.max(self.metrics.maxUpdateInterval,now-previous) end
  if not self.pauseActive and not self.awaitingManual then
    if self.errorTone and not self.inFlight then
      self.errorTone=false
      if type(system)=="table" and type(system.playTone)=="function" then
        local requestedAt=self:_clock(math.max(now,os.clock()))
        if pcall(system.playTone,1800,120,0) then
          self.inFlight={requestedAt=requestedAt,expectedEnd=requestedAt+ERROR_TONE_SECONDS,requestId=self.requestId,kind="tone"}
          self.tail=self.inFlight.expectedEnd
        end
      end
    elseif self.active then self:_submit(now) end
  end
  self:_state(self.lastNow)
  self.metrics.maxUpdateCost=math.max(self.metrics.maxUpdateCost,os.clock()-began)
end
return Audio
