-- Complete display plans are built outside paint. Painting only replays them.
-- Fonts and text bounds always come from the active Ethos LCD implementation.
local Render = {}
local imageLibrary
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local fontCache, wrapCache, wrapOrder = nil, {}, {}
local WRAP_CACHE_LIMIT = 32

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, fallback)
  return finite(value) and floor(value) or fallback
end

local function rect(x,y,w,h)
  return {x=floor(x), y=floor(y), w=max(0,floor(w)), h=max(0,floor(h))}
end

local function rgb(r,g,b)
  return lcd.RGB(r,g,b)
end

local function themeColor(name,fallback)
  local index = _G[name]
  if type(index) == "number" and type(lcd.themeColor) == "function" then
    local ok,color = pcall(lcd.themeColor,index)
    if ok and finite(color) then return color end
  end
  return fallback
end

local function palette(view)
  local white,black = rgb(255,255,255),rgb(0,0,0)
  if view.theme == "light" then
    return {bg=white, fg=black, panel=rgb(240,240,240), muted=rgb(64,64,64), border=rgb(160,160,160), warning=black}
  elseif view.theme == "dark" then
    return {bg=black, fg=white, panel=rgb(24,24,24), muted=rgb(202,202,202), border=rgb(110,110,110), warning=white}
  elseif view.theme == "custom" then
    local fg = finite(view.foreground) and view.foreground or white
    local bg = finite(view.background) and view.background or black
    return {bg=bg,fg=fg,panel=bg,muted=fg,border=fg,warning=fg}
  end
  local fg = themeColor("THEME_DEFAULT_COLOR",white)
  local bg = themeColor("THEME_DEFAULT_BGCOLOR",black)
  return {bg=bg,fg=fg,panel=themeColor("THEME_SECONDARY_BGCOLOR",bg),
    muted=themeColor("THEME_SECONDARY_COLOR",fg),
    border=themeColor("THEME_BUTTON_BORDER_COLOR",fg),
    warning=themeColor("THEME_WARNING_COLOR",fg)}
end

local function measure(font,text)
  lcd.font(font)
  local width,height = lcd.getTextSize(text)
  assert(finite(width) and finite(height) and width >= 0 and height >= 0,"Invalid Ethos text metrics")
  return width,height
end

local function fonts()
  if fontCache then return fontCache end
  local normal,bold,seen = {},{},{}
  for _,name in ipairs({"FONT_S","FONT_STD","FONT_M","FONT_L","FONT_XL","FONT_XXL"}) do
    local value = _G[name]
    if type(value) == "number" and not seen[value] then
      seen[value]=true
      local _,height = measure(value,"AgÅgj 01")
      if height > 0 then
        normal[#normal+1] = {font=value,h=height}
        local boldName=name.."_BOLD"
        local boldValue=_G[boldName]
        -- Only documented/exposed bold fonts; no guessed numeric font indexes.
        if type(boldValue) ~= "number" then boldValue=value end
        local _,boldHeight=measure(boldValue,"AgÅgj 01")
        bold[#bold+1]={font=boldValue,h=boldHeight}
      end
    end
  end
  assert(#normal > 0,"No usable Ethos system font")
  table.sort(normal,function(a,b) return a.h>b.h end)
  table.sort(bold,function(a,b) return a.h>b.h end)
  local small = _G.FONT_S or _G.FONT_STD or _G.FONT_M or 0
  local _,minimumHeight = measure(small,"AgÅgj 01")
  fontCache={normal=normal,bold=bold,minimumHeight=minimumHeight}
  return fontCache
end

local function nearestFont(target,bold)
  local candidates = bold and fonts().bold or fonts().normal
  local best,distance = candidates[1],math.huge
  for _,candidate in ipairs(candidates) do
    local nextDistance=abs(candidate.h-target)
    if nextDistance<distance then best,distance=candidate,nextDistance end
  end
  return best
end

local function smallerFonts(target,bold)
  local result,seen = {},{}
  local minimum=fonts().minimumHeight
  for _,candidate in ipairs(bold and fonts().bold or fonts().normal) do
    if candidate.h<=target*1.16 and candidate.h>=minimum-1 and not seen[candidate.font] then
      result[#result+1]=candidate;seen[candidate.font]=true
    end
  end
  if #result==0 then result[1]=nearestFont(minimum,bold) end
  return result
end

local function utf8chars(text)
  local chars={}
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars+1]=char end
  return chars
end

local function wrap(text,font,width)
  text=tostring(text or ""):gsub("\r\n","\n"):gsub("\r","\n")
  width=max(1,floor(width))
  local key=tostring(font)..":"..width..":"..text
  local cached=wrapCache[key]
  if cached then return cached end
  local lines={}
  local function append(line)
    local w,h=measure(font,line)
    lines[#lines+1]={text=line,w=w,h=h}
  end
  for paragraph in (text.."\n"):gmatch("(.-)\n") do
    local line=""
    for word in paragraph:gmatch("%S+") do
      local trial=line=="" and word or line.." "..word
      if measure(font,trial)<=width then
        line=trial
      else
        if line~="" then append(line);line="" end
        if measure(font,word)<=width then
          line=word
        else
          -- A source identifier or long word still remains accessible, split
          -- only at UTF-8 boundaries. Never cut a Norwegian character in half.
          for _,char in ipairs(utf8chars(word)) do
            if line~="" and measure(font,line..char)>width then append(line);line="" end
            line=line..char
          end
        end
      end
    end
    if line~="" then append(line) elseif paragraph=="" then append("") end
  end
  if #lines==0 then append("") end
  wrapCache[key]=lines;wrapOrder[#wrapOrder+1]=key
  if #wrapOrder>WRAP_CACHE_LIMIT then
    local old=table.remove(wrapOrder,1);wrapCache[old]=nil
  end
  return lines
end

local function addFill(plan,area,color)
  if area.w>0 and area.h>0 then
    plan.commands[#plan.commands+1]={op="fill",x=area.x,y=area.y,w=area.w,h=area.h,color=color}
  end
end

local function border(plan,area,color)
  addFill(plan,rect(area.x,area.y,area.w,1),color)
  addFill(plan,rect(area.x,area.y+area.h-1,area.w,1),color)
  addFill(plan,rect(area.x,area.y,1,area.h),color)
  addFill(plan,rect(area.x+area.w-1,area.y,1,area.h),color)
end

local function addText(plan,text,font,area,color,role,alignment)
  local w,h=measure(font,text)
  if text=="" then return end
  assert(w<=area.w and h<=area.h,"Text does not fit allocated rectangle: "..tostring(role))
  local x=area.x
  if alignment=="center" then x=x+floor((area.w-w)/2)
  elseif alignment=="right" then x=x+area.w-w end
  local y=area.y+floor((area.h-h)/2)
  plan.commands[#plan.commands+1]={op="text",x=x,y=y,text=text,font=font,color=color}
  plan.textBounds[#plan.textBounds+1]={x=x,y=y,w=w,h=h,rect=area,font=font,text=text,role=role}
end

local function elide(text,font,width)
  if measure(font,text)<=width then return text,false end
  local chars=utf8chars(text)
  local suffix="..."
  while #chars>0 and measure(font,table.concat(chars)..suffix)>width do table.remove(chars) end
  if measure(font,suffix)>width then return "",true end
  return table.concat(chars)..suffix,true
end

local function label(plan,text,target,area,color,role,alignment)
  local font=nearestFont(target,false)
  while font.h>area.h do
    local nextFont=nil
    for _,item in ipairs(fonts().normal) do if item.h<font.h and item.h<=area.h then nextFont=item;break end end
    if not nextFont then break end
    font=nextFont
  end
  local visible,truncated=elide(tostring(text or ""),font.font,area.w)
  if visible~="" then addText(plan,visible,font.font,area,color,role,alignment) end
  return font,truncated
end

local function displayText(text)
  text=tostring(text or "")
  -- Portable notation also works with older native fonts whose glyph sets do
  -- not contain the Unicode eighth fractions used in the source PDFs.
  for _,pair in ipairs({{"⅛","1/8"},{"⅜","3/8"},{"⅝","5/8"},{"⅞","7/8"},
      {"¼","1/4"},{"½","1/2"},{"¾","3/4"},{"’","'"},{"–","-"},{"—","-"}}) do
    text=text:gsub(pair[1],pair[2])
  end
  return text
end

local function titleOf(step,language,preview)
  if step and (step.kind=="start" or step.kind=="finish") then
    -- The message is already the body. Only previews need it as a caption.
    if not preview then return "" end
    return displayText(language=="en" and step.description_en or (step.description_nb or step.description_en))
  end
  return step and displayText(step.title_en) or "Choose a program"
end

local function descriptionOf(view)
  local step=view.step
  if not step then return "Configure the widget to select a flying program." end
  if view.language=="en" then return displayText(step.description_en) end
  return displayText(step.description_nb or step.description_en)
end

local function flow(title,body,width,titleFont,bodyFont,gap)
  local lines,total={},0
  local function append(items,font,role,after)
    for i,item in ipairs(items) do
      local height=max(font.h,item.h)
      local padding = i==#items and after or max(2,floor(font.h*.14))
      local line={text=item.text,w=item.w,h=item.h,font=font.font,role=role,rowHeight=height,padding=padding}
      lines[#lines+1]=line;total=total+height+padding
    end
  end
  if title~="" then append(wrap(title,titleFont.font,width),titleFont,"title",gap) end
  append(wrap(body,bodyFont.font,width),bodyFont,"description",0)
  return lines,total
end

local function chooseFlow(title,body,area,scale)
  local titleTarget=33*scale
  local bodyTarget=26*scale
  local gap=max(8,floor(14*scale))
  local best,bestScore,overflow=nil,-math.huge,nil
  for _,titleFont in ipairs(smallerFonts(titleTarget,true)) do
    for _,bodyFont in ipairs(smallerFonts(bodyTarget,false)) do
      local lines,total=flow(title,body,area.w,titleFont,bodyFont,gap)
      local score=titleFont.h*2+bodyFont.h*3
      local item={lines=lines,total=total,titleFont=titleFont,bodyFont=bodyFont}
      if total<=area.h and score>bestScore then best,bestScore=item,score end
      if not overflow or total<overflow.total then overflow=item end
    end
  end
  return best or overflow
end

local function visibleFlow(plan,current,area,requested)
  local lines=current.lines
  local maxScroll=0
  local sum=0
  for i=#lines,1,-1 do
    local line=lines[i]
    local required=line.rowHeight+(i<#lines and line.padding or 0)
    if sum+required>area.h then maxScroll=i;break end
    sum=sum+required
  end
  local scroll=min(maxScroll,max(0,integer(requested,0)))
  local y,last=area.y,scroll
  for i=scroll+1,#lines do
    local line=lines[i]
    if y+line.rowHeight>area.y+area.h then break end
    addText(plan,line.text,line.font,rect(area.x,y,area.w,line.rowHeight),plan.colors.fg,line.role)
    y=y+line.rowHeight+line.padding;last=i
  end
  plan.maxScroll,plan.scroll,plan.lastVisibleLine=maxScroll,scroll,last
  plan.lineCount=#lines
  plan.contentRect=area
  plan.contentLines=lines
  plan.fonts.title=current.titleFont
  plan.fonts.description=current.bodyFont
end

local function previewGeometry(view,content,scale,layout)
  if not view.preview or not view.nextStep then return nil,content end
  if layout=="diagram" then
    local font=nearestFont(max(14,18*scale),false)
    local height=font.h+max(6,floor(8*scale))
    local area=rect(content.x,content.y+content.h-height,content.w,height)
    return area,rect(content.x,content.y,content.w,content.h-height)
  end
  if layout=="briefing" then
    local width=max(112,floor(180*scale))
    local gap=max(12,floor(20*scale))
    local area=rect(content.x+content.w-width,content.y,width,content.h)
    return area,rect(content.x,content.y,max(80,content.w-width-gap),content.h)
  end
  local prefixWidth=max(80,floor(110*scale))
  local available=max(40,content.w-prefixWidth)
  local previewFont=nearestFont(max(18,23*scale),false)
  local lines=wrap(titleOf(view.nextStep,view.language,true),previewFont.font,available)
  local height=max(previewFont.h,#lines*(previewFont.h+3))+max(12,floor(16*scale))
  local limit=max(50,floor(86*scale))
  height=min(height,limit)
  local area=rect(content.x,content.y+content.h-height,content.w,height)
  return area,rect(content.x,content.y,content.w,content.h-height-max(10,floor(12*scale)))
end

local function drawPreview(plan,view,area,scale,layout)
  if not area then return end
  local p=plan.colors
  local step=view.nextStep
  local number=step.number and string.format("%02d",step.number) or nil
  plan.previewRect=area
  plan.nextTitle=titleOf(step,view.language,true)
  if layout=="diagram" then
    addFill(plan,rect(area.x,area.y,area.w,1),p.border)
    local prefix="NEXT  "..(number and number.."  " or "")
    local font=nearestFont(max(14,18*scale),false)
    local title,truncated=elide(prefix..plan.nextTitle,font.font,area.w)
    addText(plan,title,font.font,area,p.fg,"next-title")
    plan.previewTruncated=truncated
    return
  end
  if layout=="briefing" then
    addFill(plan,rect(area.x,area.y,1,area.h),p.border)
    local x=area.x+max(10,floor(20*scale))
    local width=area.w-(x-area.x)
    local headerHeight=max(24,floor(30*scale))
    label(plan,"NEXT",18*scale,rect(x,area.y,width,headerHeight),p.muted,"next-label")
    local y=area.y+headerHeight+max(6,floor(12*scale))
    if number then
      local numberFont=nearestFont(42*scale,false)
      addText(plan,number,numberFont.font,rect(x,y,width,numberFont.h),p.fg,"next-number")
      y=y+numberFont.h+max(8,floor(14*scale))
    end
    local font=nearestFont(max(18,24*scale),false)
    local titleArea=rect(x,y,width,area.y+area.h-y)
    local lines=wrap(titleOf(step,view.language,true),font.font,titleArea.w)
    local capacity=max(1,floor(titleArea.h/(font.h+3)))
    for i=1,min(#lines,capacity) do
      local text=lines[i].text
      if i==capacity and #lines>capacity then text=elide(text.." ...",font.font,titleArea.w);plan.previewTruncated=true end
      addText(plan,text,font.font,rect(x,y,titleArea.w,font.h),p.fg,"next-title")
      y=y+font.h+3
    end
  else
    addFill(plan,rect(area.x,area.y,area.w,1),p.border)
    local y=area.y+max(10,floor(14*scale))
    local lineHeight=max(26,floor(30*scale))
    local labelWidth=max(43,floor(56*scale))
    label(plan,"NEXT",17*scale,rect(area.x,y,labelWidth,lineHeight),p.muted,"next-label")
    local x=area.x+labelWidth+max(8,floor(12*scale))
    if number then
      local numberWidth=max(32,floor(40*scale))
      label(plan,number,25*scale,rect(x,y,numberWidth,lineHeight),p.fg,"next-number")
      x=x+numberWidth+max(8,floor(12*scale))
    end
    local width=area.x+area.w-x
    local font=nearestFont(max(18,23*scale),false)
    local lines=wrap(titleOf(step,view.language,true),font.font,width)
    local capacity=max(1,floor((area.y+area.h-y)/(font.h+3)))
    for i=1,min(capacity,#lines) do
      local text=lines[i].text
      if i==capacity and #lines>capacity then text=elide(text.." ...",font.font,width);plan.previewTruncated=true end
      addText(plan,text,font.font,rect(x,y,width,font.h),p.fg,"next-title")
      y=y+font.h+3
    end
  end
end

local function drawFigure(plan,view,area,scale,layout)
  local step=view.step or {}
  local p=plan.colors
  local labelText=view.ready and "READY" or step.kind=="figure" and "FIGURE"
    or step.kind=="start" and "START" or step.kind=="finish" and "DONE" or "TURN"
  local labelHeight=max(22,floor(26*scale))
  if layout=="daylight" then
    label(plan,labelText,18*scale,rect(area.x,area.y,max(58,floor(80*scale)),area.h),p.muted,"figure-label")
    if step.number then
      local x=area.x+max(62,floor(88*scale))
      local numberWidth=max(46,floor(60*scale))
      local numberFont=nearestFont(34*scale,true)
      label(plan,string.format("%02d",step.number),34*scale,rect(x,area.y,numberWidth,area.h),p.fg,"figure-number")
      local totalX=x+numberWidth+max(6,floor(10*scale))
      label(plan,"OF "..tostring(view.figureCount or ""),18*scale,rect(totalX,area.y,max(0,area.x+area.w-totalX),area.h),p.muted,"figure-total")
      plan.fonts.number={font=numberFont.font,h=numberFont.h,targetHeight=34*scale}
    end
    return
  end
  label(plan,labelText,17*scale,rect(area.x,area.y,area.w,labelHeight),p.muted,"figure-label")
  if step.number then
    local target=(layout=="deck" and 78 or 66)*scale
    local font=nearestFont(target,true)
    local y=area.y+labelHeight+max(3,floor(4*scale))
    local number=string.format("%02d",step.number)
    while measure(font.font,number)>area.w do
      local nextFont=nil
      for _,item in ipairs(fonts().bold) do if item.h<font.h then nextFont=item;break end end
      if not nextFont then break end
      font=nextFont
    end
    addText(plan,number,font.font,rect(area.x,y,area.w,font.h),p.fg,"figure-number")
    plan.fonts.number={font=font.font,h=font.h,targetHeight=target}
    y=y+font.h+max(7,floor(12*scale))
    label(plan,"OF "..tostring(view.figureCount or ""),18*scale,rect(area.x,y,area.w,labelHeight),p.muted,"figure-total")
  end
end

local function windArrow(plan,area,wind,color)
  local head=max(3,min(floor(area.h/2)-1,floor(area.w/3)))
  local cy=area.y+floor(area.h/2)
  local shaft=max(2,floor(head/2))
  if wind=="C" then
    addFill(plan,rect(area.x,cy-floor(shaft/2),area.w-head,shaft),color)
    local base=area.x+area.w-head-1
    for dy=-head,head do addFill(plan,rect(base,cy+dy,head-abs(dy)+1,1),color) end
  else
    addFill(plan,rect(area.x+head,cy-floor(shaft/2),area.w-head,shaft),color)
    for dy=-head,head do addFill(plan,rect(area.x+abs(dy),cy+dy,head-abs(dy)+1,1),color) end
  end
end

local function diagramPlan(plan,view,width,height,scale,headerHeight,errorHeight)
  local p=plan.colors
  local pad=max(8,floor(12*scale))
  local gap=max(4,floor(6*scale))
  local verticalPad=max(4,floor(6*scale))
  -- The shared error banner uses the ordinary outer margin. Match its top
  -- edge rather than allowing the diagram preview to extend into the banner.
  local bottomPad=view.error and max(10,floor(24*scale)) or verticalPad
  local available=rect(pad,headerHeight+verticalPad,width-pad*2,height-headerHeight-verticalPad-bottomPad-errorHeight)
  local preview,content=previewGeometry(view,available,scale,"diagram")
  local wind=view.imageWind=="C" and "C" or "B"
  local body=content
  if view.diagramTitle~=false and view.step and view.step.kind=="figure" then
    local font=nearestFont(max(16,22*scale),true)
    local rowHeight=font.h+max(4,floor(6*scale))
    local number=view.step.number and string.format("%02d  ",view.step.number) or ""
    local title,truncated=elide(number..titleOf(view.step),font.font,content.w)
    addText(plan,title,font.font,rect(content.x,content.y,content.w,rowHeight),p.fg,"title")
    plan.fonts.title=font;plan.titleTruncated=truncated
    body=rect(content.x,content.y+rowHeight,content.w,content.h-rowHeight)
  end
  plan.contentRect=body;plan.contentLines={};plan.lineCount=0;plan.scroll=0;plan.maxScroll=0;plan.lastVisibleLine=0
  plan.diagram=true;plan.imagePath=view.imagePath;plan.imageWind=wind
  local kind=view.step and view.step.kind
  if kind=="start" then
    local cardWidth=min(body.w,max(220,floor(340*scale)))
    local cardHeight=min(floor(body.h*.57),max(66,floor(96*scale)))
    local card=rect(body.x+floor((body.w-cardWidth)/2),body.y+max(0,floor(12*scale)),cardWidth,cardHeight)
    plan.windRect=card;plan.hitRects.wind=card
    local windPanel=p.panel
    if view.theme=="light" then windPanel=rgb(218,226,236)
    elseif view.theme=="dark" then windPanel=rgb(49,60,72) end
    addFill(plan,card,windPanel)
    border(plan,card,p.fg)
    border(plan,rect(card.x+1,card.y+1,card.w-2,card.h-2),p.fg)
    label(plan,"SELECT WIND",17*scale,rect(card.x+12,card.y+4,card.w-24,max(20,floor(25*scale))),p.muted,"wind-label","center")
    local arrow=rect(card.x+floor(card.w*.08),card.y+floor(card.h*.40),floor(card.w*.28),max(14,floor(card.h*.27)))
    windArrow(plan,arrow,wind,p.fg)
    label(plan,"Wind "..wind,28*scale,rect(card.x+floor(card.w*.42),card.y+floor(card.h*.30),floor(card.w*.50),max(25,floor(card.h*.44))),p.fg,"wind-selection","center")
    label(plan,"Tap to change",16*scale,rect(card.x+10,card.y+card.h-max(21,floor(23*scale)),card.w-20,max(20,floor(22*scale))),p.muted,"wind-hint","center")
    local instruction=rect(body.x,card.y+card.h+gap,body.w,max(0,body.y+body.h-card.y-card.h-gap))
    local f=nearestFont(max(18,30*scale),false)
    local lines=wrap(descriptionOf(view),f.font,instruction.w)
    local count=min(#lines,floor(instruction.h/(f.h+3)))
    local y=instruction.y+max(0,floor((instruction.h-count*(f.h+3))/2))
    for i=1,count do addText(plan,lines[i].text,f.font,rect(instruction.x,y,instruction.w,f.h),p.fg,"start-description","center");y=y+f.h+3 end
  elseif kind=="figure" and view.imagePath then
    local info=imageLibrary and imageLibrary:info(view.imagePath) or {}
    addFill(plan,body,rgb(255,255,255));border(plan,body,p.border)
    local inset=max(3,floor(4*scale))
    local allocation=rect(body.x+inset,body.y+inset,body.w-inset*2,body.h-inset*2)
    plan.imageRect=allocation
    if finite(info.width) and finite(info.height) and info.width>0 and info.height>0 then
      local fit=min(allocation.w/info.width,allocation.h/info.height)
      local dw,dh=max(1,floor(info.width*fit)),max(1,floor(info.height*fit))
      local target=rect(allocation.x+floor((allocation.w-dw)/2),allocation.y+floor((allocation.h-dh)/2),dw,dh)
      plan.imageBounds={x=target.x,y=target.y,w=target.w,h=target.h,rect=allocation,sourceWidth=info.width,sourceHeight=info.height,path=view.imagePath}
      plan.commands[#plan.commands+1]={op="bitmap",path=view.imagePath,x=target.x,y=target.y,w=target.w,h=target.h}
    end
    if info.status~="ready" then
      label(plan,"Loading diagram...",22*scale,body,rgb(0,0,0),"image-loading","center")
    end
  else
    local f=nearestFont(max(18,32*scale),false)
    local lines=wrap(descriptionOf(view),f.font,body.w)
    local count=min(#lines,floor(body.h/(f.h+4)))
    local y=body.y+max(0,floor((body.h-count*(f.h+4))/2))
    for i=1,count do addText(plan,lines[i].text,f.font,rect(body.x,y,body.w,f.h),p.fg,"instruction-description","center");y=y+f.h+4 end
  end
  drawPreview(plan,view,preview,scale,"diagram")
end

function Render.build(view,width,height)
  view=view or {}
  width,height=max(160,integer(width,800)),max(140,integer(height,480))
  local layout=view.layout
  if layout~="deck" and layout~="daylight" and layout~="briefing" then layout="focus" end
  local scale=min(width/800,height/480)
  if view.diagram and view.step and view.step.kind=="figure" then
    local info=view.imagePath and imageLibrary and imageLibrary:info(view.imagePath)
    if not view.imagePath or not info or info.error then
      local fallback={};for key,value in pairs(view) do fallback[key]=value end
      fallback.diagram=false
      fallback.error=view.error or ((info and info.error) or "Diagram is not installed")..". Text shown."
      local plan=Render.build(fallback,width,height)
      plan.diagram=true;plan.diagramFallback=true;plan.imageWind=view.imageWind
      return plan
    end
  end
  local pad=max(10,floor(24*scale))
  local gap=max(10,floor(20*scale))
  local headerHeight=max(44,floor(56*scale))
  local p=palette(view)
  local plan={width=width,height=height,layout=layout,colors=p,commands={},textBounds={},fonts={},
    hitRects={},ready=view.ready==true,programName=tostring(view.programName or "Schedule Caller"),
    stepId=view.step and view.step.id,nextStepId=view.nextStep and view.nextStep.id}
  addFill(plan,rect(0,0,width,height),p.bg)
  if layout=="deck" then addFill(plan,rect(0,0,width,headerHeight),p.panel) end
  addFill(plan,rect(0,headerHeight-1,width,layout=="daylight" and 2 or 1),layout=="daylight" and p.fg or p.border)
  local brandWidth=min(floor(width*.55),max(140,floor(390*scale)))
  label(plan,"Schedule Caller IMAC",24*scale,rect(pad,0,brandWidth,headerHeight-1),p.fg,"brand")
  local programX=pad+brandWidth+gap
  local windWidth=view.diagram and max(43,floor(72*scale)) or 0
  local programRect=rect(programX,0,max(0,width-pad-programX-windWidth),headerHeight-1)
  label(plan,plan.programName,21*scale,programRect,p.muted,"program","right")
  if view.diagram then
    local wind=view.imageWind=="C" and "C" or "B"
    local windX=width-pad-windWidth+max(5,floor(9*scale))
    local arrowWidth=max(19,floor(32*scale))
    local arrowHeight=max(10,floor(15*scale))
    windArrow(plan,rect(windX,floor((headerHeight-arrowHeight)/2),arrowWidth,arrowHeight),wind,p.muted)
    local labelX=windX+arrowWidth+3
    label(plan,wind,18*scale,rect(labelX,0,width-pad-labelX,headerHeight-1),p.muted,"wind-indicator","right")
  end


  -- This strip is reserved in every plan, including idle ones. A queued request
  -- never changes text wrapping, scroll targets, preview or bitmap allocation.
  local statusFont=nearestFont(18*scale,false)
  local statusHeight=statusFont.h+6
  local contentHeight=max(headerHeight,height-statusHeight)
  plan.statusRect=rect(0,contentHeight,width,height-contentHeight)
  local queueWidth=measure(statusFont.font,"Call queued")
  plan.queueRect=rect(max(0,width-pad-queueWidth),contentHeight,min(queueWidth,width-pad),statusHeight)
  plan.queued=view.queued==true
  local errorHeight=view.error and max(44,floor(54*scale)) or 0
  if view.diagram then
    diagramPlan(plan,view,width,contentHeight,scale,headerHeight,errorHeight)
  else
  local available=rect(pad,headerHeight+pad,width-pad*2,contentHeight-headerHeight-pad*2-errorHeight)
  local preview,content=previewGeometry(view,available,scale,layout)
  local figureArea
  if layout=="daylight" then
    local figureHeight=max(32,floor(43*scale))
    figureArea=rect(content.x,content.y,content.w,figureHeight)
    content=rect(content.x,content.y+figureHeight+max(8,floor(12*scale)),content.w,content.h-figureHeight-max(8,floor(12*scale)))
  else
    local col=(layout=="deck" and 110 or layout=="briefing" and 65 or 100)*scale
    col=max(layout=="briefing" and 46 or 58,floor(col))
    figureArea=rect(content.x,content.y,col,content.h)
    if layout=="deck" then
      figureArea.h=available.h
      addFill(plan,rect(figureArea.x+figureArea.w,figureArea.y,1,figureArea.h),p.border)
      if preview then preview=rect(preview.x+col+gap,preview.y,preview.w-col-gap,preview.h) end
    end
    content=rect(content.x+col+gap,content.y,content.w-col-gap,content.h)
  end
  local current=chooseFlow(titleOf(view.step),descriptionOf(view),content,scale)
  local footerHeight=0
  if current.total>content.h then
    footerHeight=max(34,floor(40*scale))
    content=rect(content.x,content.y,content.w,content.h-footerHeight)
    current=chooseFlow(titleOf(view.step),descriptionOf(view),content,scale)
  end
  visibleFlow(plan,current,content,view.scroll)
  drawFigure(plan,view,figureArea,scale,layout)
  drawPreview(plan,view,preview,scale,layout)

  if footerHeight>0 then
    local footer=rect(content.x,content.y+content.h,content.w,footerHeight)
    plan.footerRect=footer;plan.hitRects.footer=footer
    addFill(plan,rect(footer.x,footer.y,footer.w,1),p.border)
    local buttonWidth=max(52,floor(70*scale))
    local down=rect(footer.x+footer.w-buttonWidth,footer.y+3,buttonWidth,footer.h-5)
    local up=rect(down.x-buttonWidth-8,down.y,buttonWidth,down.h)
    plan.scrollUpRect,plan.scrollDownRect=up,down
    plan.hitRects.scrollUp,plan.hitRects.scrollDown=up,down
    border(plan,up,p.border);border(plan,down,p.border)
    label(plan,"Up",17*scale,up,plan.scroll>0 and p.fg or p.muted,"scroll-up","center")
    label(plan,"Down",17*scale,down,plan.scroll<plan.maxScroll and p.fg or p.muted,"scroll-down","center")
    local counter=string.format("%d-%d / %d",plan.scroll+1,plan.lastVisibleLine,plan.lineCount)
    label(plan,counter,16*scale,rect(footer.x,footer.y+2,max(0,up.x-footer.x-8),footer.h-4),p.muted,"scroll-range")
  end
  end
  if view.error then
    local area=rect(pad,contentHeight-pad-errorHeight,width-pad*2,errorHeight)
    addFill(plan,rect(area.x,area.y,area.w,1),p.warning)
    local font=nearestFont(max(18,20*scale),false)
    local lines=wrap(tostring(view.error),font.font,area.w)
    local capacity=max(1,floor((area.h-6)/(font.h+2)))
    local y=area.y+5
    for i=1,min(capacity,#lines) do
      local text=lines[i].text
      if i==capacity and #lines>capacity then text=elide(text.." ...",font.font,area.w) end
      addText(plan,text,font.font,rect(area.x,y,area.w,font.h),p.warning,"error")
      y=y+font.h+2
    end
    plan.errorRect=area
  end
  if plan.queued then
    addText(plan,"Call queued",statusFont.font,plan.queueRect,rgb(255,0,0),"queued","right")
  end
  plan.footerRect=plan.footerRect or rect(0,height,0,0)
  return plan
end

function Render.paint(plan)
  if not plan then return end
  local lastColor,lastFont
  -- Respect the clipping rectangle installed by Ethos. All text is already
  -- measured and wholly inside its allocation; no paint-time clipping reset
  -- may punch through an Ethos menu or another overlay.
  for _,command in ipairs(plan.commands) do
    if command.color~=nil and command.color~=lastColor then lcd.color(command.color);lastColor=command.color end
    if command.op=="fill" then
      lcd.drawFilledRectangle(command.x,command.y,command.w,command.h)
    elseif command.op=="text" then
      if command.font~=lastFont then lcd.font(command.font);lastFont=command.font end
      lcd.drawText(command.x,command.y,command.text)
    elseif command.op=="bitmap" then
      local bitmap=imageLibrary and imageLibrary:peek(command.path)
      if bitmap then lcd.drawBitmap(command.x,command.y,bitmap,command.w,command.h) end
    end
  end
end

function Render.setImageLibrary(library) imageLibrary=library end

function Render.clearCache()
  fontCache,wrapCache,wrapOrder=nil,{},{}
end

return Render
