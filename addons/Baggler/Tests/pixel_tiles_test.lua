-- Pixel-level tile check (offline fake client; says nothing about the real renderer, only about the geometry the
-- add-on hands it). Models a pixel-snapping renderer: every texture edge lands on round(absolute px).
-- For many scales / icon sizes / column counts / fractional window offsets it asserts:
--  * every tile's four edges (absolute) are whole physical pixels;
--  * the visible border on each of the 4 sides (tile edge -> icon edge after snapping) is >= 1 whole pixel,
--    so the icon never overlaps the border;
--  * the outline ring, fill and icon are pixel-snapped.
dofile('tests/harness/ca_stubs.lua')
local create = CreateFrame
local function record(region)
  function region:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = { ... } end
  function region:ClearAllPoints() self.points = {} end
  function region:SetSnapToPixelGrid(v) self.pixelSnap = v end
  function region:SetTexelSnappingBias(v) self.pixelBias = v end
  function region:SetColorTexture(...) self.color = { ... } end
  return region
end
CreateFrame = function(...)
  local f = record(create(...))
  local nm = select(2, ...)
  local ic = nm and _G[nm .. 'IconTexture']
  if ic then record(ic); ic.GetEffectiveScale = function() return f:GetEffectiveScale() end end   -- see every icon anchor
  function f:SetSize(w, h) self.w, self.h = w, h end
  function f:GetWidth() return self.w or 100 end
  function f:GetHeight() return self.h or 100 end
  function f:GetEffectiveScale() return self:GetScale() * (self.__parent and self.__parent:GetEffectiveScale() or 1) end
  local texture = f.CreateTexture
  function f:CreateTexture(name, layer, template, sublevel)
    local t = record(texture(self)); t.layer, t.sublevel = layer, sublevel
    function t:GetEffectiveScale() return self.__parent:GetEffectiveScale() end
    return t
  end
  return f
end
local PH = 1440
function GetPhysicalScreenSize() return 2560, PH end
function UnitClass() return 'Warrior', 'WARRIOR' end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, n, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
CB.Window:Open(); CB.Bank.window:Open()

local function round(x) return math.floor(x + 0.5 + 1e-9) end
local EPS = 1e-6
local failures, checked = 0, 0
local function bad(msg) failures = failures + 1; if failures <= 8 then print('FAIL ' .. msg) end end

for _, W in ipairs({ CB.Window, CB.Bank.window }) do
  local f = W.frame
  for _, scale in ipairs({ 0.65, 0.7, 0.8, 0.85, 0.94, 1, 1.1, 1.15, 1.3, 1.5 }) do
    for _, iconSize in ipairs({ 30, 36, 38, 40, 45 }) do
      for _, cols in ipairs({ 5, 8, 10, 12 }) do
        for _, parentOff in ipairs({ 0, 0.37, 0.5, 12.31, 100.73 }) do
          CB.db.iconSize, CB.db.columns = iconSize, cols
          CB.db.sizes = CB.db.sizes or {}; CB.db.sizes[W.opts.sizeKey] = nil
          f:SetScale(scale); CB.UI:Resnap(true)
          local ps = f.content:GetEffectiveScale() * PH / 768
          -- the window sits at a fractional screen offset (UI units of the window)
          f.content.GetLeft = function() return parentOff + 10.11 end
          f.content.GetTop = function() return 700 + parentOff * 0.77 end
          local items = {}
          for i = 1, cols * 2 + 3 do items[i] = { bag = 0, slot = i, key = 'k' .. i, name = 'x', icon = 1, quality = 1 } end
          W.sections = { { name = 'Test', items = items } }
          pcall(W.Layout, W)
          local L, T = f.content:GetLeft() * ps, f.content:GetTop() * ps
          for _, rec in ipairs(items) do
            local b = W:GetButton(rec.bag, rec.slot)
            local p = b and b.cbHolder.points and b.cbHolder.points[1]
            if p then
              checked = checked + 1
              local w = b.cbHolder.w
              local left = L + p[4] * ps
              local top = T + p[5] * ps               -- p[5] is negative (downward)
              local right, bottom = left + w * ps, top - w * ps
              local label = ('%s scale %.2f icon %d cols %d off %.2f #%d'):format(W.opts.frameName or '?', scale, iconSize, cols, parentOff, rec.slot)
              for name, v in pairs({ left = left, right = right, top = top, bottom = bottom }) do
                if math.abs(v - round(v)) > EPS then bad(label .. ': tile ' .. name .. ' edge at fractional pixel ' .. v) end
              end
              local icon = b.icon or b.Icon or _G[b:GetName() .. 'IconTexture']
              local d
              for _, ip in ipairs(icon.points or {}) do if ip[1] == 'TOPLEFT' then d = ip[4] end end
              if not d then bad(label .. ': icon has no inset anchor') else
                local dpx = d * ps
                local iL, iR = round(left + dpx), round(right - dpx)
                local iT, iB = round(top - dpx), round(bottom + dpx)
                local tL, tR, tT, tB = round(left), round(right), round(top), round(bottom)
                for side, width in pairs({ left = iL - tL, right = tR - iR, top = tT - iT, bottom = iB - tB }) do
                  if width < 1 then bad(label .. ': ' .. side .. ' border is ' .. width .. ' px') end
                end
              end
              if not (b.cbRing and b.cbRing.pixelSnap and icon.pixelSnap and b.cbBg.pixelSnap) then
                bad(label .. ': tile outline/icon is not pixel-snapped')
              end
            end
          end
        end
      end
    end
  end
end
assert(checked > 1000, 'the check inspected tiles (' .. checked .. ')')
if failures > 0 then print(('FAILED: %d pixel violations over %d tiles'):format(failures, checked)); os.exit(1) end
print(('PASS tile edges are whole physical pixels, all 4 border sides >= 1px, icon never overlaps (%d tiles, offline)'):format(checked))
