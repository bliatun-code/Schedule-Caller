-- Cheap runtime validation before Ethos playFile (which has no success result).
-- Full signal/energy/hash validation belongs to the private build checks.
local Wav={}
local function u16(s,p)
  local a,b=s:byte(p,p+1)
  return a and b and a+b*256 or nil
end
local function u32(s,p)
  local a,b,c,d=s:byte(p,p+3)
  return a and b and c and d and a+b*256+c*65536+d*16777216 or nil
end
function Wav.inspect(path)
  local ok,file=pcall(io.open,path,"r")
  if not ok or not file then return nil,"Missing audio file: "..path end
  local success,result=pcall(function()
    local size=file:seek("end")
    assert(type(size)=="number" and size>=44 and size<=67108864,"Invalid WAV size")
    file:seek("set",0)
    local header=file:read(12)
    assert(type(header)=="string" and #header==12 and header:sub(1,4)=="RIFF" and header:sub(9,12)=="WAVE","Invalid RIFF/WAVE header")
    assert(u32(header,5)+8==size,"Truncated or inconsistent RIFF")
    local offset,fmt,dataSize,dataOffset=12,nil,nil,nil
    while offset+8<=size do
      file:seek("set",offset)
      local chunk=file:read(8)
      assert(type(chunk)=="string" and #chunk==8,"Truncated chunk header")
      local count=u32(chunk,5)
      assert(count and offset+8+count<=size,"Truncated WAV chunk")
      if chunk:sub(1,4)=="fmt " then
        assert(count>=16,"Invalid WAV format chunk")
        fmt=file:read(16)
      elseif chunk:sub(1,4)=="data" then
        assert(not dataSize,"Multiple audio data chunks")
        dataSize,dataOffset=count,offset+8
      end
      offset=offset+8+count+count%2
    end
    assert(fmt and #fmt==16,"Missing WAV format")
    assert(u16(fmt,1)==1,"Expected linear PCM")
    assert(u16(fmt,3)==1,"Expected mono audio")
    assert(u32(fmt,5)==32000,"Expected 32000 Hz")
    assert(u32(fmt,9)==64000 and u16(fmt,13)==2 and u16(fmt,15)==16,"Expected PCM16 little endian")
    assert(dataSize and dataSize>0 and dataSize%2==0,"Empty or unaligned audio data")
    return {bytes=size,dataOffset=dataOffset,dataBytes=dataSize,frames=dataSize/2,duration=dataSize/64000}
  end)
  pcall(function() file:close() end)
  if not success then return nil,tostring(result) end
  return result
end
return Wav
