-- Radio-independent caller state. All sound and UI work belongs to adapters.
local Core = {}
Core.__index = Core

function Core.new(program, notify)
  assert(program and #program.steps >= 2, "Program requires start and finish")
  return setmetatable({program=program, cursor=0, pending=1, variants={}, notify=notify or function() end, revision=1}, Core)
end

function Core:emit(kind, fields)
  fields = fields or {}
  fields.type = kind
  self.notify(fields)
end

function Core:changed()
  self.revision = self.revision + 1
end

function Core:step(index)
  local original = self.program.steps[index]
  if not original then return nil end
  local selected = self.variants[original.id]
  if not selected or not original.variants then return original end
  for _, variant in ipairs(original.variants) do
    if variant.id == selected then
      local result = {}
      for key,value in pairs(original) do result[key]=value end
      for key,value in pairs(variant) do result[key]=value end
      result.id, result.number, result.kind = original.id, original.number, original.kind
      return result
    end
  end
  return original
end

function Core:current()
  local index = self.pending or math.max(1, self.cursor)
  return self:step(index), index, self.pending ~= nil
end

function Core:upcoming()
  local _, index = self:current()
  return self:step(index < #self.program.steps and index+1 or 1)
end

function Core:read(index, reason)
  self:emit("stop", {reason=reason})
  self.cursor, self.pending = index, nil
  self:changed()
  self:emit("call", {step=self:step(index), index=index, reason=reason})
end

function Core:next()
  local index = self.pending or (self.cursor >= #self.program.steps and 1 or self.cursor+1)
  self:read(index, "next")
end

function Core:repeatCurrent()
  self:read(self.pending or math.max(1,self.cursor), "repeat")
end

function Core:previous()
  self:read(math.max(1,(self.pending or self.cursor)-1), "previous")
end

function Core:reset(confirmation)
  self:emit("stop", {reason="reset"})
  self.cursor, self.pending = 0, 1
  self:changed()
  if confirmation then self:emit("confirmation", {name="ready"}) end
end

function Core:selectFigure(number)
  for index,step in ipairs(self.program.steps) do
    if step.kind == "figure" and step.number == number then
      self:emit("stop", {reason="select"})
      self.cursor, self.pending = index-1, index
      self:changed()
      return true
    end
  end
  return false
end

function Core:setProgram(program, variants)
  assert(program and #program.steps >= 2, "Invalid program")
  self.program, self.variants = program, variants or {}
  self:reset(false)
end

function Core:setVariant(stepId, variantId)
  for _,step in ipairs(self.program.steps) do
    if step.id == stepId and step.variants then
      for _,variant in ipairs(step.variants) do
        if variant.id == variantId then
          if self.variants[stepId] ~= variantId then
            self.variants[stepId] = variantId
            self:reset(false)
          end
          return true
        end
      end
    end
  end
  return false
end

function Core:interrupted()
  self:emit("stop", {reason="system-alert"})
  self:changed()
end

return Core
