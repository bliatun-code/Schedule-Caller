-- Two checksummed slots preserve the previous settings if a write is interrupted.
-- No Lua evaluation is used to read user settings. Model sources use widget storage.
local Store={}
Store.__index=Store
local LIMIT=32768
local function checksum(text)
  local value=5381
  for i=1,#text do value=(value*33+text:byte(i))%2147483647 end
  return value
end
local function readFile(path)
  local file=io.open(path,"r")
  if not file then return nil end
  local ok,text=pcall(function() return file:read(LIMIT+1) end)
  file:close()
  if not ok or type(text)~="string" or #text>LIMIT then return nil end
  return text
end
local function decode(raw)
  if not raw then return nil end
  local seq,hash,body=raw:match("^SC1:(%d+):(%d+)\n(.*)$")
  seq,hash=tonumber(seq),tonumber(hash)
  if not seq or not hash or checksum(body)~=hash then return nil end
  local values={}
  for line in body:gmatch("([^\n]+)\n") do
    local key,value=line:match("^([%w_.-]+)=(.*)$")
    if not key or values[key]~=nil then return nil end
    values[key]=value
  end
  return {seq=seq,values=values}
end
function Store.new(prefix)
  local best,bestSlot
  for _,slot in ipairs({"a","b"}) do
    local ok,candidate=pcall(function() return decode(readFile(prefix.."-"..slot..".cfg")) end)
    if ok and candidate and (not best or candidate.seq>best.seq) then best,bestSlot=candidate,slot end
  end
  return setmetatable({prefix=prefix,seq=best and best.seq or 0,slot=bestSlot,values=best and best.values or {}},Store)
end
function Store:get(key,fallback)
  local value=self.values[key]
  if value==nil then return fallback end
  return value
end
function Store:set(key,value)
  assert(type(key)=="string" and key:match("^[%w_.-]+$"),"Invalid settings key")
  value=tostring(value)
  assert(not value:find("[\r\n]"),"Invalid settings value")
  if self.values[key]~=value then self.values[key]=value;self.dirty=true end
end
function Store:save()
  if not self.dirty then return true end
  local keys,parts={},{}
  for key in pairs(self.values) do keys[#keys+1]=key end
  table.sort(keys)
  for _,key in ipairs(keys) do parts[#parts+1]=key.."="..self.values[key].."\n" end
  local body=table.concat(parts)
  local seq=self.seq+1
  local raw="SC1:"..seq..":"..checksum(body).."\n"..body
  if #raw>LIMIT then self.error="Settings file too large";return false end
  local slot=self.slot=="a" and "b" or "a"
  local path=self.prefix.."-"..slot..".cfg"
  local ok,message=pcall(function()
    local file=assert(io.open(path,"w"),"Cannot open settings file")
    local written,err=pcall(function() file:write(raw) end)
    file:close()
    assert(written,err)
    local result=decode(readFile(path))
    assert(result and result.seq==seq,"Settings verification failed")
  end)
  if not ok then self.error=tostring(message);return false end
  self.seq,self.slot,self.dirty,self.error=seq,slot,false,nil
  return true
end
return Store
