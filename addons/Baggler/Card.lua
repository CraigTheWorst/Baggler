-- Baggler item card: a read-only panel beside the bags (and the bank, vendor, mail, trade and loot windows) that
-- describes the highlighted item and keeps describing it while the highlight rests there, so a controller player
-- can read it without a mouse tooltip. Gear also gets a card for each piece worn in the slots it would fill.
-- Toggles: the window menu, Settings, or /baggler card.
local ADDON, CB = ...
local NewFrame = function(...) return CB.NewFrame(...) end
local UI = CB.UI
local Card = {}
CB.Card = Card

-- Card geometry, in card units (the whole card is scaled with the windows).
local WIDTH = 300            -- every card is this wide
local SIDE_GAP = 6           -- space between the window and a card, and between cards
local EDGE = 10              -- inner margin
local ICON_SIZE = 34
local HEAD_TO_BODY = 8       -- space between the header and the first body row
local LINE_GAP = 3           -- added under every text row
local SPACER_HEIGHT = 6
local RULE_MARGIN = 4
local RIGHT_GUTTER = 10      -- keeps a left text clear of a right-aligned value
local MIN_LINE = 12
local ROW_LIMIT = 48         -- rows past this are not drawn
local SCREEN_MARGIN = 40     -- a card never grows taller than the screen minus this
local QUESTION_MARK = 134400
Card.contentWidth, Card.rowLimit = WIDTH - EDGE * 2, ROW_LIMIT

function Card:Enabled() return CB.db and CB.db.itemCard ~= false and C_TooltipInfo and true or false end

function Card:Toggle()
  CB.db.itemCard = not (CB.db.itemCard ~= false)
  if not CB.db.itemCard then Card:HideAll() end
  CB:Print("item card " .. (CB.db.itemCard and "on" or "off") .. ".")
end

---------------------------------------------------------------------------
-- Colours. A colour is one { r, g, b } table; tooltip data hands us colour objects with the same fields.
---------------------------------------------------------------------------
local function rgb(r, g, b) return { r = r, g = g, b = b } end

local WHITE = rgb(1, 1, 1)
local KNOWN_RED = rgb(1, 0.2, 0.2)
local EMPTY_GREEN = rgb(0.55, 1, 0.55)

-- The game's ordinary tooltip text colour, read each time (another add-on or a client update may change it).
local function tooltipColour()
  local c = rawget(_G, "NORMAL_FONT_COLOR")
  if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
    return rgb(c.r, c.g, c.b)
  end
  return rgb(1, 0.82, 0)
end

local function colourOr(c, fallback)
  if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
    return rgb(c.r, c.g, c.b)
  end
  return fallback or tooltipColour()
end

local function named(key)
  local c = CB.COLOR[key]
  return rgb(c[1], c[2], c[3])
end

---------------------------------------------------------------------------
-- Card body: an ordered list of rows. { kind = "text", left, right, leftColour, rightColour }, { kind = "space" }
-- or { kind = "rule" }. Spaces collapse: never first, never two in a row, and trailing ones are dropped on paint.
---------------------------------------------------------------------------
local Body = {}
Body.__index = Body

local function newBody() return setmetatable({ rows = {} }, Body) end

function Body:Text(left, leftColour, right, rightColour)
  self.rows[#self.rows + 1] = { kind = "text", left = left or "", right = right,
    leftColour = leftColour or tooltipColour(), rightColour = rightColour or tooltipColour() }
end

function Body:Space()
  local last = self.rows[#self.rows]
  if last and last.kind ~= "space" then self.rows[#self.rows + 1] = { kind = "space" } end
end

function Body:Rule()
  self.rows[#self.rows + 1] = { kind = "rule" }
end

function Body:HasLeft(text)
  for _, row in ipairs(self.rows) do
    if row.kind == "text" and row.left == text then return true end
  end
  return false
end

function Body:Trimmed()
  local rows = self.rows
  while rows[#rows] and rows[#rows].kind == "space" do rows[#rows] = nil end
  return rows
end

local function present(s) return type(s) == "string" and s ~= "" end

--- Tooltip lines after the first (the first is the card's title) appended to `body`.
local function addTooltipLines(body, data)
  local lines = type(data) == "table" and type(data.lines) == "table" and data.lines or {}
  for i = 2, #lines do
    local line = lines[i]
    if type(line) == "table" then
      local left = present(line.leftText) and line.leftText or nil
      local right = present(line.rightText) and line.rightText or nil
      if not left and not right then
        body:Space()
      else
        body:Text(left or "", colourOr(line.leftColor), right, right and colourOr(line.rightColor) or nil)
      end
    end
  end
end

--- Title text and colour from tooltip line 1, with a fallback text.
local function titleFrom(data, fallback)
  local first = type(data) == "table" and type(data.lines) == "table" and data.lines[1]
  first = type(first) == "table" and first or {}
  local text = present(first.leftText) and first.leftText or fallback or ""
  return text, colourOr(first.leftColor)
end

---------------------------------------------------------------------------
-- Frames: the main card and up to two cards for worn gear (rings and trinkets have two slots)
---------------------------------------------------------------------------
Card.frames = {}

local function buildCard(globalName)
  UI:MakeFonts()
  local f = NewFrame("Frame", globalName, UIParent, "BackdropTemplate")
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:EnableMouse(false)
  f:SetWidth(WIDTH)
  UI:Backdrop(f, UI.bg, UI.border, CB.db.bgAlpha)
  UI:Shadow(f)

  f.wash = f:CreateTexture(nil, "BORDER")
  f.wash:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  f.wash:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(ICON_SIZE, ICON_SIZE)
  f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE, -EDGE)
  f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  local textLeft = EDGE + ICON_SIZE + 8
  f.name = f:CreateFontString(nil, "OVERLAY", "BagglerFontTitle")
  f.name:SetJustifyH("LEFT")
  f.name:SetWordWrap(false)
  f.name:SetPoint("TOPLEFT", f, "TOPLEFT", textLeft, -EDGE)
  f.name:SetWidth(WIDTH - textLeft - EDGE)

  f.sub = f:CreateFontString(nil, "OVERLAY", "BagglerFontMuted")
  f.sub:SetJustifyH("LEFT")
  f.sub:SetWordWrap(false)
  f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -2)
  f.sub:SetWidth(WIDTH - textLeft - EDGE)

  f.lines = {}
  f:Hide()
  Card.frames[#Card.frames + 1] = f
  return f
end

local function mainFrame()
  if not Card.frame then Card.frame = buildCard("BagglerCard") end
  return Card.frame
end

local function compareFrame(i)
  Card.cmp = Card.cmp or {}
  if not Card.cmp[i] then Card.cmp[i] = buildCard("BagglerCardCompare" .. i) end
  return Card.cmp[i]
end

-- One reusable row widget set: a left text, a right text and a hairline for rule rows.
local function lineWidgets(f, i)
  local w = f.lines[i]
  if w then return w end
  w = {}
  w.left = f:CreateFontString(nil, "OVERLAY", "BagglerFont")
  w.left:SetJustifyH("LEFT")
  w.left:SetWordWrap(true)
  w.right = f:CreateFontString(nil, "OVERLAY", "BagglerFont")
  w.right:SetJustifyH("RIGHT")
  w.right:SetWordWrap(false)
  w.rule = f:CreateTexture(nil, "ARTWORK")
  w.rule:SetColorTexture(1, 1, 1, 0.12)
  UI:Line(w.rule, "h", 1)
  f.lines[i] = w
  return w
end

local function hideWidgets(w)
  w.left:Hide(); w.right:Hide(); w.rule:Hide()
end

local function heightLimit()
  local scale = (CB.db and CB.db.scale) or 1
  return (UIParent:GetHeight() or 768) / scale - SCREEN_MARGIN
end

--- Draws a header ({ icon, title, titleColour, sub, subColour }) and a list of body rows onto card `f`.
local function paint(f, head, rows)
  local content = WIDTH - EDGE * 2
  f.icon:SetTexture(head.icon or QUESTION_MARK)
  f.name:SetText(head.title or "")
  local tc = head.titleColour or tooltipColour()
  f.name:SetTextColor(tc.r, tc.g, tc.b)
  f.sub:SetText(head.sub or "")
  local sc = head.subColour or named("muted")
  f.sub:SetTextColor(sc.r, sc.g, sc.b)

  local textHeight = math.ceil(f.name:GetStringHeight() or 0) + 2 + math.ceil(f.sub:GetStringHeight() or 0)
  local headHeight = math.max(ICON_SIZE, textHeight)
  f.wash:SetHeight(EDGE + headHeight)
  UI:Fade(f.wash, tc.r, tc.g, tc.b, 0.20, 0)

  local limit = heightLimit()
  local y = EDGE + headHeight + HEAD_TO_BODY
  local used, drawn = 0, {}
  for _, row in ipairs(rows) do
    if used >= ROW_LIMIT then break end
    local w = lineWidgets(f, used + 1)
    hideWidgets(w)
    local nextY
    if row.kind == "space" then
      nextY = y + SPACER_HEIGHT
    elseif row.kind == "rule" then
      w.rule:ClearAllPoints()
      w.rule:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE, -(y + RULE_MARGIN))
      w.rule:SetWidth(content)
      nextY = y + RULE_MARGIN * 2 + 1
    else
      local leftWidth = content
      if row.right then
        w.right:SetWidth(0)
        w.right:SetText(row.right)
        local rightWidth = math.min(math.ceil(w.right:GetStringWidth() or 0), content - 60)
        w.right:SetWidth(rightWidth)
        w.right:ClearAllPoints()
        w.right:SetPoint("TOPRIGHT", f, "TOPRIGHT", -EDGE, -y)
        w.right:SetTextColor(row.rightColour.r, row.rightColour.g, row.rightColour.b)
        leftWidth = content - rightWidth - RIGHT_GUTTER
      end
      w.left:SetWidth(leftWidth)
      w.left:SetText(row.left)
      w.left:ClearAllPoints()
      w.left:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE, -y)
      w.left:SetTextColor(row.leftColour.r, row.leftColour.g, row.leftColour.b)
      nextY = y + math.max(MIN_LINE, math.ceil(w.left:GetStringHeight() or 0)) + LINE_GAP
    end
    if nextY + EDGE > limit then break end                 -- the rest would run off the screen
    if row.kind == "rule" then w.rule:Show()
    elseif row.kind == "text" then
      w.left:Show()
      if row.right then w.right:Show() end
    end
    used = used + 1
    drawn[used] = row
    y = nextY
  end
  for i = used + 1, #f.lines do hideWidgets(f.lines[i]) end
  f.drawn = drawn                                          -- what is on the card now (read by tests and diagnostics)
  local last = drawn[#drawn]
  if last and last.kind == "text" then y = y - LINE_GAP end
  f:SetHeight(math.min(y + EDGE, limit))
  f:SetBackdropColor(UI.bg[1], UI.bg[2], UI.bg[3], CB.db.bgAlpha)
end

---------------------------------------------------------------------------
-- Item facts
---------------------------------------------------------------------------
local GetItemCountFn = (C_Item and C_Item.GetItemCount) or rawget(_G, "GetItemCount")

local function carried(id)
  if not id or not GetItemCountFn then return nil end
  local ok, n = pcall(GetItemCountFn, id)
  if ok and type(n) == "number" then return n end
end

--- The "on other characters" total, or nil when that setting is off or nobody else has the item.
local function elsewhereTotal(id)
  if not (id and CB.Extras and CB.db.showAltCounts) then return nil end
  local ok, lines, total = pcall(CB.Extras.CountLines, CB.Extras, id)
  if ok and type(lines) == "table" and #lines > 0 then return total end
end

--- Fact rows for an item known by id: the caller's own rows first, then what is carried and held elsewhere.
local function itemFacts(id, extra)
  local facts = {}
  for _, row in ipairs(extra or {}) do facts[#facts + 1] = row end
  facts[#facts + 1] = { left = "Carried", right = tostring(carried(id) or 0) }
  local elsewhere = elsewhereTotal(id)
  if elsewhere then facts[#facts + 1] = { left = "Elsewhere", right = tostring(elsewhere) } end
  return facts
end

--- id, equip location, icon, class and item level from a hyperlink (each nil when the client cannot say).
local function linkInfo(link)
  if type(link) ~= "string" then return nil end
  local id, equipLoc, icon, classID
  local instant = (C_Item and C_Item.GetItemInfoInstant) or rawget(_G, "GetItemInfoInstant")
  if instant then
    local ok, a, _, _, d, e, f = pcall(instant, link)
    if ok then id, equipLoc, icon, classID = a, d, e, f end
  end
  id = id or tonumber(link:match("item:(%d+)"))
  local ilvl = CB.ComparisonHost and CB.ComparisonHost:Level(link) or nil
  return id, equipLoc, icon, classID, ilvl
end

local function className(classID)
  if not (classID and C_Item and C_Item.GetItemClassInfo) then return nil end
  local ok, label = pcall(C_Item.GetItemClassInfo, classID)
  if ok and present(label) then return label end
end

local function levelText(ilvl)
  if type(ilvl) == "number" and ilvl > 1 then return "ilvl " .. math.floor(ilvl) end
end

---------------------------------------------------------------------------
-- Cards for what is worn
---------------------------------------------------------------------------
local function tinted(line)
  if line.sign == "positive" then return CB.HEX.gain .. line.text .. "|r" end
  if line.sign == "negative" then return CB.HEX.loss .. line.text .. "|r" end
  return line.text
end

--- Header + rows for each comparison card the item gets (an empty list when it gets none).
local function wornCards(spec)
  local host = CB.ComparisonHost
  if not host or CB.db.cardCompare == false or spec.noCompare then return {} end
  local ok, view = pcall(function()
    local candidate = { link = spec.link, equipLoc = spec.equipLoc, native = host:Identity(spec.data) }
    return host:New():Compare(candidate, { compareEnabled = CB.db.cardCompare ~= false, noCompare = spec.noCompare })
  end)
  if not ok or type(view) ~= "table" then return {} end
  if view.empty then
    return { { head = { icon = QUESTION_MARK, title = "Nothing equipped", titleColour = EMPTY_GREEN,
      sub = "No readable equipped item in this slot" }, rows = {} } }
  end
  local out = {}
  for _, alternative in ipairs(view.alternatives or {}) do
    if #out == 2 then break end
    local item = alternative.item or {}
    if type(item.data) == "table" then
      local body = newBody()
      addTooltipLines(body, item.data)
      for _, change in ipairs(view.deltas or {}) do
        if change.slot == alternative.slot then
          body:Space()
          body:Text(ITEM_DELTA_DESCRIPTION or "Stat change", tooltipColour())
          for _, line in ipairs(change.lines or {}) do
            if type(line) == "table" and present(line.text) then body:Text(tinted(line), WHITE) end
          end
        end
      end
      local title, colour = titleFrom(item.data, item.link)
      local level = levelText(item.ilvl)
      out[#out + 1] = { head = { icon = item.icon, title = title, titleColour = colour,
        sub = "Worn now" .. (level and ("   " .. level) or ""), subColour = named("gold") }, rows = body:Trimmed() }
    end
  end
  return out
end

---------------------------------------------------------------------------
-- "Already known": the game's tooltip says it for recipes, grimoires, pets, mounts and appearances, but the
-- tooltip data does not always carry the line. A hidden tooltip is filled the old way and read for it.
---------------------------------------------------------------------------
local scanTip

local function plainPattern(fmt)
  -- a game string such as "Collected (%d/%d)" turned into a pattern that matches any numbers
  return "^" .. fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%d", "%%d+"):gsub("%%%%s", ".+")
end

local KNOWN_STRINGS = { "ITEM_SPELL_KNOWN", "ITEM_PET_KNOWN", "TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN", "ITEM_COSMETIC_LEARNED" }

local function isKnownText(text)
  for _, key in ipairs(KNOWN_STRINGS) do
    local str = _G[key]
    if type(str) == "string" and str ~= "" then
      if text == str or text:find(plainPattern(str)) then return true end
    end
  end
  return false
end

--- The "already known" style line for an item, or nil. `fill(tip)` points the hidden tooltip at the item.
local function knownLine(fill)
  if not fill then return nil end
  if not scanTip then
    local ok, tip = pcall(CreateFrame, "GameTooltip", "BagglerScanTip", UIParent, "GameTooltipTemplate")
    if not ok or not tip then scanTip = false; return nil end
    scanTip = tip
  end
  if not scanTip then return nil end
  scanTip:SetOwner(UIParent, "ANCHOR_NONE")
  scanTip:ClearLines()
  if not pcall(fill, scanTip) then return nil end
  for i = 2, scanTip:NumLines() do
    local fs = _G["BagglerScanTipTextLeft" .. i]
    local text = fs and fs:GetText()
    if text and isKnownText(text) then return text end
  end
end

---------------------------------------------------------------------------
-- Grimoires and spell books: the tooltip never says "Already known" for them, the game only refuses at use
-- ("your demon already knows that"). So the spell the item teaches is looked for in the book of the demon that is
-- out (and in the player's own): the tooltip names it as "Firebolt (Rank 1)", the spell book as "Firebolt" + "Rank 1".
---------------------------------------------------------------------------
local reportedBooks

--- "name (rank)" strings (lower case) for every spell of a book: "pet" or "spell".
local function bookEntries(bank)
  local out = {}
  local isPet = bank == "pet"
  local SB = C_SpellBook
  local count
  if isPet then
    if HasPetSpells then count = select(1, HasPetSpells()) end
  elseif GetNumSpells then
    count = GetNumSpells()
  end
  count = tonumber(count) or 0
  local nameOf
  if SB and SB.GetSpellBookItemName and Enum and Enum.SpellBookSpellBank then
    local b = isPet and Enum.SpellBookSpellBank.Pet or Enum.SpellBookSpellBank.Player
    nameOf = function(i) return SB.GetSpellBookItemName(i, b) end
  elseif GetSpellBookItemName then
    nameOf = function(i) return GetSpellBookItemName(i, bank) end
  elseif GetSpellName then
    nameOf = function(i) return GetSpellName(i, bank) end
  end
  if not nameOf then return out, count, "no spell book API" end
  for i = 1, math.min(count, 600) do
    local ok, name, rank = pcall(nameOf, i)
    if ok and type(name) == "string" and name ~= "" then
      name = name:lower()
      if type(rank) == "string" and rank ~= "" then out[#out + 1] = name .. " (" .. rank:lower() .. ")"
      else out[#out + 1] = name end
    end
  end
  return out, count
end

--- The "already known" line for an item that teaches a spell to the player or the demon out, or nil.
local function taughtKnown(spec)
  if not spec.link or not (C_Item and C_Item.GetItemSpell) or not C_Item.GetItemSpell(spec.link) then return nil end
  local lines = {}
  for _, ln in ipairs(spec.data and spec.data.lines or {}) do
    if ln.leftText then lines[#lines + 1] = ln.leftText:lower() end
  end
  local text = table.concat(lines, "\n")
  if text == "" then return nil end
  -- (the first few such items are written to the journal, so a mismatch in wording can be seen and fixed)
  Card.taughtSeen = Card.taughtSeen or {}
  local seenKey = spec.link
  local first = not Card.taughtSeen[seenKey] and #Card.taughtSeen < 6
  if first then
    Card.taughtSeen[seenKey] = true
    Card.taughtSeen[#Card.taughtSeen + 1] = seenKey
    local petEntries, petCount = bookEntries("pet")
    CB:JournalDebug("card", ("teaches? %s | demon book: %d/%d [%s] | tooltip: %s"):format(spec.link:match("%[(.-)%]") or "?", #petEntries, petCount or 0,
      table.concat(petEntries, "; "):sub(1, 140), text:gsub("\n", " / "):sub(1, 200)))
  end
  for _, bank in ipairs({ "pet", "spell" }) do
    local entries, count, note = bookEntries(bank)
    if not reportedBooks and CB.debugMode then
      reportedBooks = true
      CB:JournalDebug("card", ("spell books: %s has %d spell(s)%s"):format(bank, count or 0, note and (" - " .. note) or ""))
    end
    for _, key in ipairs(entries) do
      if text:find(key, 1, true) then return ITEM_SPELL_KNOWN or "Already known" end
    end
  end
end

---------------------------------------------------------------------------
-- Placement: the card hugs the window on the side with room; comparison cards continue outwards
---------------------------------------------------------------------------
local function place(W, cards)
  local anchor = W.frame
  if not anchor or #cards == 0 then return end
  local scale = CB.db.scale or 1
  -- GetRight is in the window's own scale; the screen's room is in the screen's
  local right = (anchor:GetRight() or 0) * ((anchor:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1))
  local room = (UIParent:GetWidth() or 1920) - right
  local columns = 1 + ((cards.hasCompare and 1) or 0)
  local side = CB.db.cardSide or "auto"
  local onLeft = side == "left" or (side == "auto" and room < (WIDTH + SIDE_GAP) * columns + 20)
  local previous = anchor
  for i, f in ipairs(cards) do
    f:SetScale(scale)
    UI:Resnap()
    f:ClearAllPoints()
    if i == 1 then
      if onLeft then f:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -SIDE_GAP, 0)
      else f:SetPoint("TOPLEFT", anchor, "TOPRIGHT", SIDE_GAP, 0) end
      previous = f
    elseif i == 2 then                                  -- first comparison card: next to the main card, further out
      if onLeft then f:SetPoint("TOPRIGHT", previous, "TOPLEFT", -SIDE_GAP, 0)
      else f:SetPoint("TOPLEFT", previous, "TOPRIGHT", SIDE_GAP, 0) end
      cards.firstCompare = f
    else                                                -- a second worn item goes under the first
      f:SetPoint("TOPLEFT", cards.firstCompare, "BOTTOMLEFT", 0, -SIDE_GAP)
    end
  end
end

---------------------------------------------------------------------------
-- Showing it
---------------------------------------------------------------------------
local function accentHex()
  local r, g, b = CB:Accent()
  return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
end

--- "A Use   X Pick up ..." from the player's own button map.
--- The hint line under a card for the mouse: { { "Click", "Buy" }, { "Right-click", "Amount" } } -> coloured keys.
function Card:MouseHint(list)
  local col = "|cff" .. accentHex()
  local out = {}
  for _, it in ipairs(list) do out[#out + 1] = col .. it[1] .. "|r " .. it[2] end
  return table.concat(out, "   ")
end

function Card:Buttons(items)
  local inv = {}
  for key, action in pairs(CB.db.pad.map) do if action then inv[action] = key end end
  local out = {}
  for _, it in ipairs(items) do
    if it[1] and it[2] and inv[it[1]] then
      out[#out + 1] = "|cff" .. accentHex() .. UI:PadLabel(inv[it[1]]) .. "|r " .. it[2]
    end
  end
  return table.concat(out, "    ")
end

--- Shows the card for one item and returns true when it is up (the caller then skips the plain tooltip).
--- `spec` = { data (C_TooltipInfo result, required), icon, name, link, equipLoc, classID, ilvl,
---   facts = { { left =, right = }, ... }, buttons (legend string), scan (fills a tooltip with the item),
---   noCompare (skip the worn-gear cards) }.
function Card:Show(W, spec)
  Card.source = nil                    -- only ShowFor follows a source; everything else is a one-off picture
  if not Card:Enabled() or not W or type(spec) ~= "table" or type(spec.data) ~= "table" then
    Card:HideAll()
    return false
  end

  local body = newBody()
  addTooltipLines(body, spec.data)

  local fill = spec.scan
  if not fill and spec.link then fill = function(tip) tip:SetHyperlink(spec.link) end end
  local okKnown, known = pcall(knownLine, fill)
  if not (okKnown and present(known)) then
    local okTaught, taught = pcall(taughtKnown, spec)
    known = okTaught and taught or nil
  end
  if present(known) and not body:HasLeft(known) then body:Text(known, KNOWN_RED) end

  body:Space()
  local label, value = named("muted"), WHITE
  for _, fact in ipairs(spec.facts or {}) do
    if type(fact) == "table" and fact.left then body:Text(tostring(fact.left), label, fact.right and tostring(fact.right), value) end
  end
  if present(spec.buttons) then
    body:Space()
    body:Text(spec.buttons, WHITE)
  end

  local title, titleColour = titleFrom(spec.data, spec.name)
  local sub = className(spec.classID) or ""
  local level = levelText(spec.ilvl)
  if level then sub = sub ~= "" and (sub .. "   " .. level) or level end

  local main = mainFrame()
  paint(main, { icon = spec.icon, title = title, titleColour = titleColour, sub = sub }, body:Trimmed())

  local cards = { main }
  local worn = wornCards(spec)
  for i, card in ipairs(worn) do
    local f = compareFrame(i)
    paint(f, card.head, card.rows)
    cards[#cards + 1] = f
  end
  for i = #worn + 1, #(Card.cmp or {}) do Card.cmp[i]:Hide() end
  cards.hasCompare = #worn > 0
  place(W, cards)
  for _, f in ipairs(cards) do f:Show() end
  return true
end

--- The card for an item in the bags or the bank. `mouse` is true when the pointer (not the highlight) asked.
function Card:ShowFor(W, rec, mouse)
  if not Card:Enabled() or not rec or rec.empty or not rec.bag then Card:HideAll(); return false end
  local getter = C_TooltipInfo.GetBagItem
  local okData, data = false, nil
  if getter then okData, data = pcall(getter, rec.bag, rec.slot) end
  if not okData or not data then Card:HideAll(); return false end

  local facts = {}
  facts[#facts + 1] = { left = "Carried", right = tostring(carried(rec.itemID) or rec.count or 1) }
  if (rec.sellPrice or 0) > 0 then
    facts[#facts + 1] = { left = "Sells for", right = UI:Money(rec.sellPrice * (rec.count or 1)) }
  end
  facts[#facts + 1] = { left = "Location", right = ("%s / %s"):format(tostring(rec.bag), tostring(rec.slot)) }
  local Inv = CB.Inventory
  local left = Inv and Inv.CooldownLeft and Inv:CooldownLeft(rec.bag, rec.slot, rec)
  if type(left) == "number" then
    local bandage = Inv.IsBandage and Inv:IsBandage(rec)
    facts[#facts + 1] = { left = bandage and "Recently bandaged" or "Cooldown", right = UI:Duration(left) }
  end
  local elsewhere = elsewhereTotal(rec.itemID)
  if elsewhere then facts[#facts + 1] = { left = "Elsewhere", right = tostring(elsewhere) } end

  local buttons
  if mouse then
    buttons = W.MouseHint and W:MouseHint(rec) or ""
  else
    local useLabel = W.UseLabel and W:UseLabel(rec)
    local pickLabel = W.PickupLabel and W:PickupLabel(rec) or "Pick up"
    buttons = Card:Buttons({ { "use", useLabel }, { "pickup", pickLabel }, { "menu", "Menu" }, { "favorite", "Favorite" } })
  end

  local ok, shown = pcall(Card.Show, Card, W, { data = data, icon = rec.icon, name = rec.name, link = rec.link,
    equipLoc = rec.equipLoc, classID = rec.classID, ilvl = rec.ilvl, facts = facts, buttons = buttons,
    scan = function(tip) tip:SetBagItem(rec.bag, rec.slot) end })
  if not ok then CB:Warn("card", tostring(shown)) end
  if not ok or not shown then Card:HideAll(); return false end
  Card.mouseShown = mouse and true or false
  Card.source = { W = W, key = rec.key, mouse = Card.mouseShown }
  return true
end

---------------------------------------------------------------------------
-- Following changes: an equip (A, or a click) swaps the highlighted bag item with the worn one, but the highlight
-- does not move, so nothing would ask for a new card. While a bag card is up, any bag / equipment change
-- (Inventory.lua turns BAG_UPDATE_DELAYED, PLAYER_EQUIPMENT_CHANGED, UNIT_INVENTORY_CHANGED into DIRTY and
-- ITEM_LOCK_CHANGED into LOCKS) queues one rebuild for the next frame, after the window has redrawn its records.
-- It is the same rebuild re-highlighting does: the controller card follows the highlight, the mouse card the slot.
-- Only the addon's own card frames and C_TooltipInfo are touched, so it is safe in combat.
---------------------------------------------------------------------------
local MAX_WAIT_FRAMES = 5      -- frames to wait for the window's own redraw before rebuilding anyway

local function cardShown() return Card.frame and Card.frame:IsShown() end

local function entryFor(W, key)
  for _, e in ipairs(W.navFull or W.nav or {}) do if e.key == key then return e end end
end

-- Keep only source identity across redraws, never an old item record. Equipment
-- swaps can replace the item at the same coordinates without moving focus.
-- Mouse follows its hovered slot; controller follows the current selected entry.
function Card:RefreshNow()
  local source = Card.source
  if not (source and cardShown()) then return end
  local window = source.W
  if not (window and window.frame and window.frame:IsShown()) then Card:Hide(); return end
  local mouse = source.mouse
  local entry
  if mouse then
    if CursorHasItem and CursorHasItem() then return end   -- (a held item has its own on-screen life, as in HoverCard)
    entry = entryFor(window, source.key)
  else
    entry = window.selEntry
  end
  if entry and entry.rec and not entry.rec.empty and Card:ShowFor(window, entry.rec, mouse) then return end
  Card:Hide()                                              -- the highlight (or the hovered slot) holds nothing now
end

-- Coalesce event bursts and allow the owning view to finish its dirty redraw.
-- The bounded wait avoids an endless timer chain if a view stays dirty. Hide()
-- clears the source, so an already scheduled callback cannot reopen a closed card.
local function runQueued()
  local W = Card.source and Card.source.W
  if W and W.dirty and Card.queuedWaits < MAX_WAIT_FRAMES and cardShown() and W.frame and W.frame:IsShown() then
    Card.queuedWaits = Card.queuedWaits + 1
    C_Timer.After(0, runQueued)                            -- its records are rebuilt on its next OnUpdate
    return
  end
  Card.queued = false
  CB:Safe("card:refresh", Card.RefreshNow, Card)
end

function Card:QueueRefresh()
  if Card.queued or not Card.source or not cardShown() then return end     -- no work while nothing is shown
  if not (C_Timer and C_Timer.After) then return end
  Card.queued, Card.queuedWaits = true, 0
  C_Timer.After(0, runQueued)
end

CB:On("DIRTY", function() Card:QueueRefresh() end)
CB:On("LOCKS", function() Card:QueueRefresh() end)

--- An entry of the merchant window: wares for sale, the buy-back list, or worn and damaged gear.
function Card:ShowEntry(W, e, mouse)
  if not Card:Enabled() or not e or not e.link then Card:HideAll(); return false end
  local info = C_TooltipInfo
  local data
  if e.kind == "buy" and info.GetMerchantItem then data = info.GetMerchantItem(e.index)
  elseif e.kind == "buyback" and info.GetBuybackItem then data = info.GetBuybackItem(e.index)
  elseif e.kind == "repairitem" then
    if e.bag and info.GetBagItem then data = info.GetBagItem(e.bag, e.slot)
    elseif info.GetInventoryItem then data = info.GetInventoryItem("player", e.slot) end
  end
  if not data then Card:HideAll(); return false end
  local id, equipLoc, icon, classID, ilvl = linkInfo(e.link)
  local extra = {}
  if e.kind == "buy" or e.kind == "buyback" then
    extra[#extra + 1] = { left = "Price", right = (e.kind == "buy" and e.extended) and "Special cost" or UI:Money(e.price or 0) }
    if e.kind == "buy" and (e.numAvailable or -1) >= 0 then extra[#extra + 1] = { left = "In stock", right = tostring(e.numAvailable) } end
  elseif e.dur and e.max then
    extra[#extra + 1] = { left = "Durability", right = ("%d / %d"):format(e.dur, e.max) }
  end
  local label = (e.kind == "buy" and "Buy") or (e.kind == "buyback" and "Buy back") or "Repair"
  local ok, shown = pcall(Card.Show, Card, W, { data = data, icon = icon or e.icon, name = e.name, link = e.link,
    equipLoc = equipLoc, classID = classID, ilvl = ilvl, facts = itemFacts(id, extra),
    buttons = mouse and Card:MouseHint(e.kind == "buy" and { { "Click", "Buy" }, { "Right-click", "Amount / menu" } } or { { "Click", label } })
      or Card:Buttons({ { "use", label } }), noCompare = (e.kind == "repairitem"),
    scan = function(tip)
      if e.kind == "buy" then tip:SetMerchantItem(e.index)
      elseif e.kind == "buyback" then tip:SetBuybackItem(e.index)
      else tip:SetHyperlink(e.link) end
    end })
  if not ok or not shown then Card:HideAll(); return false end
  Card.mouseShown = mouse and true or false
  return true
end

--- Any item known by a link whose tooltip data a getter supplies (guild bank slot, mail attachment, trade slot).
--- `getter` is called with no arguments and returns the C_TooltipInfo data; `extra` are leading fact rows;
--- `scan(tip)` (optional) fills a tooltip with the item the old way, to read "already known" from it.
--- `noCompare` (optional) skips the comparison with worn gear (for items that are worn already).
function Card:ShowLink(W, link, getter, extra, buttons, scan, noCompare, mouse)
  if not Card:Enabled() or not link or not getter then Card:HideAll(); return false end
  local okData, data = pcall(getter)
  if not okData or not data then Card:HideAll(); return false end
  local id, equipLoc, icon, classID, ilvl = linkInfo(link)
  local ok, shown = pcall(Card.Show, Card, W, { data = data, icon = icon, link = link, equipLoc = equipLoc,
    classID = classID, ilvl = ilvl, facts = itemFacts(id, extra), buttons = buttons, scan = scan,
    noCompare = noCompare })
  if not ok or not shown then Card:HideAll(); return false end
  Card.mouseShown = mouse and true or false
  return true
end

---------------------------------------------------------------------------
-- Taking it down
---------------------------------------------------------------------------
--- Just the cards.
function Card:Hide()
  Card.mouseShown = false
  Card.source = nil
  if Card.frame then Card.frame:Hide() end
  for _, f in pairs(Card.cmp or {}) do f:Hide() end
end

--- The mouse left a tile: the card goes if the mouse put it up (a card the controller's highlight keeps stays).
function Card:HideMouse()
  if Card.mouseShown then Card:HideAll() end
end

--- Everything that describes an item: the cards, the tooltip and the game's own "equipped" comparison tooltips.
--- Used when the highlight leaves the items (search bar, filters, buttons) so nothing stale hides the window.
function Card:HideAll()
  Card:Hide()
  UI:HideTip()
  for i = 1, 2 do
    local tip = rawget(_G, "ShoppingTooltip" .. i)
    if tip and tip.IsShown and tip:IsShown() then tip:Hide() end
  end
end

CB:On("SETTING", function(key)
  if key == "bgAlpha" then
    for _, f in ipairs(Card.frames or {}) do f:SetBackdropColor(UI.bg[1], UI.bg[2], UI.bg[3], CB.db.bgAlpha) end
  end
  if key == "itemCard" and not CB.db.itemCard then Card:Hide() end
  if key == "cardCompare" and CB.db.cardCompare == false and Card.cmp then for _, f in pairs(Card.cmp) do f:Hide() end end
end)
