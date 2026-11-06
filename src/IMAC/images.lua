-- One current diagram only. Loading and bounded collection run outside paint.
local Images={}
Images.__index=Images
local RESERVE=65536
local MAX_PIXELS=300000
local function finite(v) return type(v)=="number" and v==v and v~=math.huge and v~=-math.huge end
local function integer(v) return finite(v) and v==math.floor(v) end
local function clock(now) return finite(now) and now or os.clock() end
local function u32(s,p)
  local a,b,c,d=s:byte(p,p+3)
  return a and b and c and d and ((a*256+b)*256+c)*256+d or nil
end
local function header(path,entry)
  local ok,file=pcall(io.open,path,"r")
  if not ok or not file then return nil,"Diagram file is missing" end
  local good,data=pcall(function() return file:read(33) end)
  pcall(function() file:close() end)
  if not good or type(data)~="string" or #data<33 or data:sub(1,8)~="\137PNG\13\10\26\10"
    or data:sub(13,16)~="IHDR" or u32(data,17)~=entry.width or u32(data,21)~=entry.height then
    return nil,"Diagram file is invalid"
  end
  return true
end
function Images.new(root)
  assert(type(root)=="string" and root~="","Images requires a script root")
  if root:sub(-1)~="/" then root=root.."/" end
  local self=setmetatable({root=root,byPath={},programs={},status="empty",retryAt=0,
    metrics={loads=0,failures=0,memoryWaits=0,maxLoadMs=0,maxUpdateMs=0,gcSteps=0}},Images)
  local ok,catalog=pcall(dofile,root.."images/index.lua")
  if not ok or type(catalog)~="table" or catalog.schema~=1 or type(catalog.programs)~="table" then
    self.catalogError="Diagram library is not installed";return self
  end
  -- Runtime work must stay bounded as the library grows. The index is data;
  -- validate only a requested program (twenty entries), outside paint.
  self.rawPrograms=catalog.programs
  return self
end
function Images:_loadProgram(id)
  if type(id)~="string" then return nil end
  if self.programs[id]~=nil then return self.programs[id] or nil end
  local winds=self.rawPrograms and self.rawPrograms[id]
  if type(winds)~="table" then self.programs[id]=false;return nil end
  local program={};self.programs[id]=program
  for _,wind in ipairs({"B","C"}) do
    local figures=winds[wind]
    if type(figures)=="table" then
      local result={};program[wind]=result
      for number,entry in pairs(figures) do
        if integer(number) and number>0 and type(entry)=="table" and type(entry.path)=="string"
          and entry.path:match("^images/[%w_/-]+%.png$") and not entry.path:find("//",1,true)
          and integer(entry.width) and integer(entry.height) and entry.width>0 and entry.height>0
          and entry.width<=1024 and entry.height<=1024 and entry.width*entry.height<=MAX_PIXELS then
          local path=self.root..entry.path
          self.byPath[path]={path=path,width=entry.width,height=entry.height}
          result[number]=path
        end
      end
    end
  end
  return program
end
function Images:path(programId,wind,number)
  local program=self:_loadProgram(programId)
  local figures=program and program[wind]
  return figures and figures[number] or nil
end
function Images:select(path,now)
  if path==self.currentPath then return false end
  self.needsGc=self.needsGc or self.bitmap~=nil
  self.bitmap=nil -- plans keep a path, so they do not retain old bitmap userdata
  self.currentPath=path;self.entry=path and self.byPath[path] or nil
  self.checked=false;self.retryAt=clock(now);self.waits=0;self.error=nil
  if not path then self.status="empty";self.pending=false
  elseif not self.entry then self.status="error";self.error="Diagram is not installed";self.pending=false
  else self.status="loading";self.pending=true end
  return true
end
function Images:clear() return self:select(nil) end
function Images:info(path)
  local entry=path and self.byPath[path]
  return {path=path,width=entry and entry.width,height=entry and entry.height,
    status=path==self.currentPath and self.status or "empty",
    error=path==self.currentPath and self.error or self.catalogError}
end
function Images:peek(path)
  if path==self.currentPath and self.status=="ready" then return self.bitmap end
end
function Images:_fail(message)
  self.bitmap=nil;self.pending=false;self.status="error";self.error=message
  self.metrics.failures=self.metrics.failures+1
  return true
end
function Images:update(now)
  now=clock(now)
  local began=os.clock()
  local changed=false
  if self.needsGc then
    collectgarbage("step",128);self.metrics.gcSteps=self.metrics.gcSteps+1;self.needsGc=false
  end
  if self.pending and now>=self.retryAt then
    if not self.checked then
      local valid,message=header(self.currentPath,self.entry)
      if not valid then return self:_fail(message) end
      self.checked=true
    end
    local usage=system.getMemoryUsage()
    local available=type(usage)=="table" and usage.luaBitmapsRamAvailable
    local needed=self.entry.width*self.entry.height*4+RESERVE
    if finite(available) and available<needed then
      collectgarbage("step",128);self.metrics.gcSteps=self.metrics.gcSteps+1
      self.metrics.memoryWaits=self.metrics.memoryWaits+1;self.waits=self.waits+1
      local message="Waiting for diagram memory"
      changed=self.error~=message
      self.error=message;self.retryAt=now+(self.waits<16 and .04 or 1)
    else
      local started=os.clock()
      local ok,bitmap=pcall(lcd.loadBitmap,self.currentPath,false)
      self.metrics.maxLoadMs=math.max(self.metrics.maxLoadMs,(os.clock()-started)*1000)
      if not ok or not bitmap then return self:_fail("Diagram could not be decoded") end
      local dimensions,width,height=pcall(function() return bitmap:width(),bitmap:height() end)
      if not dimensions or width~=self.entry.width or height~=self.entry.height then
        return self:_fail("Diagram dimensions do not match")
      end
      self.bitmap=bitmap;self.status="ready";self.pending=false;self.error=nil
      self.metrics.loads=self.metrics.loads+1;changed=true
    end
  end
  self.metrics.maxUpdateMs=math.max(self.metrics.maxUpdateMs,(os.clock()-began)*1000)
  return changed
end
return Images
