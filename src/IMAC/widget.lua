-- Schedule Caller widget. main.lua loads this file when a model uses the widget
-- and releases it again when the last widget is destroyed.
local BASE="SCRIPTS:/ScheduleCallerIMAC/"
local Core=dofile(BASE.."lib/core.lua")
local Buttons=dofile(BASE.."lib/buttons.lua")
local Store=dofile(BASE.."lib/store.lua")
local Render=dofile(BASE.."lib/render.lua")
local Index=dofile(BASE.."programs/index.lua").programs
local VERSION="1.0.2"
local AUDIO_PENDING="Audio installation incomplete. Reinstall the sound library."
local shared={instances={},revision=1,events={},metrics={polls=0,builds=0,paints=0,buildMs=0,maxBuildMs=0,paintMs=0,maxPaintMs=0,gcSteps=0,gcMs=0,maxGcMs=0},audioReady=false}
local configure

local function call(fn,...)
  if type(fn)~="function" then return nil end
  local ok,a,b=pcall(fn,...)
  if ok then return a,b end
end
local function finite(n) return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge end
local function now() return call(os.clock) or 0 end
local function dirty()
  shared.revision=shared.revision+1
  for _,w in ipairs(shared.instances) do w.refresh=true end
end
local function valid(w) return type(w)=="table" and not w.destroyed end
-- Module-level readers: pressed() runs for three sources in every wakeup,
-- also behind VoltDeck/GasDeck, so it must not create closures.
local function sourceCategory(value) return value:category() end
local function sourceValue(value) return value:value() end
local function sourceState(value) return value:state() end
local function source(value)
  if type(value)=="string" then value=call(system.getSource,value) end
  if type(value)~="userdata" and type(value)~="table" then return nil end
  local category=call(sourceCategory,value)
  if category==CATEGORY_NONE then return nil end
  return value
end
local function pressed(value)
  if not value then return false end
  -- Whole momentary sources have a useful value, but state() can remain false.
  local number=call(sourceValue,value)
  if finite(number) then return number>0 end
  if type(number)=="boolean" then return number end
  return call(sourceState,value)==true
end
local function modelKey() return tostring(call(model.path) or call(model.id) or call(model.name) or "unknown") end
local function member(list,value,fallback)
  for _,candidate in ipairs(list) do if value==candidate then return value end end
  return fallback
end
local function number(value,fallback)
  value=tonumber(value);return finite(value) and value or fallback
end
local function optionalLoad(path)
  local file=io.open(path,"r")
  if not file then return nil,"Missing "..path end
  file:close()
  local ok,result=pcall(dofile,path)
  if not ok then
    print("Schedule Caller IMAC: cannot load "..path..": "..tostring(result))
    return nil,"Cannot load "..path
  end
  return result
end
local function record(event)
  local entry={type=event.type,reason=event.reason,stepId=event.step and event.step.id,index=event.index,at=now()}
  if event.type=="stop" and shared.audio then shared.audio:stop(event.reason)
  elseif event.type=="call" or event.type=="confirmation" then
    if shared.profile.speech==false then
      entry.audioAccepted=true;entry.muted=true
    elseif shared.audio and shared.audioReady then
      if event.type=="call" then
        local step={};for key,value in pairs(event.step) do step[key]=value end
        step.variantId=shared.profile.variants[step.id]
        local profile={};for key,value in pairs(shared.profile) do profile[key]=value end
        profile.playbackMode="segments"
        entry.playbackMode=profile.playbackMode
        entry.audioAccepted,entry.audioError=shared.audio:call(shared.core.program.id,step,profile,entry.at)
      else
        entry.audioAccepted,entry.audioError=shared.audio:confirmation(event.name,shared.profile.language,entry.at)
      end
    else entry.audioAccepted=false;entry.audioError=shared.audioError or "Audio installation incomplete" end
    shared.lastAudioRequest=entry
  end
  if shared.simulation then
    shared.events[#shared.events+1]=entry
    if #shared.events>80 then table.remove(shared.events,1) end
  end
end
local function loadProgram(id)
  for _,item in ipairs(Index) do
    if item.id==id then
      local result=dofile(BASE.."programs/"..item.file)
      assert(result.id==id and type(result.steps)=="table","Invalid program data")
      return result
    end
  end
end
local function readProfile(program)
  local prefix="p."..program.id.."."
  local savedMode=shared.store:get(prefix.."mode")
  local mode=member({"learning","expert"},savedMode,"expert")
  if savedMode=="short" then
    mode="learning"
    shared.store:set(prefix.."mode",mode);shared.saveAt=now()+.2
  end
  local result={mode=mode,
    language=member({"nb","en"},shared.store:get(prefix.."language"),"en"),
    titleLanguage=member({"nb","en"},shared.store:get(prefix.."titleLanguage"),"en"),
    speech=shared.store:get(prefix.."speech","true")~="false",
    number=shared.store:get(prefix.."number","false")=="true",variants={}}
  for _,step in ipairs(program.steps) do
    if step.variants then
      local selected=shared.store:get(prefix.."variant."..step.id,step.default_variant)
      for _,variant in ipairs(step.variants) do if variant.id==selected then result.variants[step.id]=selected end end
    end
  end
  return result
end
local function loadAudio(programId)
  local Audio=shared.audioModule
  local filename=type(shared.audioCatalogs)=="table" and shared.audioCatalogs[programId]
  local engine=shared.audio
  if engine then engine.catalog=nil end
  local catalog,catalogProblem
  if filename then catalog,catalogProblem=optionalLoad(BASE.."audio/"..filename) end
  local validCatalog,validationProblem
  if type(Audio)=="table" and type(Audio.new)=="function" and type(Audio.validateCatalog)=="function" then
    local ok,value,problem=pcall(Audio.validateCatalog,catalog)
    validCatalog=ok and value==true
    validationProblem=ok and problem or "Invalid audio catalog validator"
  end
  shared.audioReady=false
  if validCatalog then
    if engine then
      engine.catalog=catalog
    else
      engine=Audio.new(BASE,catalog,function(kind,message)
        if kind=="error" then shared.audioError=tostring(message)
        elseif kind=="clear" then shared.audioError=nil end
        dirty()
      end)
      shared.audio=engine
    end
    shared.audioReady=type(engine.inspect)=="function"
    shared.audioError=not shared.audioReady and "Audio validator unavailable" or nil
  else
    shared.audioError=shared.audioModuleError or shared.audioCatalogIndexError or catalogProblem
      or (not filename and "Missing audio catalog for "..programId)
      or validationProblem or "Invalid audio installation"
  end
  if _G.SC_TEST then SC_TEST.audioReady=shared.audioReady end
end

-- Ethos stops create() after about 20 000 Lua instructions. Reading settings
-- costs about 7 instructions per byte per slot, so settings saved for many
-- programs plus the selected program and catalog went over the limit on the
-- radio. Loading therefore runs from wakeup, one small step per call.
local loadSteps={
  function()
    shared.store=Store.new(BASE.."user-settings")
    shared.settings={layout=member({"focus","deck","daylight","briefing","diagram"},shared.store:get("layout"),"diagram"),
      theme=member({"radio","dark","light","custom"},shared.store:get("theme"),"light"),
      preview=shared.store:get("preview","current")=="next" and "next" or "current",
      diagramTitle=shared.store:get("diagramTitle","false")=="true",
      diagramPreview=shared.store:get("diagramPreview","current")=="next" and "next" or "current",
      playbackMode="segments",
      wind=member({"B","C"},shared.store:get("wind"),"B"),
      foreground=number(shared.store:get("foreground"),lcd.RGB(255,255,255)),
      background=number(shared.store:get("background"),lcd.RGB(0,0,0))}
    if shared.store:get("playbackMode")~="segments" then shared.store:set("playbackMode","segments");shared.saveAt=now()+.2 end
  end,
  function()
    local selected=shared.store:get("program",Index[1].id)
    local program=loadProgram(selected) or loadProgram(Index[1].id)
    if program.id~=selected then shared.store:set("program",program.id);shared.saveAt=now()+.2 end
    shared.profile=readProfile(program)
    shared.core=Core.new(program,record)
    shared.core.variants=shared.profile.variants
    shared.modelKey=modelKey()
  end,
  function()
    local Images,imageProblem=optionalLoad(BASE.."lib/images.lua")
    if type(Images)=="table" and type(Images.new)=="function" then
      local ok,library=pcall(Images.new,BASE)
      if ok and type(library)=="table" then shared.images=library
      else shared.imageError="Diagram library could not be loaded" end
    else shared.imageError=imageProblem or "Diagram library is not installed" end
    if type(Render.setImageLibrary)=="function" then Render.setImageLibrary(shared.images) end
  end,
  function()
    shared.audioModule,shared.audioModuleError=optionalLoad(BASE.."lib/audio.lua")
    shared.audioCatalogs,shared.audioCatalogIndexError=optionalLoad(BASE.."audio/catalog.lua")
  end,
  function() loadAudio(shared.core.program.id) end,
}
local function loadStep()
  if shared.ready then return true end
  local index=(shared.loaded or 0)+1
  loadSteps[index]()
  shared.loaded=index
  if index==#loadSteps then shared.ready=true;dirty() end
  return shared.ready
end
local function ensureShared()
  while not loadStep() do end
end
local function saveSoon()
  shared.saveAt=now()+.2
end
local function setGlobal(key,value)
  ensureShared()
  local validValue
  if key=="layout" then validValue=member({"focus","deck","daylight","briefing","diagram"},value,nil)
  elseif key=="theme" then validValue=member({"radio","dark","light","custom"},value,nil)
  elseif key=="preview" or key=="diagramPreview" then validValue=member({"current","next"},value,nil)
  elseif key=="diagramTitle" and type(value)=="boolean" then validValue=value
  elseif key=="playbackMode" then validValue=value=="segments" and "segments" or nil
  elseif key=="wind" then validValue=member({"B","C"},value,nil)
  elseif key=="foreground" or key=="background" then if finite(value) then validValue=value end end
  if validValue==nil then return false end
  shared.settings[key]=validValue;shared.store:set(key,validValue);saveSoon();dirty();return true
end
local function setProfile(key,value)
  ensureShared()
  if key=="speech" then
    if not member({"en","nb","nb-native","off"},value,nil) then return false end
    local enabled=value~="off"
    local prefix="p."..shared.core.program.id.."."
    shared.profile.speech=enabled
    shared.store:set(prefix.."speech",enabled)
    if enabled then
      shared.profile.language=value=="en" and "en" or "nb"
      shared.profile.titleLanguage=value=="nb-native" and "nb" or "en"
      shared.store:set(prefix.."language",shared.profile.language)
      shared.store:set(prefix.."titleLanguage",shared.profile.titleLanguage)
    elseif shared.audio then shared.audio:stop("speech-off") end
    saveSoon();dirty();return true
  end
  local accepted
  if key=="mode" then accepted=member({"learning","expert"},value=="short" and "learning" or value,nil)
  elseif key=="language" then accepted=member({"nb","en"},value,nil)
  elseif key=="number" and type(value)=="boolean" then accepted=value end
  if accepted==nil then return false end
  shared.profile[key]=accepted
  shared.store:set("p."..shared.core.program.id.."."..key,accepted);saveSoon();dirty();return true
end
local function setProgram(id)
  ensureShared()
  local program=loadProgram(id)
  if not program then return false end
  if shared.core.program.id==id then return true end
  shared.profile=readProfile(program)
  shared.core:setProgram(program,shared.profile.variants)
  loadAudio(id)
  shared.store:set("program",id);saveSoon()
  if shared.buttons then shared.buttons:clear() end
  for _,w in ipairs(shared.instances) do w.scroll=0 end
  dirty();return true
end
local function setVariant(stepId,variantId)
  ensureShared()
  if not shared.core:setVariant(stepId,variantId) then return false end
  shared.profile.variants[stepId]=variantId
  shared.store:set("p."..shared.core.program.id..".variant."..stepId,variantId);saveSoon()
  if shared.buttons then shared.buttons:clear() end
  for _,w in ipairs(shared.instances) do w.scroll=0 end
  dirty();return true
end
local function action(kind)
  ensureShared()
  local core=shared.core
  if kind=="next" then core:next()
  elseif kind=="repeat" then core:repeatCurrent()
  elseif kind=="previous" then core:previous()
  elseif kind=="reset" then core:reset(true)
  else return false end
  for _,w in ipairs(shared.instances) do w.scroll=0 end
  dirty();return true
end
local function claimOwner(w)
  if shared.owner==w then return end
  local previous=shared.owner
  local sameBindings=valid(previous) and previous.modelKey==w.modelKey and previous.sources==w.sources and previous.resetMode==w.resetMode
  shared.owner=w
  if not sameBindings or not shared.buttons then
    shared.buttons=Buttons.new(action,{dedicatedReset=w.resetMode=="separate"})
    shared.buttons:clear()
  end
end
local function configChanged(w)
  shared.bindingConfigured=true;shared.bindingResetMode=w.resetMode
  for _,item in ipairs(shared.instances) do if item.modelKey==w.modelKey then item.resetMode=w.resetMode end end
  call(model.dirty)
  if shared.owner==w and shared.buttons then
    shared.buttons.dedicatedReset=w.resetMode=="separate";shared.buttons:clear()
  end
  dirty()
end
local function selectFigure(value)
  ensureShared()
  local ok=shared.core:selectFigure(value)
  if ok then
    if shared.buttons then shared.buttons:clear() end
    for _,w in ipairs(shared.instances) do w.scroll=0 end
    dirty()
  end
  return ok
end

local function updateLcd(w,time)
  if not shared.lcdWidth and (not shared.retryLcdAt or time>=shared.retryLcdAt) then
    shared.retryLcdAt=time+1
    local version=call(system.getVersion)
    if type(version)=="table" and finite(version.lcdWidth) and finite(version.lcdHeight) and version.lcdWidth>0 and version.lcdHeight>0 then shared.lcdWidth,shared.lcdHeight=version.lcdWidth,version.lcdHeight end
  end
  local width,height=call(lcd.getWindowSize)
  if not finite(width) or not finite(height) or width<1 or height<1 then return end
  local mode=not shared.lcdWidth and "unknown" or (width~=shared.lcdWidth or height~=shared.lcdHeight) and "split" or "full"
  if width~=w.width or height~=w.height or mode~=w.sizeMode then w.width,w.height,w.sizeMode=width,height,mode;w.refresh=true end
end
local function noticePlan(w)
  local width,height=w.width,w.height
  local light=shared.settings.theme=="light"
  local fg=light and lcd.RGB(0,0,0) or lcd.RGB(255,255,255)
  local bg=light and lcd.RGB(255,255,255) or lcd.RGB(0,0,0)
  if shared.settings.theme=="custom" then fg,bg=shared.settings.foreground,shared.settings.background end
  local plan={width=width,height=height,commands={{op="fill",x=0,y=0,w=width,h=height,color=bg}},textBounds={}}
  local padding=math.min(12,math.floor(width/16),math.floor(height/12))
  local fonts={FONT_M or FONT_STD or 0,FONT_S or FONT_STD or 0,FONT_XS or FONT_S or 0,FONT_XXS or FONT_XS or 0}
  local minHeight=math.huge
  for _,font in ipairs(fonts) do lcd.font(font);local _,h=lcd.getTextSize("A");if finite(h) and h>0 then minHeight=math.min(minHeight,h) end end
  local count=math.min(3,math.floor((height-2*padding+4)/(minHeight+4)))
  local middle=w.sizeMode=="unknown" and "Screen size unavailable" or "Full screen required"
  local rows={"Schedule Caller",middle,w.sizeMode=="unknown" and "Retrying automatically" or "Use a full-screen widget area"}
  if count==1 then rows={middle} elseif count==2 then rows={rows[1],middle} end
  if count<1 then return plan end
  local rowHeight=(height-2*padding-(count-1)*4)/count
  for index,text in ipairs(rows) do
    local selected,tw,th
    for _,font in ipairs(fonts) do
      lcd.font(font);local a,b=lcd.getTextSize(text)
      if a<=width-2*padding and b<=rowHeight then selected,tw,th=font,a,b;break end
    end
    if selected then
      local x=math.floor((width-tw)/2);local y=math.floor(padding+(index-1)*(rowHeight+4)+(rowHeight-th)/2)
      plan.commands[#plan.commands+1]={op="text",text=text,font=selected,color=fg,x=x,y=y}
      plan.textBounds[#plan.textBounds+1]={text=text,font=selected,x=x,y=y,w=tw,h=th,role="size-notice"}
    end
  end
  return plan
end
local function buildPlan(w)
  if not w.width or not w.height then return end
  local started=now()
  local ok,plan=pcall(function()
    if w.sizeMode~="full" then return noticePlan(w) end
    local step,_,ready=shared.core:current()
    local diagram=shared.settings.layout=="diagram"
    local status=w.storageError or shared.store.error or (shared.profile.speech~=false and shared.audioError)
      or (shared.profile.speech~=false and not shared.audioReady and AUDIO_PENDING)
      or (diagram and shared.imageError)
    local imagePath=diagram and shared.images and shared.images:path(shared.core.program.id,shared.settings.wind,step.number,shared.profile.variants[step.id])
    return Render.build({programName=shared.core.program.name,figureCount=shared.core.program.figure_count,
      step=step,nextStep=shared.core:upcoming(),ready=ready,layout=diagram and "focus" or shared.settings.layout,theme=shared.settings.theme,
      foreground=shared.settings.foreground,background=shared.settings.background,language=shared.profile.language,
      preview=(diagram and shared.settings.diagramPreview=="next") or (not diagram and shared.settings.preview=="next"),scroll=w.scroll,error=status,
      queued=shared.audio and shared.audio.waitingForPrevious==true,
      diagram=diagram,diagramTitle=shared.settings.diagramTitle,imagePath=imagePath,imageWind=shared.settings.wind},w.width,w.height)
  end)
  if ok then
    w.plan=plan;w.scroll=plan.scroll or 0;w.refresh=false;w.seenRevision=shared.revision;w.seenCoreRevision=shared.core.revision;w.renderError=nil
    -- Discarded wrapping/measurement tables can otherwise accumulate beyond
    -- the shared Lua budget when several Deck widgets are loaded. Advance the
    -- incremental collector after each new plan; paint only replays commands.
    local gcStarted=now()
    collectgarbage("step",128)
    local gcDuration=(now()-gcStarted)*1000
    shared.metrics.gcSteps=shared.metrics.gcSteps+1;shared.metrics.gcMs=shared.metrics.gcMs+gcDuration;shared.metrics.maxGcMs=math.max(shared.metrics.maxGcMs,gcDuration)
    local duration=(now()-started)*1000
    shared.metrics.builds=shared.metrics.builds+1;shared.metrics.buildMs=shared.metrics.buildMs+duration;shared.metrics.maxBuildMs=math.max(shared.metrics.maxBuildMs,duration)
  else
    w.plan=nil;w.renderError=tostring(plan);w.refresh=false
    print("Schedule Caller render error: "..tostring(plan))
  end
end
local function scroll(w,delta)
  if not w.plan or not w.plan.maxScroll or w.plan.maxScroll==0 then return false end
  w.scroll=math.max(0,math.min(w.plan.maxScroll,w.scroll+delta));w.refresh=true
  return true
end
local function hit(rect,x,y) return rect and x>=rect.x and x<rect.x+rect.w and y>=rect.y and y<rect.y+rect.h end
local function create()
  local identity=modelKey()
  if shared.bindingKey~=identity then
    shared.bindingKey=identity;shared.bindingConfigured=false;shared.bindingResetMode="separate"
    shared.bindingSources={nextSource=source("SJ"),repeatSource=source("SI"),resetSource=source("SH")}
  end
  local w={sources=shared.bindingSources,resetMode=shared.bindingResetMode,scroll=0,refresh=true,modelKey=identity}
  shared.instances[#shared.instances+1]=w
  if not valid(shared.owner) then claimOwner(w) end
  return w
end
local function read(w)
  if not valid(w) then return end
  local schema=call(storage.read,"schema")
  if schema~=nil and schema~=1 then w.storageError="Unsupported model settings";return end
  if schema==1 and not shared.bindingConfigured then
    for _,key in ipairs({"nextSource","repeatSource","resetSource"}) do w.sources[key]=source(call(storage.read,key)) end
    w.resetMode=call(storage.read,"resetMode")=="hold" and "hold" or "separate"
    shared.bindingResetMode=w.resetMode;shared.bindingConfigured=true
    for _,item in ipairs(shared.instances) do if item.modelKey==w.modelKey then item.resetMode=w.resetMode end end
  end
  if shared.owner==w then claimOwner(w);shared.buttons.dedicatedReset=w.resetMode=="separate";shared.buttons:clear() end
end
local function write(w)
  if not valid(w) or w.storageError then return end
  storage.write("schema",1)
  for _,key in ipairs({"nextSource","repeatSource","resetSource"}) do storage.write(key,w.sources[key]) end
  storage.write("resetMode",w.resetMode)
end
local function wakeup(w)
  if not valid(w) then return end
  if not shared.ready then loadStep();return end
  local time=now()
  w.visible=call(lcd.isVisible)==true
  if not valid(shared.owner) or (w.visible and not shared.owner.visible) then claimOwner(w) end
  if shared.owner==w then
    local identity=modelKey()
    if shared.modelKey~=identity then
      shared.modelKey=identity;shared.core:reset(false);shared.buttons:clear();dirty()
      for _,item in ipairs(shared.instances) do item.scroll=0 end
    end
    shared.metrics.polls=shared.metrics.polls+1
    if not w.storageError then shared.buttons:poll(time,pressed(w.sources.nextSource),pressed(w.sources.repeatSource),w.resetMode=="separate" and pressed(w.sources.resetSource) or false) end
    if shared.audio then
      shared.audio:update(now())
      local queued=shared.audio.waitingForPrevious==true
      if queued~=shared.audioQueued then shared.audioQueued=queued;dirty() end
    end
    if shared.saveAt and time>=shared.saveAt then
      shared.saveAt=nil
      local before=shared.store.error
      shared.store:save()
      if shared.store.error~=before then dirty() end
    end
  end
  updateLcd(w,time)
  if shared.settings.theme=="radio" and w.visible and (not w.nextThemeAt or time>=w.nextThemeAt) then
    w.nextThemeAt=time+1
    local colors={}
    for _,name in ipairs({"THEME_DEFAULT_COLOR","THEME_DEFAULT_BGCOLOR","THEME_SECONDARY_COLOR","THEME_SECONDARY_BGCOLOR","THEME_WARNING_COLOR"}) do
      colors[#colors+1]=tostring(_G[name] and call(lcd.themeColor,_G[name]))
    end
    local signature=table.concat(colors,":")
    if signature~=w.themeSignature then w.themeSignature=signature;w.refresh=true end
  end
  if shared.owner==w and shared.images then
    local step=shared.core:current()
    local path=shared.settings.layout=="diagram" and w.visible and w.sizeMode=="full" and not w.formMode
      and shared.images:path(shared.core.program.id,shared.settings.wind,step.number,shared.profile.variants[step.id]) or nil
    local changed=shared.images:select(path,time)
    if shared.images:update(now()) or changed then dirty() end
  end
  if w.refresh or w.seenRevision~=shared.revision or w.seenCoreRevision~=shared.core.revision then
    -- Behind VoltDeck/GasDeck the plan is not drawn. Rebuild it when this
    -- instance becomes visible; keep the first plan so paint always has one.
    if w.visible or not w.plan then buildPlan(w) end
    if w.visible then lcd.invalidate() end
  end
  if shared.simulation and _G.SC_TEST and type(SC_TEST.onWakeup)=="function" and shared.owner==w then SC_TEST.onWakeup(w,time) end

end
local function paint(w)
  if not valid(w) or w.formMode then return end
  local width,height=call(lcd.getWindowSize)
  if not w.plan or width~=w.plan.width or height~=w.plan.height then w.refresh=true;return end
  local started=now()
  Render.paint(w.plan)
  local duration=(now()-started)*1000
  shared.metrics.paints=shared.metrics.paints+1;shared.metrics.paintMs=shared.metrics.paintMs+duration;shared.metrics.maxPaintMs=math.max(shared.metrics.maxPaintMs,duration)
end
local function event(w,category,value,x,y)
  if not valid(w) then return false end
  if w.sizeMode~="full" then return false end
  if category==EVT_KEY then
    if value==KEY_ROTARY_LEFT then return scroll(w,-1)
    elseif value==KEY_ROTARY_RIGHT then return scroll(w,1) end
  elseif category==EVT_TOUCH and finite(x) and finite(y) then
    if value==TOUCH_START then
      w.touchX,w.touchY=x,y
      local rects=w.plan and w.plan.hitRects or {}
      return hit(rects.wind,x,y) or hit(rects.scrollUp,x,y) or hit(rects.scrollDown,x,y) or false
    elseif value==TOUCH_MOVE then
      local dy=w.touchY and y-w.touchY or 0;local dx=w.touchX and x-w.touchX or 0
      return math.abs(dy)>24 and math.abs(dy)>math.abs(dx) and w.plan and (w.plan.maxScroll or 0)>0 or false
    elseif value==TOUCH_END then
      local dy=w.touchY and y-w.touchY or 0;local dx=w.touchX and x-w.touchX or 0
      w.touchX,w.touchY=nil,nil
      if math.abs(dy)>24 and math.abs(dy)>math.abs(dx) and scroll(w,dy>0 and -2 or 2) then return true end
      local rects=w.plan and w.plan.hitRects or {}
      if hit(rects.wind,x,y) then setGlobal("wind",shared.settings.wind=="B" and "C" or "B");return true
      elseif hit(rects.scrollUp,x,y) then return scroll(w,-1)
      elseif hit(rects.scrollDown,x,y) then return scroll(w,1) end
      return false
    end
  end
  return false
end
local function menu(w)
  if shared.simulation then shared.menuCalls=(shared.menuCalls or 0)+1 end
  return {{"New round",function() claimOwner(w);action("reset") end}}
end
configure=function(w)
  if not valid(w) then return end
  ensureShared()
  w.configGeneration=(w.configGeneration or 0)+1
  local generation,bindings,panel=w.configGeneration,{},nil
  shared.configHandlers=shared.configHandlers or {};w.configHandlers=shared.configHandlers
  local function callbacks(label,getter,setter,enabled,choices)
    local item=w.configHandlers[label]
    if not item then
      item={owner=w};w.configHandlers[label]=item
      item.get=function()
        if not valid(item.owner) or not item.getter then return item.isChoice and 1 or nil end
        local value=item.getter()
        if item.choices then
          for index,choice in ipairs(item.choices) do if choice[2]==value then return index end end
          return 1
        end
        return value
      end
      item.set=function(value)
        if not valid(item.owner) or (item.enabled and not item.enabled()) then return end
        if item.choices then
          if not item.choices[value] then return end
          value=item.choices[value][2]
        end
        item.setter(value)
        if valid(item.owner) and item.owner.configRefresh then item.owner.configRefresh() end
      end
    end
    item.owner,item.isChoice=w,choices~=nil
    item.getter,item.setter,item.enabled,item.choices=getter,setter,enabled,choices
    return item.get,item.set
  end
  if shared.simulation then w.configFields={};w.configPanels={} end
  local function current() return valid(w) and w.configGeneration==generation end
  local function refresh()
    for _,binding in ipairs(bindings) do if current() then binding.field:enable(binding.enabled()) end end
  end
  w.configRefresh=refresh
  local function group(label)
    panel=form.addExpansionPanel(label);panel:open(false)
    if shared.simulation then w.configPanels[label]=panel end
  end
  local function line(label) return form.addLine(label,panel) end
  local function bind(label,field,enabled)
    if enabled then bindings[#bindings+1]={field=field,enabled=enabled} end
    if shared.simulation then w.configFields[label]=field end
    return field
  end
  local function choice(label,choices,getter,setter,enabled)
    local native={};for index,item in ipairs(choices) do native[index]={item[1],index} end
    local get,set=callbacks(label,getter,setter,enabled,choices)
    return bind(label,form.addChoiceField(line(label),nil,native,get,set),enabled)
  end
  local function color(label,key)
    local enabled=function() return shared.settings.theme=="custom" end
    local get,set=callbacks(label,function() return shared.settings[key] end,function(value)
      if current() and enabled() then setGlobal(key,value) end
    end,enabled)
    return bind(label,form.addColorField(line(label),nil,get,set),enabled)
  end
  local function sourceField(label,key,enabled)
    local get,set=callbacks(label,function() return w.sources[key] end,function(value)
      if current() and (not enabled or enabled()) then w.sources[key]=source(value);configChanged(w) end
    end,enabled)
    return bind(label,form.addSourceField(line(label),nil,get,set),enabled)
  end
  local function note(text)
    return form.addStaticText(line(""),{x=10,y=0,w=math.max(40,(call(form.width) or 800)-20),h=35},text)
  end
  form.addLine("Schedule Caller IMAC "..VERSION)
  group("Appearance")
  choice("Layout",{{"Focus","focus"},{"Deck","deck"},{"Daylight","daylight"},{"Briefing","briefing"},{"Diagram","diagram"}},function() return shared.settings.layout end,function(value) setGlobal("layout",value) end)
  choice("Diagram wind",{{"B  (left)","B"},{"C  (right)","C"}},function() return shared.settings.wind end,function(value) setGlobal("wind",value) end,function() return shared.settings.layout=="diagram" end)
  local function isDiagram() return shared.settings.layout=="diagram" end
  local visibility={{"On","on"},{"Off","off"}}
  choice("Show current name",visibility,function() return shared.settings.diagramTitle and "on" or "off" end,
    function(value) setGlobal("diagramTitle",value=="on") end,isDiagram)
  choice("Show next name",visibility,function() return shared.settings.diagramPreview=="next" and "on" or "off" end,
    function(value) setGlobal("diagramPreview",value=="on" and "next" or "current") end,isDiagram)
  choice("Display",{{"Current only","current"},{"Current + next","next"}},
    function() return shared.settings.preview end,
    function(value) setGlobal("preview",value) end,function() return not isDiagram() end)
  choice("Theme",{{"Radio theme","radio"},{"Dark","dark"},{"Light","light"},{"Custom","custom"}},function() return shared.settings.theme end,function(value) setGlobal("theme",value) end)
  color("Text color","foreground");color("Background color","background")
  note("To show illustrations, select Diagram under Appearance.")
  group("Program and calls")
  local programs={};for _,item in ipairs(Index) do programs[#programs+1]={item.name,item.id} end
  choice("Program",programs,function() return shared.core.program.id end,function(id)
    setProgram(id);form.clear();configure(w)
  end)
  note("Illustrations from IMAC (International Miniature Aerobatic Club).")
  choice("Call mode",{{"Name + description","learning"},{"Name only","expert"}},function() return shared.profile.mode end,function(value) setProfile("mode",value) end)
  choice("Speech",{{"Norwegian","nb-native"},{"English name + Norwegian description","nb"},{"English","en"},{"Off","off"}},function()
    if shared.profile.speech==false then return "off" end
    if shared.profile.language=="nb" and shared.profile.titleLanguage=="nb" then return "nb-native" end
    return shared.profile.language
  end,function(value) setProfile("speech",value) end)
  local numberGet,numberSet=callbacks("Speak figure number",function() return shared.profile.number end,function(value) if current() then setProfile("number",value) end end)
  bind("Speak figure number",form.addBooleanField(line("Speak figure number"),nil,numberGet,numberSet))
  for _,step in ipairs(shared.core.program.steps) do
    if step.variants then
      local id=step.id;local variants={};for _,v in ipairs(step.variants) do variants[#variants+1]={v.title_en,v.id} end
      choice("Figure "..tostring(step.number),variants,function() return shared.profile.variants[id] or step.default_variant end,function(value) setVariant(id,value) end)
    end
  end
  note("To show illustrations, select Diagram under Appearance.")
  group("Controls")
  sourceField("Next button","nextSource");sourceField("Repeat button","repeatSource")
  choice("New round method",{{"Separate button","separate"},{"Hold Repeat","hold"}},function() return w.resetMode end,function(value) w.resetMode=value;configChanged(w) end)
  sourceField("New round button","resetSource",function() return w.resetMode=="separate" end)
  note("Repeat: single repeats, double goes to previous.")
  note("New round: use the assigned button or hold Repeat.")
  refresh()
end
local function destroy(w)
  if not valid(w) then return end
  w.destroyed=true;w.plan=nil;w.configRefresh=nil
  for _,item in pairs(w.configHandlers or {}) do
    if item.owner==w then item.owner=nil;item.getter=nil;item.setter=nil;item.enabled=nil;item.choices=nil end
  end
  w.configHandlers=nil;w.configFields=nil;w.configPanels=nil
  for index,item in ipairs(shared.instances) do if item==w then table.remove(shared.instances,index);break end end
  if shared.owner==w then
    local replacement
    for _,item in ipairs(shared.instances) do if valid(item) and item.modelKey==w.modelKey and item.sources==w.sources and item.resetMode==w.resetMode then replacement=item;break end end
    shared.owner=replacement
    if not replacement then shared.buttons=nil end
  end
  if #shared.instances==0 and shared.core then
    shared.core:reset(false);shared.modelKey=nil
    shared.bindingKey=nil;shared.bindingSources=nil;shared.bindingConfigured=false
    if shared.images then shared.images:clear() end
  end
  if shared.store then shared.store:save() end
end
-- main.lua calls this after the last widget is destroyed, for example when the
-- model changes. destroy() has already saved the settings.
local function release()
  if shared.images then shared.images:clear() end
  if _G.SC_TEST and SC_TEST.shared==shared then _G.SC_TEST=nil end
end
do
  local version=call(system.getVersion)
  if type(version)=="table" and version.simulation==true then
    shared.simulation=true
    _G.SC_TEST={version=VERSION,audioReady=shared.audioReady,shared=shared,render=Render,index=Index,
      owner=function() return shared.owner end,instances=function() return shared.instances end,
      action=action,setProgram=setProgram,setGlobal=setGlobal,setProfile=setProfile,setVariant=setVariant,selectFigure=selectFigure,
      configure=function() configure(shared.owner) end,
      menu=function() return menu(shared.owner) end,
      scroll=function(delta) return scroll(shared.owner,delta) end,
      create=create,destroy=destroy,
      save=function() ensureShared();return shared.store:save() end,
      setResetMode=function(value) assert(value=="hold" or value=="separate");shared.owner.resetMode=value;configChanged(shared.owner) end,
      setSource=function(key,value) local w=shared.owner;assert(key=="nextSource" or key=="repeatSource" or key=="resetSource");w.sources[key]=source(value);configChanged(w) end,
      inspect=function()
        ensureShared()
        local step,index,ready=shared.core:current()
        return {program=shared.core.program.id,step=step.id,number=step.number,index=index,ready=ready,cursor=shared.core.cursor,
          pending=shared.core.pending,modelKey=shared.modelKey,settings=shared.settings,profile=shared.profile,
          audioReady=shared.audioReady,lastAudioRequest=shared.lastAudioRequest,events=shared.events,metrics=shared.metrics}
      end}
    local installTests=optionalLoad(BASE.."private-tests.lua")
    if type(installTests)=="function" then installTests(SC_TEST) end
  end
end
return {create=create,read=read,write=write,wakeup=wakeup,paint=paint,event=event,menu=menu,configure=configure,
  destroy=destroy,unused=function() return #shared.instances==0 end,release=release}
