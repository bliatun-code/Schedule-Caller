-- Schedule Caller loader for FrSky Ethos. Ethos loads every installed script at
-- power-on, so this file only registers the widget. The widget code in
-- lib/widget.lua is loaded when a model uses the widget and released again when
-- the last widget is destroyed, for example after a model change.
local BASE="SCRIPTS:/ScheduleCallerSportflyer/"
local widget
-- Ethos keeps the functions a widget gives to its menu and settings form, also after
-- the widget is destroyed. These small functions reach the widget code only through
-- `widget`, so a released widget can still be freed.
local bridges={}
local function bridge(key)
  local run=bridges[key]
  if not run then
    run=function(...) if widget then return widget.call(key,...) end end
    bridges[key]=run
  end
  return run
end
local function forward(name)
  return function(w,...)
    if widget then return widget[name](w,...) end
  end
end
local function create()
  if not widget then
    widget=dofile(BASE.."lib/widget.lua")
    widget.attach(bridge)
  end
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
  system.registerWidget({key="SchSprt",name="Schedule Caller Sportflyer",create=create,read=forward("read"),write=forward("write"),
    wakeup=forward("wakeup"),paint=forward("paint"),event=forward("event"),menu=forward("menu"),
    configure=forward("configure"),destroy=destroy,persistent=true,title=false})
end
return {init=init}
