-- Offline fixture renderer: executes the shipped layout, draws its recorded
-- anchors. Approximate text metrics and placeholder art, NOT a game screenshot.
local CB, W, path = ...
local UI, f = CB.UI, W.frame
local function clean(t) return tostring(t or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '') end
local function esc(t) return clean(t):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;') end
local out = { '<svg xmlns="http://www.w3.org/2000/svg" width="850" height="740" viewBox="0 0 850 740">', '<rect width="850" height="740" fill="#101014"/>', '<g font-family="monospace" font-size="10" fill="#c4c4cc">', '<text x="20" y="22">OFFLINE real-TOC layout / approximate text metrics / placeholder bag art / NOT a screenshot</text>' }
local function rect(x, y, w, h, stroke)
  out[#out + 1] = ('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#191920" stroke="%s"/>'):format(x,y,w,h,stroke or '#555562')
end
local function text(x,y,t,color,anchor)
  out[#out + 1] = ('<text x="%s" y="%s" fill="%s" text-anchor="%s">%s</text>'):format(x,y,color or '#c4c4cc',anchor or 'start',esc(t))
end
CB.db.pad.map.PADLTRIGGER, CB.db.pad.map.PADRTRIGGER = 'collapse', 'filter'
CB.db.pad.style, CB.db.pad.hints, CB.db.showBagSlots, CB.db.showFooter = 'xbox', true, true, true
C_Container.ContainerIDToInventoryID = function(bag) return 19 + bag end
GetInventoryItemTexture = function(_, id) if id < 23 then return 'fixture-art' end end
C_Container.GetContainerNumSlots = function() return 16 end
C_Container.GetContainerNumFreeSlots = function(bag) return 8, bag == 2 and 32 or 0 end
W:UpdateBagSlots()
W.freeCount, W.totalSlots = 24, 80
W:UpdateFooter()
local top = 45
for _, spec in ipairs({ {376, false}, {376, true}, {736, true} }) do
  local width, merchant = spec[1], spec[2]
  MerchantFrame:SetShown(merchant)
  W.merchantOpen = merchant
  f.sellBtn:SetShown(merchant)
  f.sellBtn.text:SetText('Sell junk  12s 40c'); f.sellBtn:SetWidth(122)
  f.moneyText:SetText('123g 45s'); f.slotsText:SetText('56 / 80')
  W.innerW = width; W:ApplySize()
  rect(18, top, width + 24, W.footerH + W.hintH + 36, '#393944')
  text(30,top+17,(merchant and 'Vendor' or 'Bags') .. ' / ' .. (width+24) .. 'px window', '#5ec8ff')
  local ox, oy = 30, top + 28
  for _, b in ipairs(f.bagSlots) do
    if b:IsShown() then
      local p = b.__point; local x,y = ox+p[4], oy-p[5]
      rect(x,y,b:GetWidth(),b:GetHeight()); text(x+3,y+12,'bag','#747484')
      text(x+29,y+29,b.capacity:GetText(),'#ffffff','end'); text(x+3,y+10,b.specialty:GetText(),'#73d9bf')
    end
  end
  local p = f.moneyText.__point; text(ox+p[4],oy-p[5]+12,f.moneyText:GetText())
  p = f.slotsText.__point; text(ox+width+p[4],oy-p[5]+12,f.slotsText:GetText(),nil,'end')
  if merchant then
    p=f.sellBtn.__point; local x,y=ox+width-f.sellBtn:GetWidth()+p[4],oy-p[5]
    rect(x,y,f.sellBtn:GetWidth(),f.sellBtn:GetHeight()); text(x+7,y+14,f.sellBtn.text:GetText())
  end
  local hy = oy + W.footerH + 4
  for _, b in ipairs(f.hints.badges) do
    if b:IsShown() then
      p=b.__point; local x,y=ox+p[4],hy-p[5]
      rect(x,y,b:GetWidth(),b:GetHeight()); text(x+b:GetWidth()/2,y+12,b.text:GetText(),'#5ec8ff','middle')
    end
  end
  for _, pool in ipairs({ f.hints.labels, f.hints.slashes }) do
    for _, l in ipairs(pool) do
      if l:IsShown() then p=l.__point; text(ox+p[4],hy-p[5]+3,l:GetText()) end
    end
  end
  top = top + W.footerH + W.hintH + 52
end
out[#out+1] = '</g></svg>'
local file = assert(io.open(path, 'w')); file:write(table.concat(out, '\n')); file:close()
print('OFFLINE footer SVG: ' .. path)
