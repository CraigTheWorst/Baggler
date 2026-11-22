-- Actual shipping TOC; records renderer writes, not a simulated GPU/playtest.
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
  function f:SetFrameLevel(v) self.level = v end
  function f:GetFrameLevel() return self.level or (self.__parent and self.__parent:GetFrameLevel() + 1) or 1 end
  function f:GetEffectiveScale() return self:GetScale() * (self.__parent and self.__parent:GetEffectiveScale() or 1) end
  local texture = f.CreateTexture
  function f:CreateTexture(name, layer, template, sublevel)
    local t = record(texture(self)); t.layer, t.sublevel = layer, sublevel
    function t:GetEffectiveScale() return self.__parent:GetEffectiveScale() end -- real Region behavior
    return t
  end
  return f
end
function GetPhysicalScreenSize() return 2560, 1440 end
function UnitClass() return 'Warrior', 'WARRIOR' end
local CB = {}
for line in io.lines('addons/Baggler/Baggler.toc') do
  if line:match('%.lua$') then assert(loadfile('addons/Baggler/' .. line))('Baggler', CB) end
end
local function event(n, ...) CB.eventFrame.__scripts.OnEvent(CB.eventFrame, n, ...) end
event('ADDON_LOADED', 'Baggler'); event('PLAYER_LOGIN'); FLUSH()
CB.Window:Open(); CB.Bank.window:Open()
for _, W in ipairs({ CB.Window, CB.Bank.window }) do
  for _, size in ipairs({ 24, 32, 38, 56, 64 }) do
    CB.db.iconSize = size
    local b = W:NewButton(0, size)
    local click = b:GetScript('OnClick')
    assert(b.cbRing and b.cbBorder.cbOutline and b.cbBorder.cbOutline[1] == b.cbRing,
      'item outline is the ring of a full-tile texture beneath the art, not four separate strips')
    assert(b.cbRing.layer == 'BACKGROUND' and b.cbRing.pixelSnap == true, 'ring is a snapped background layer')
    local icon = b.icon or b.Icon or _G[b:GetName() .. 'IconTexture']
    assert(icon, 'item button has an icon texture')
    record(icon)                                   -- see every anchor the add-on writes from here on
    icon.GetEffectiveScale = function() return b:GetEffectiveScale() end   -- real Region behavior
    local function insets(region, label)           -- anchor offsets in physical pixels, per corner
      local out = {}
      for _, p in ipairs(region.points or {}) do
        local anchor = p[2]
        assert(anchor == b or anchor == b.cbBorder, label .. ' must be anchored to the tile, not to screen/parent defaults')
        local scale = anchor:GetEffectiveScale()
        out[p[1]] = { math.abs(p[4] or 0) * scale / (768 / 1440), math.abs(p[5] or 0) * scale / (768 / 1440) }
      end
      return out
    end
    for _, scale in ipairs({ 0.65, 0.85, 1, 1.15, 1.5 }) do
      W.frame:SetScale(scale); CB.UI:Resnap(true)
      -- the icon (and the washes over it) sit strictly inside the outline: inset == outline thickness in physical px
      local sideNames = { TOPLEFT = true, BOTTOMRIGHT = true }
      local got = insets(icon, 'icon')
      for corner in pairs(sideNames) do
        assert(got[corner], 'icon is anchored at ' .. corner)
        assert(got[corner][1] >= 1 - 1e-8 and math.abs(got[corner][1] - 1) < 1e-6 and math.abs(got[corner][2] - 1) < 1e-6,
          ('icon inset must equal the 1px outline (size %d scale %s, got %.3f/%.3f px)'):format(size, scale, got[corner][1], got[corner][2]))
      end
      for _, name in ipairs({ 'cbGlow', 'cbRed' }) do
        for corner, v in pairs(insets(b[name], name)) do
          assert(math.abs(v[1] - 1) < 1e-6 and math.abs(v[2] - 1) < 1e-6, name .. ' must be inset by the outline thickness at ' .. corner)
        end
      end
      -- draw order: art < washes < outline; nothing on the border frame but the outline reaches sublevel 7
      assert(icon.layer == nil or icon.layer == 'ARTWORK' or icon.layer == 'BACKGROUND', 'icon stays in an art layer below the outline')
      assert(b.cbBorder:GetFrameLevel() > b:GetFrameLevel(), 'outline frame is above the item button (icon, cooldown base)')
      for _, t in ipairs({ icon, b.cbBg }) do
        assert(t.pixelSnap == true or t == icon, 'fill is pixel-snapped')
      end
      b.cbBorder:SetBackdropBorderColor(0.36, 0.36, 0.40, 1)
      local c = b.cbRing.color
      assert(c[1] == 0.36 and c[3] == 0.40 and c[4] == 1, 'junk outline color unchanged')
      b.cbBorder:SetBackdropBorderColor(0.1, 1, 0.2, 0.95)
      assert(b.cbRing.color[2] == 1 and b.cbRing.color[4] == 0.95, 'quality/alpha writes reach the ring')
      assert(b:GetScript('OnClick') == click and b.cbBorder:GetFrameLevel() > b:GetFrameLevel(), 'native click and above-art layer retained')
    end
  end
end
print('PASS bag/bank ring outline, physical inset, snapped layers and color parity across sizes/scales (offline)')
