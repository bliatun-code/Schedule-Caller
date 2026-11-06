-- Momentary button recogniser. Time is monotonic seconds from the adapter.
local Buttons = {}
Buttons.__index = Buttons

function Buttons.new(emit, options)
  options = options or {}
  return setmetatable({emit=emit,doubleTime=options.doubleTime or .28,holdTime=options.holdTime or .85,dedicatedReset=options.dedicatedReset~=false,last={},armed=false},Buttons)
end

function Buttons:clear()
  self.last, self.downAt, self.due, self.second, self.held, self.armed = {},nil,nil,false,false,false
end

function Buttons:poll(now, nextPressed, repeatPressed, resetPressed)
  if self.lastTime and now < self.lastTime then self:clear() end
  self.lastTime = now
  -- Re-arm only after all controls are released, including after model change.
  if not self.armed then
    if not nextPressed and not repeatPressed and not resetPressed then self.armed=true end
    self.last={next=nextPressed,repeatButton=repeatPressed,reset=resetPressed}
    return
  end
  local previous=self.last
  self.last={next=nextPressed,repeatButton=repeatPressed,reset=resetPressed}
  if self.dedicatedReset and resetPressed and not previous.reset then
    self.due,self.downAt,self.second,self.held=nil,nil,false,false
    self.emit("reset")
    return
  end
  if nextPressed and not previous.next then
    self.due,self.downAt,self.second,self.held=nil,nil,false,false
    self.emit("next")
    return
  end
  if repeatPressed and not previous.repeatButton then
    -- If wakeup first sees another tap after the deadline, the earlier tap is
    -- already a single. Deliver it before arming the new gesture.
    if self.due and now>self.due then
      self.due=nil
      self.emit("repeat")
    end
    self.downAt,self.held=now,false
    self.second=self.due~=nil and now<=self.due
    if self.second then self.due=nil end
  end
  if repeatPressed and not self.dedicatedReset and self.downAt and not self.held and now-self.downAt>=self.holdTime then
    self.held,self.due,self.second=true,nil,false
    self.emit("reset")
  end
  if not repeatPressed and previous.repeatButton then
    if not self.held and self.downAt then
      if not self.dedicatedReset and now-self.downAt>=self.holdTime then
        self.emit("reset");self.due=nil
      elseif self.second then self.emit("previous");self.due=nil else self.due=now+self.doubleTime end
    end
    self.downAt,self.held,self.second=nil,false,false
  end
  if self.due and not repeatPressed and now>=self.due then
    self.due=nil
    self.emit("repeat")
  end
end

return Buttons
