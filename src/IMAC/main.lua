-- Schedule Caller loader for FrSky Ethos. Ethos loads every installed script at
-- power-on, so this file only registers the widget. The widget code in
-- lib/widget.lua is loaded when a model uses the widget and released again when
-- the last widget is destroyed, for example after a model change.
local BASE="SCRIPTS:/ScheduleCallerIMAC/"
local widget
local function forward(name)
  return function(w,...)
    if widget then return widget[name](w,...) end
  end
end
local function create()
  if not widget then widget=dofile(BASE.."lib/widget.lua") end
  return widget.create()
end
local function destroy(w)
  if not widget then return end
  widget.destroy(w)
  if widget.unused() then
    widget.release()
    widget=nil
  end
end
local function init()
  system.registerWidget({key="SchCal2",name="Schedule Caller IMAC",create=create,read=forward("read"),write=forward("write"),
    wakeup=forward("wakeup"),paint=forward("paint"),event=forward("event"),menu=forward("menu"),
    configure=forward("configure"),destroy=destroy,persistent=true,title=false})
end
return {init=init}
