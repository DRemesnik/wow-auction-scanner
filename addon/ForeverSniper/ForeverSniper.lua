local ADDON_NAME = ...

-- Keybinding labels for WoW's Key Bindings UI
BINDING_HEADER_FOREVERSNIPER = "Goblin Broker: Forever"
BINDING_NAME_FOREVERSNIPER_BUY = "Купить / Подтвердить лот"
BINDING_NAME_FOREVERSNIPER_SCAN = "Старт / Пауза скана"
BINDING_NAME_FOREVERSNIPER_TOGGLE = "Показать / Скрыть окно"
BINDING_NAME_FOREVERSNIPER_BAIT = "Выставить наживку (1 шт)"

ForeverSniperDB = ForeverSniperDB or {
  watchlist = {}, -- [itemID] = maxUnitCopper
  qtyLimits = {}, -- [itemID] = maxBuyQty (nil or 0 = unlimited)
  tracked = {},   -- [itemID] = boolean (nil/true = tracked, false = skipped)
  presets = {},   -- [name] = { watchlist = {...}, qtyLimits = {...}, tracked = {...} }
  activePreset = nil,
  selectedID = nil,
  autoScan = false,
  soundAlert = true,
  miniMode = false,
  railExpanded = false,
  activeBaitID = nil,
  skipSingleBait = false,
  telemetry = { days = {}, items = {}, hours = {} },
}

local function EnsureTelemetryDB()
  ForeverSniperDB.telemetry = ForeverSniperDB.telemetry or {}
  ForeverSniperDB.telemetry.days = ForeverSniperDB.telemetry.days or {}
  ForeverSniperDB.telemetry.items = ForeverSniperDB.telemetry.items or {}
  ForeverSniperDB.telemetry.hours = ForeverSniperDB.telemetry.hours or {}
  return ForeverSniperDB.telemetry
end

local function TodayKey()
  return (date and date("%Y-%m-%d")) or "unknown"
end

local function HourKey()
  local t = date and date("*t")
  return (t and t.hour) or 0
end

local function TouchHourBucket(t, hr)
  local h = t.hours[hr]
  if not h then h = { buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, dips = 0 }; t.hours[hr] = h end
  return h
end

local function RecordTelemetryDip(itemID, unitPrice, name)
  if not itemID then return end
  local t = EnsureTelemetryDB()
  local dk = TodayKey()
  local d = t.days[dk]
  if not d then d = { buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, dips = 0 }; t.days[dk] = d end
  d.dips = (d.dips or 0) + 1
  local it = t.items[itemID]
  if not it then it = { name = name, buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, dips = 0 }; t.items[itemID] = it end
  it.dips = (it.dips or 0) + 1
  if name and not it.name then it.name = name end
  if unitPrice and unitPrice > 0 and (not it.minDip or unitPrice < it.minDip) then
    it.minDip = unitPrice
  end
  local hb = TouchHourBucket(t, HourKey())
  hb.dips = (hb.dips or 0) + 1
end

local function RecordTelemetryMarketFloor(itemID, floorPrice, name)
  if not itemID or not floorPrice or floorPrice <= 0 then return end
  local t = EnsureTelemetryDB()
  local it = t.items[itemID]
  if not it then
    it = { name = name, buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, dips = 0, scanSum = 0, scanCnt = 0 }
    t.items[itemID] = it
  end
  it.scanSum = (it.scanSum or 0) + floorPrice
  it.scanCnt = (it.scanCnt or 0) + 1
  if name and not it.name then it.name = name end
end

local function RecordTelemetryBuy(itemID, qty, totalCost, name, savedCopper, mktSavedCopper)
  if not itemID then return end
  local t = EnsureTelemetryDB()
  local dk = TodayKey()
  local sv = math.max(0, tonumber(savedCopper) or 0)
  local msv = math.max(0, tonumber(mktSavedCopper) or 0)
  local d = t.days[dk]
  if not d then d = { buys = 0, qty = 0, spent = 0, saved = 0, mktSaved = 0, missed = 0, dips = 0 }; t.days[dk] = d end
  d.buys = (d.buys or 0) + 1
  d.qty = (d.qty or 0) + (qty or 1)
  d.spent = (d.spent or 0) + (totalCost or 0)
  d.saved = (d.saved or 0) + sv
  d.mktSaved = (d.mktSaved or 0) + msv
  local it = t.items[itemID]
  if not it then it = { name = name, buys = 0, qty = 0, spent = 0, saved = 0, mktSaved = 0, missed = 0, dips = 0 }; t.items[itemID] = it end
  it.buys = (it.buys or 0) + 1
  it.qty = (it.qty or 0) + (qty or 1)
  it.spent = (it.spent or 0) + (totalCost or 0)
  it.saved = (it.saved or 0) + sv
  it.mktSaved = (it.mktSaved or 0) + msv
  if name and not it.name then it.name = name end
  local hb = TouchHourBucket(t, HourKey())
  hb.buys = (hb.buys or 0) + 1
  hb.qty = (hb.qty or 0) + (qty or 1)
  hb.spent = (hb.spent or 0) + (totalCost or 0)
  hb.saved = (hb.saved or 0) + sv
  hb.mktSaved = (hb.mktSaved or 0) + msv
end

local function RecordTelemetryMiss(itemID, name)
  if not itemID then return end
  local t = EnsureTelemetryDB()
  local dk = TodayKey()
  local d = t.days[dk]
  if not d then d = { buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, dips = 0 }; t.days[dk] = d end
  d.missed = (d.missed or 0) + 1
  local it = t.items[itemID]
  if not it then it = { name = name, buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, dips = 0 }; t.items[itemID] = it end
  it.missed = (it.missed or 0) + 1
  if name and not it.name then it.name = name end
  local hb = TouchHourBucket(t, HourKey())
  hb.missed = (hb.missed or 0) + 1
end

local function IsSoundEnabled()
  return ForeverSniperDB.soundAlert ~= false
end

local origBgSoundCVar = nil
local function EnsureBackgroundSoundCVar()
  if IsSoundEnabled() and SetCVar then
    if origBgSoundCVar == nil and GetCVar then
      local ok, cur = pcall(GetCVar, "Sound_EnableSoundWhenGameIsInBG")
      if ok then origBgSoundCVar = cur end
    end
    pcall(SetCVar, "Sound_EnableSoundWhenGameIsInBG", "1")
  elseif not IsSoundEnabled() and SetCVar and origBgSoundCVar ~= nil then
    pcall(SetCVar, "Sound_EnableSoundWhenGameIsInBG", origBgSoundCVar)
  end
end

local function PlayDealAlert()
  if not IsSoundEnabled() then return end
  EnsureBackgroundSoundCVar()
  if PlaySound and SOUNDKIT then
    local coinKit = SOUNDKIT.LOOT_WINDOW_COIN_SOUND or SOUNDKIT.AUCTION_WINDOW_OPEN
    if coinKit then
      pcall(PlaySound, coinKit, "Master")
    end
    local bellKit = SOUNDKIT.ALARM_CLOCK_WARNING_3 or SOUNDKIT.TELL_MESSAGE
    if bellKit then
      pcall(PlaySound, bellKit, "Master")
    end
  end
  if FlashClientIcon then
    FlashClientIcon()
  end
end

local LOGO_PATH = "Interface\\AddOns\\ForeverSniper\\logo.tga"

local function GetBaseQtyCap(itemID)
  if not itemID or not ForeverSniperDB.qtyLimits then return 0 end
  return tonumber(ForeverSniperDB.qtyLimits[itemID]) or 0
end

local function GetQtyCap(itemID)
  local base = GetBaseQtyCap(itemID)
  if base <= 0 then return 0 end
  local bought = (ForeverSniperDB.boughtByItem and ForeverSniperDB.boughtByItem[itemID]) or 0
  return math.max(0, base - bought)
end

local state = {
  ahOpen = false,
  queue = {},
  idx = 1,
  lastQueryAt = 0,
  queryInterval = 0.25, -- Fast 4/sec polling for earliest deal detection
  queryCount = 0,
  pendingDeal = nil,   -- { itemID, isCommodity, auctionID, unitPrice, qty, maxPrice, name, stage, confirmAt }
  throttled = false,
  lastSeenByItem = {}, -- [itemID] = { lowestPrice, availBelow, updatedAt }
  lastPurchaseAttempt = nil, -- { itemID, name, qty, totalCost, at }
  sessionBuys = {
    totalQty = 0,
    totalCopper = 0,
    history = {}, -- ring buffer up to 10 entries
    lastOutcome = nil,
  },
}

local PRICE_SORTS = {
  { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
}

local FLAT_BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8X8",
  edgeFile = "Interface\\Buttons\\WHITE8X8",
  tile = false,
  edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local SHADOW_BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8X8",
  edgeFile = "Interface\\AddOns\\ForeverSniper\\shadow_border.tga",
  tile = false,
  edgeSize = 16,
  insets = { left = 12, right = 12, top = 12, bottom = 12 },
}

local function AttachDropShadow(owner, pad, alpha)
  local p = pad or 12
  local a = alpha or 0.72
  local sh = CreateFrame("Frame", nil, owner, "BackdropTemplate")
  sh:SetPoint("TOPLEFT", owner, "TOPLEFT", -p, p)
  sh:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", p, -p)
  sh:SetFrameLevel(math.max(0, (owner:GetFrameLevel() or 1) - 1))
  sh:SetBackdrop(SHADOW_BACKDROP)
  sh:SetBackdropColor(0, 0, 0, a * 0.55)
  sh:SetBackdropBorderColor(0, 0, 0, a)
  owner.dropShadow = sh
  return sh
end

local ICON_GOLD   = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:1:0|t"
local ICON_SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:1:0|t"
local ICON_COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:1:0|t"
local DOT_GREEN   = "|TInterface\\COMMON\\Indicator-Green:11:11:0:0|t"
local DOT_AMBER   = "|TInterface\\COMMON\\Indicator-Yellow:11:11:0:0|t"
local DOT_RED     = "|TInterface\\COMMON\\Indicator-Red:11:11:0:0|t"
local DOT_GRAY    = "|TInterface\\COMMON\\Indicator-Gray:11:11:0:0|t"

local function FormatCoins(copper)
  if not copper or copper <= 0 then
    return "0" .. ICON_COPPER
  end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local parts = {}
  if g > 0 then table.insert(parts, "|cffffffff" .. g .. "|r" .. ICON_GOLD) end
  if s > 0 or g > 0 then table.insert(parts, "|cffffffff" .. s .. "|r" .. ICON_SILVER) end
  table.insert(parts, "|cffffffff" .. c .. "|r" .. ICON_COPPER)
  return table.concat(parts, " ")
end

local function FormatCoinsPlain(copper)
  if not copper or copper <= 0 then return "0c" end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local parts = {}
  if g > 0 then table.insert(parts, g .. "g") end
  if s > 0 or g > 0 then table.insert(parts, s .. "s") end
  table.insert(parts, c .. "c")
  return table.concat(parts, " ")
end

local itemKeyCache = {}
local function GetCachedItemKey(itemID)
  local k = itemKeyCache[itemID]
  if not k and C_AuctionHouse and C_AuctionHouse.MakeItemKey then
    k = C_AuctionHouse.MakeItemKey(itemID)
    itemKeyCache[itemID] = k
  end
  return k
end

local itemVisualCache = {}
local function GetItemVisuals(itemID)
  local cached = itemVisualCache[itemID]
  if cached then
    return cached[1], cached[2], cached[3], cached[4], cached[5]
  end
  local icon = 134400
  if C_Item and C_Item.GetItemIconByID then
    icon = C_Item.GetItemIconByID(itemID) or icon
  elseif GetItemInfoInstant then
    icon = select(5, GetItemInfoInstant(itemID)) or icon
  end
  local info = C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.MakeItemKey and
    C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(itemID))
  local realName = (info and info.itemName) or (GetItemInfo and GetItemInfo(itemID))
  local name = realName or ("Item #" .. tostring(itemID))
  local quality = (info and info.quality) or (select(3, GetItemInfo(itemID))) or 1
  local r, g, b = 0.88, 0.91, 0.96
  if ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
    local qc = ITEM_QUALITY_COLORS[quality]
    r, g, b = qc.r, qc.g, qc.b
  end
  if realName and icon ~= 134400 then
    itemVisualCache[itemID] = { icon, name, r, g, b }
  end
  return icon, name, r, g, b
end

local function StyleFlatBox(box, w, h)
  box:SetSize(w, h)
  box:SetAutoFocus(false)
  box:SetTextInsets(6, 6, 0, 0)
  box:SetFontObject("GameFontHighlight")
  box:SetBackdrop(FLAT_BACKDROP)
  box:SetBackdropColor(0.03, 0.045, 0.08, 1)
  box:SetBackdropBorderColor(0.18, 0.24, 0.35, 1)
  box:SetScript("OnEditFocusGained", function(self)
    self:SetBackdropBorderColor(0.92, 0.70, 0.03, 1) -- Goblin Broker Gold focus
  end)
  box:SetScript("OnEditFocusLost", function(self)
    self:SetBackdropBorderColor(0.18, 0.24, 0.35, 1)
  end)
  box:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
end

local function CreateFlatButton(name, parent, w, h, text)
  local btn = CreateFrame("Button", name, parent, "BackdropTemplate")
  btn:SetSize(w, h)
  btn:SetBackdrop(FLAT_BACKDROP)
  btn:SetBackdropColor(0.11, 0.15, 0.23, 1)
  btn:SetBackdropBorderColor(0.22, 0.29, 0.42, 1)

  local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("CENTER")
  label:SetText(text or "")
  btn.label = label
  btn.baseBg = { 0.11, 0.15, 0.23, 1 }
  btn.hoverBg = { 0.16, 0.22, 0.33, 1 }
  btn.baseBorder = { 0.22, 0.29, 0.42, 1 }
  btn.isEnabled = true

  function btn:SetColors(bg, hover, border, textColor)
    self.baseBg = bg
    self.hoverBg = hover
    self.baseBorder = border
    self:SetBackdropColor(unpack(bg))
    self:SetBackdropBorderColor(unpack(border))
    if textColor then
      self.label:SetTextColor(unpack(textColor))
    else
      self.label:SetTextColor(0.92, 0.95, 0.99)
    end
  end

  function btn:SetLabel(txt)
    self.label:SetText(txt or "")
  end

  function btn:SetFlatEnabled(enabled)
    self.isEnabled = not not enabled
    if enabled then
      self:Enable()
      self:SetAlpha(1)
    else
      self:Disable()
      self:SetAlpha(0.65)
    end
  end

  btn:SetScript("OnEnter", function(self)
    if self.isEnabled then
      self:SetBackdropColor(unpack(self.hoverBg))
    end
  end)
  btn:SetScript("OnLeave", function(self)
    self:SetBackdropColor(unpack(self.baseBg))
  end)

  return btn
end

local function IsItemTracked(itemID)
  ForeverSniperDB.tracked = ForeverSniperDB.tracked or {}
  return ForeverSniperDB.tracked[itemID] ~= false
end

local function RebuildQueue()
  state.allItems = {}
  state.queue = {}
  for itemID, maxPrice in pairs(ForeverSniperDB.watchlist or {}) do
    local id = tonumber(itemID)
    local price = tonumber(maxPrice)
    if id and price and price > 0 then
      table.insert(state.allItems, id)
      if IsItemTracked(id) then
        table.insert(state.queue, id)
      end
    end
  end
  table.sort(state.allItems)
  table.sort(state.queue)
  if #state.allItems == 0 then
    ForeverSniperDB.selectedID = nil
    state.idx = 1
    return
  end
  if ForeverSniperDB.selectedID then
    for i, id in ipairs(state.queue) do
      if id == ForeverSniperDB.selectedID then
        state.idx = i
        return
      end
    end
    for _, id in ipairs(state.allItems) do
      if id == ForeverSniperDB.selectedID then
        state.idx = 1
        return
      end
    end
  end
  state.idx = 1
  ForeverSniperDB.selectedID = state.queue[1] or state.allItems[1]
end

-- ============================================================================
-- Main Frame (Goblin Broker: Forever — Branded Navy / Gold / Emerald)
-- ============================================================================
local f = CreateFrame("Frame", "ForeverSniperFrame", UIParent, "BackdropTemplate")
f:SetSize(572, 585)
f:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -30, 100)
f:SetFrameStrata("DIALOG")
f:SetToplevel(true)
f:SetClampedToScreen(true)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
local function CaptureWindowPos()
  local point, _, relPoint, x, y = f:GetPoint(1)
  if not point then return nil end
  return {
    point = point,
    relPoint = relPoint or point,
    x = math.floor((x or 0) + 0.5),
    y = math.floor((y or 0) + 0.5),
  }
end

local function ApplyWindowPos(pos)
  if type(pos) ~= "table" or not pos.point then return end
  f:ClearAllPoints()
  f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
end

f:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  ForeverSniperDB.windowPos = CaptureWindowPos()
end)
f:SetBackdrop(FLAT_BACKDROP)
f:SetBackdropColor(0.043, 0.067, 0.125, 1) -- #0B1120 Goblin Broker Navy (opaque)
f:SetBackdropBorderColor(0.22, 0.28, 0.40, 1)
AttachDropShadow(f, 10, 0.60)
f:Hide()

-- Top 2px Gold-to-Emerald brand hairline
local topAccent = f:CreateTexture(nil, "ARTWORK")
topAccent:SetHeight(2)
topAccent:SetPoint("TOPLEFT", 1, -1)
topAccent:SetPoint("TOPRIGHT", -1, -1)
topAccent:SetColorTexture(1, 1, 1, 1)
topAccent:SetGradient("HORIZONTAL", CreateColor(0.92, 0.70, 0.03, 1), CreateColor(0.06, 0.73, 0.51, 1))

-- Brand Logo Mark (Logo #1: Gold Goblin Head + Emerald Monocle)
local brandMark = CreateFrame("Frame", nil, f, "BackdropTemplate")
brandMark:SetSize(36, 36)
brandMark:SetPoint("TOPLEFT", 14, -8)
brandMark:SetBackdrop(FLAT_BACKDROP)
brandMark:SetBackdropColor(0.07, 0.10, 0.18, 1)
brandMark:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.65)

local brandLogo = brandMark:CreateTexture(nil, "ARTWORK")
brandLogo:SetSize(28, 28)
brandLogo:SetPoint("CENTER")
brandLogo:SetTexture(LOGO_PATH)

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", brandMark, "TOPRIGHT", 10, -1)
title:SetText("|cfff59e0bGoblin Broker|r|cfff8fafc: Forever|r")

local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
subtitle:SetPoint("BOTTOMLEFT", brandMark, "BOTTOMRIGHT", 10, 1)
subtitle:SetText("|cff94a3b8EU Орда | AH Снайпер (1с)|r")

-- Close button
local closeBtn = CreateFlatButton(nil, f, 26, 26, "X")
closeBtn:SetPoint("TOPRIGHT", -12, -13)
closeBtn:SetColors({ 0.10, 0.13, 0.21, 1 }, { 0.55, 0.14, 0.18, 1 }, { 0.22, 0.28, 0.40, 1 }, { 0.85, 0.89, 0.95 })
closeBtn:SetScript("OnClick", function() f:Hide() end)

-- Live Status Pill
local statusPill = CreateFrame("Frame", nil, f, "BackdropTemplate")
statusPill:SetSize(118, 26)
statusPill:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
statusPill:SetBackdrop(FLAT_BACKDROP)
statusPill:SetBackdropColor(0.07, 0.10, 0.18, 1)
statusPill:SetBackdropBorderColor(0.18, 0.25, 0.36, 1)

local statusText = statusPill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statusText:SetPoint("CENTER")
statusText:SetText(DOT_GRAY .. " |cff94a3b8Пауза|r")

local hdrDiv = f:CreateTexture(nil, "ARTWORK")
hdrDiv:SetHeight(1)
hdrDiv:SetPoint("TOPLEFT", 12, -50)
hdrDiv:SetPoint("TOPRIGHT", -12, -50)
hdrDiv:SetColorTexture(0.18, 0.24, 0.36, 0.75)

-- ============================================================================
-- Left Expandable Tool Sidebar (under app logo: 40px icons <-> 134px icons+labels)
-- ============================================================================
local toolRail = CreateFrame("Frame", nil, f, "BackdropTemplate")
toolRail:SetWidth(36)
toolRail:SetPoint("TOPLEFT", 14, -60)
toolRail:SetPoint("BOTTOMLEFT", 14, 14)
toolRail:SetBackdrop(FLAT_BACKDROP)
toolRail:SetBackdropColor(0.028, 0.042, 0.082, 1)
toolRail:SetBackdropBorderColor(0.15, 0.21, 0.32, 1)

local railButtons = {}
local function MakeRailButton(yParent, yOff, texPath, labelTxt, isBottom)
  local btn = CreateFlatButton(nil, toolRail, 28, 26, "")
  if isBottom then
    btn:SetPoint("BOTTOMLEFT", 4, 4)
    btn:SetPoint("BOTTOMRIGHT", -4, 4)
  elseif yParent then
    btn:SetPoint("TOPLEFT", yParent, "BOTTOMLEFT", 0, yOff)
    btn:SetPoint("TOPRIGHT", yParent, "BOTTOMRIGHT", 0, yOff)
  else
    btn:SetPoint("TOPLEFT", 4, yOff)
    btn:SetPoint("TOPRIGHT", -4, yOff)
  end
  if texPath then
    local ico = btn:CreateTexture(nil, "ARTWORK")
    ico:SetSize(18, 18)
    ico:SetPoint("LEFT", 5, 0)
    ico:SetTexture(texPath)
    ico:SetTexCoord(0, 1, 0, 1)
    btn.ico = ico
  end
  local txt = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  txt:SetPoint("LEFT", 28, 0)
  txt:SetPoint("RIGHT", -4, 0)
  txt:SetJustifyH("LEFT")
  txt:SetWordWrap(false)
  txt:SetText(labelTxt or "")
  txt:Hide()
  btn.railText = txt
  table.insert(railButtons, btn)
  return btn
end

-- 0. Expand / Collapse Sidebar Toggle
local railToggleBtn = CreateFlatButton(nil, toolRail, 28, 22, ">>")
railToggleBtn:SetPoint("TOPLEFT", 4, -4)
railToggleBtn:SetPoint("TOPRIGHT", -4, -4)
railToggleBtn:SetColors({ 0.07, 0.10, 0.17, 1 }, { 0.13, 0.18, 0.28, 1 }, { 0.20, 0.28, 0.40, 0.7 }, { 0.78, 0.86, 0.96 })
railToggleBtn:HookScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(ForeverSniperDB.railExpanded and "Свернуть панель" or "Развернуть панель с названиями", 0.96, 0.70, 0.03)
  GameTooltip:Show()
end)
railToggleBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

-- 1. Mini / Full Mode Toggle
local miniBtn = MakeRailButton(railToggleBtn, -6, "Interface\\AddOns\\ForeverSniper\\rail_mini.tga", "Мини-режим")
miniBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.85, 0.90, 0.96 })
miniBtn:HookScript("OnEnter", function(self)
  if ForeverSniperDB.railExpanded then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(ForeverSniperDB.miniMode and "Полный режим" or "Мини-режим", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Свернуть/развернуть список и настройки", 0.85, 0.90, 0.96)
  GameTooltip:Show()
end)
miniBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

-- 2. Sound Alert Toggle (works in background via Sound_EnableSoundWhenGameIsInBG)
local soundBtn = MakeRailButton(miniBtn, -5, "Interface\\AddOns\\ForeverSniper\\rail_sound.tga", "Звук: ВКЛ")

local function RefreshSoundBtn()
  if IsSoundEnabled() then
    soundBtn:SetColors({ 0.04, 0.16, 0.14, 1 }, { 0.06, 0.24, 0.20, 1 }, { 0.06, 0.73, 0.51, 0.8 }, { 0.85, 1, 0.94 })
    soundBtn.ico:SetDesaturated(false)
    soundBtn.ico:SetAlpha(1)
    soundBtn.railText:SetText("|cff10b981Звук: ВКЛ|r")
  else
    soundBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.13, 0.17, 0.25, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.45, 0.52, 0.62 })
    soundBtn.ico:SetDesaturated(true)
    soundBtn.ico:SetAlpha(0.45)
    soundBtn.railText:SetText("|cff64748bЗвук: ВЫКЛ|r")
  end
end

soundBtn:SetScript("OnClick", function()
  ForeverSniperDB.soundAlert = not IsSoundEnabled()
  RefreshSoundBtn()
  if IsSoundEnabled() then
    EnsureBackgroundSoundCVar()
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON, "Master")
    end
  end
end)

soundBtn:HookScript("OnEnter", function(self)
  if ForeverSniperDB.railExpanded then return end
  if GameTooltip then
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(IsSoundEnabled() and "Звуковой сигнал: ВКЛ" or "Звуковой сигнал: ВЫКЛ", 0.96, 0.70, 0.03)
    GameTooltip:AddLine("Работает даже в фоновом режиме (Alt+Tab)", 0.65, 0.75, 0.85)
    GameTooltip:Show()
  end
end)
soundBtn:HookScript("OnLeave", function()
  if GameTooltip then GameTooltip:Hide() end
end)

-- 3. Session Purchase Log Button (with numeric badge when > 0)
local logBtn = MakeRailButton(soundBtn, -5, "Interface\\AddOns\\ForeverSniper\\rail_log.tga", "Лог (0)")
logBtn:SetColors({ 0.08, 0.12, 0.20, 1 }, { 0.14, 0.20, 0.32, 1 }, { 0.22, 0.29, 0.42, 1 }, { 0.92, 0.70, 0.03 })

local logBadgeCount = logBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
logBadgeCount:SetPoint("TOPRIGHT", 2, 2)
logBadgeCount:SetText("")
logBadgeCount:Hide()

local railDiv = toolRail:CreateTexture(nil, "ARTWORK")
railDiv:SetHeight(1)
railDiv:SetPoint("TOPLEFT", logBtn, "BOTTOMLEFT", 4, -6)
railDiv:SetPoint("TOPRIGHT", logBtn, "BOTTOMRIGHT", -4, -6)
railDiv:SetColorTexture(0.20, 0.28, 0.40, 0.85)

-- 4. Import (shown in Full Mode)
local importBtn = MakeRailButton(logBtn, -13, "Interface\\AddOns\\ForeverSniper\\rail_import.tga", "Импорт")
importBtn:SetColors({ 0.09, 0.13, 0.21, 1 }, { 0.14, 0.20, 0.32, 1 }, { 0.0, 0.71, 0.85, 0.65 }, { 0.75, 0.92, 1 })
importBtn:HookScript("OnEnter", function(self)
  if ForeverSniperDB.railExpanded then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Импорт из дашборда", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Вставить список itemID=цена[:кол-во]", 0.85, 0.90, 0.96)
  GameTooltip:Show()
end)
importBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

-- 4b. Bait Posting ("На живца", shown in Full Mode)
do
  local baitBtn = MakeRailButton(importBtn, -5, "Interface\\Icons\\INV_Misc_Fish_02", "На живца")
  baitBtn:SetColors({ 0.14, 0.10, 0.06, 1 }, { 0.22, 0.16, 0.08, 1 }, { 0.92, 0.70, 0.03, 0.75 }, { 0.99, 0.86, 0.45 })
  if baitBtn.ico then
    baitBtn.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end
  baitBtn:HookScript("OnEnter", function(self)
    if ForeverSniperDB.railExpanded then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("На живца (Ловушка)", 0.96, 0.70, 0.03)
    GameTooltip:AddLine("Выставить 1 шт на мин. срок (2ч/12ч) по заданной цене", 0.85, 0.90, 0.96, true)
    GameTooltip:Show()
  end)
  baitBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
  f._baitBtn = baitBtn

  local skip1Btn = MakeRailButton(baitBtn, -5, "Interface\\Icons\\INV_Misc_Spyglass_02", "Пропуск 1шт: ВЫКЛ")
  if skip1Btn.ico then
    skip1Btn.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end
  local function RefreshRailSkip1Btn()
    if ForeverSniperDB.skipSingleBait then
      skip1Btn:SetColors({ 0.16, 0.12, 0.03, 1 }, { 0.24, 0.18, 0.05, 1 }, { 0.92, 0.70, 0.03, 0.85 }, { 1, 0.94, 0.70 })
      if skip1Btn.ico then skip1Btn.ico:SetDesaturated(false); skip1Btn.ico:SetAlpha(1) end
      skip1Btn.railText:SetText("|cfff59e0bПропуск 1шт: ВКЛ|r")
    else
      skip1Btn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.13, 0.17, 0.25, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.45, 0.52, 0.62 })
      if skip1Btn.ico then skip1Btn.ico:SetDesaturated(true); skip1Btn.ico:SetAlpha(0.45) end
      skip1Btn.railText:SetText("|cff64748bПропуск 1шт: ВЫКЛ|r")
    end
  end
  skip1Btn:SetScript("OnClick", function()
    ForeverSniperDB.skipSingleBait = not ForeverSniperDB.skipSingleBait
    if f._refreshSkip1Btn then f._refreshSkip1Btn() end
    if ForeverSniperDB.skipSingleBait then
      print("|cfff59e0bGoblin Broker:|r фильтр «Пропуск 1 шт» |cff10b981ВКЛ|r — игнорируем стакаемые лоты по 1 шт.")
    else
      print("|cfff59e0bGoblin Broker:|r фильтр «Пропуск 1 шт» |cff94a3b8ВЫКЛ|r — ловим все лоты.")
    end
  end)
  skip1Btn:HookScript("OnEnter", function(self)
    if ForeverSniperDB.railExpanded then return end
    if GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(ForeverSniperDB.skipSingleBait and "Пропуск 1 шт (наживка): ВКЛ" or "Пропуск 1 шт (наживка): ВЫКЛ", 0.96, 0.70, 0.03)
      GameTooltip:AddLine("Пропускать стакаемые лоты по 1 шт, чтобы ловить реальные пачки (2+ шт).", 0.85, 0.90, 0.96, true)
      GameTooltip:Show()
    end
  end)
  skip1Btn:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  f._skip1Btn = skip1Btn
  f._refreshRailSkip1Btn = RefreshRailSkip1Btn
end

-- 5. Keybind / Sniper Hotkey Info (pinned to bottom of rail)
local hotkeyBtn = MakeRailButton(nil, nil, "Interface\\AddOns\\ForeverSniper\\rail_hotkey.tga", "Клавиши", true)
hotkeyBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.22, 0.29, 0.42, 1 }, { 0.98, 0.94, 0.54 })
hotkeyBtn:HookScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Горячие клавиши", 0.96, 0.70, 0.03)
  local bk = GetBindingKey and GetBindingKey("FOREVERSNIPER_BUY")
  local sk = GetBindingKey and GetBindingKey("FOREVERSNIPER_SCAN")
  local btk = GetBindingKey and GetBindingKey("FOREVERSNIPER_BAIT")
  GameTooltip:AddDoubleLine("Купить / Подтв.:", bk or "не задана", 0.85, 0.90, 0.96, 0.98, 0.94, 0.54)
  GameTooltip:AddDoubleLine("Старт / Пауза:", sk or "не задана", 0.85, 0.90, 0.96, 0.85, 0.90, 0.96)
  GameTooltip:AddDoubleLine("Наживка (1 шт):", btk or "не задана", 0.85, 0.90, 0.96, 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Назначить: ESC -> Назначение клавиш -> Goblin Broker", 0.60, 0.72, 0.84, true)
  GameTooltip:Show()
end)
hotkeyBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
hotkeyBtn:SetScript("OnClick", function()
  local bk = GetBindingKey and GetBindingKey("FOREVERSNIPER_BUY")
  print("|cfff59e0bGoblin Broker:|r клавиша покупки: |cfffef08a" .. (bk or "не задана") .. "|r (ESC -> Назначение клавиш -> Goblin Broker: Forever).")
end)

-- ============================================================================
-- Section 1: Unified Header Bar (Preset Picker + Save + Add Item)
-- ============================================================================
local SyncActivePresetSnapshot
local UpdateStatus, OpenExportModal, RefreshOverrideBindings, ClearPendingDeal
local presetBar = CreateFrame("Frame", nil, f)
presetBar:SetPoint("TOPLEFT", toolRail, "TOPRIGHT", 10, 0)
presetBar:SetPoint("TOPRIGHT", -12, -60)
presetBar:SetHeight(26)

local addToggleBtn = CreateFlatButton(nil, presetBar, 132, 22, "+ Добавить товар")
addToggleBtn:SetPoint("RIGHT", 0, 0)
addToggleBtn:SetColors({ 0.08, 0.13, 0.22, 1 }, { 0.13, 0.20, 0.32, 1 }, { 0.92, 0.70, 0.03, 0.65 }, { 0.98, 0.88, 0.55 })

local cfgCard = CreateFrame("Frame", nil, f, "BackdropTemplate")
cfgCard:SetPoint("TOPLEFT", presetBar, "BOTTOMLEFT", 0, -4)
cfgCard:SetPoint("TOPRIGHT", presetBar, "BOTTOMRIGHT", 0, -4)
cfgCard:SetHeight(124)
cfgCard:SetBackdrop(FLAT_BACKDROP)
cfgCard:SetBackdropColor(0.067, 0.094, 0.153, 1)
cfgCard:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)
cfgCard:Hide()

local iconFrame = CreateFrame("Button", nil, cfgCard, "BackdropTemplate")
iconFrame:SetSize(38, 38)
iconFrame:SetPoint("TOPLEFT", 12, -12)
iconFrame:SetBackdrop(FLAT_BACKDROP)
iconFrame:SetBackdropColor(0.03, 0.04, 0.07, 1)
iconFrame:SetBackdropBorderColor(0.25, 0.33, 0.45, 1)
iconFrame:EnableMouse(true)
iconFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

local itemIcon = iconFrame:CreateTexture(nil, "ARTWORK")
itemIcon:SetPoint("TOPLEFT", 2, -2)
itemIcon:SetPoint("BOTTOMRIGHT", -2, 2)
itemIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
itemIcon:SetTexture(134400)

iconFrame:SetScript("OnLeave", function()
  if GameTooltip then GameTooltip:Hide() end
end)

local targetNameText = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
targetNameText:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 10, -2)
targetNameText:SetPoint("RIGHT", cfgCard, "RIGHT", -12, 0)
targetNameText:SetJustifyH("LEFT")
targetNameText:SetWordWrap(false)
targetNameText:SetText("Нет выбранного предмета")

local targetSubText = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
targetSubText:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMRIGHT", 10, 2)
targetSubText:SetPoint("RIGHT", cfgCard, "RIGHT", -12, 0)
targetSubText:SetJustifyH("LEFT")
targetSubText:SetWordWrap(false)
targetSubText:SetText("|cff64748bЗадайте ID и лимит ниже или нажмите Импорт|r")

local cfgDiv = cfgCard:CreateTexture(nil, "ARTWORK")
cfgDiv:SetHeight(1)
cfgDiv:SetPoint("TOPLEFT", 12, -58)
cfgDiv:SetPoint("TOPRIGHT", -12, -58)
cfgDiv:SetColorTexture(0.16, 0.22, 0.34, 0.65)

-- Row 1: ID + Max Unit Price (g / s / c, right-aligned to -12)
local idLabel = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
idLabel:SetPoint("TOPLEFT", 12, -70)
idLabel:SetText("|cff94a3b8ID предмета:|r")

local idInput = CreateFrame("EditBox", nil, cfgCard, "BackdropTemplate")
StyleFlatBox(idInput, 82, 24)
idInput:SetPoint("LEFT", idLabel, "RIGHT", 6, 0)
idInput:SetScript("OnTextChanged", function(self, userInput)
  local txt = self:GetText() or ""
  local linkID = txt:match("item:(%d+)")
  if linkID then
    self:SetText(linkID)
    return
  end
  local clean = txt:gsub("%D+", "")
  if clean ~= txt then
    self:SetText(clean)
    return
  end
  if userInput then
    local previewID = tonumber(clean)
    if previewID and previewID > 0 then
      local icon, nm, r, g, b = GetItemVisuals(previewID)
      itemIcon:SetTexture(icon)
      iconFrame:SetBackdropBorderColor(r, g, b, 0.85)
      targetNameText:SetText(nm)
      targetNameText:SetTextColor(r, g, b)
    end
  end
end)

local cUnit = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
cUnit:SetPoint("RIGHT", cfgCard, "TOPRIGHT", -12, -75)
cUnit:SetText(ICON_COPPER)

local copperInput = CreateFrame("EditBox", nil, cfgCard, "BackdropTemplate")
StyleFlatBox(copperInput, 36, 24)
copperInput:SetPoint("RIGHT", cUnit, "LEFT", -4, 0)
copperInput:SetNumeric(true)
copperInput:SetMaxLetters(2)
copperInput:SetJustifyH("RIGHT")

local sUnit = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sUnit:SetPoint("RIGHT", copperInput, "LEFT", -8, 0)
sUnit:SetText(ICON_SILVER)

local silverInput = CreateFrame("EditBox", nil, cfgCard, "BackdropTemplate")
StyleFlatBox(silverInput, 36, 24)
silverInput:SetPoint("RIGHT", sUnit, "LEFT", -4, 0)
silverInput:SetNumeric(true)
silverInput:SetMaxLetters(2)
silverInput:SetJustifyH("RIGHT")

local gUnit = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
gUnit:SetPoint("RIGHT", silverInput, "LEFT", -8, 0)
gUnit:SetText(ICON_GOLD)

local goldInput = CreateFrame("EditBox", nil, cfgCard, "BackdropTemplate")
StyleFlatBox(goldInput, 64, 24)
goldInput:SetPoint("RIGHT", gUnit, "LEFT", -4, 0)
goldInput:SetNumeric(true)
goldInput:SetJustifyH("RIGHT")

local limLabel = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
limLabel:SetPoint("RIGHT", goldInput, "LEFT", -8, 0)
limLabel:SetText("|cff94a3b8Макс. цена:|r")

-- Row 2: Max Qty per Buy + Apply CTA
local maxLimitLabel = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
maxLimitLabel:SetPoint("TOPLEFT", 12, -98)
maxLimitLabel:SetText("|cff94a3b8Лимит покупки (шт):|r")

local maxQtyLimitInput = CreateFrame("EditBox", nil, cfgCard, "BackdropTemplate")
StyleFlatBox(maxQtyLimitInput, 70, 24)
maxQtyLimitInput:SetPoint("LEFT", maxLimitLabel, "RIGHT", 8, 0)
maxQtyLimitInput:SetNumeric(true)
maxQtyLimitInput:SetJustifyH("RIGHT")

local maxLimitHint = cfgCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
maxLimitHint:SetPoint("LEFT", maxQtyLimitInput, "RIGHT", 8, 0)
maxLimitHint:SetText("|cff64748b(0 = все)|r")

local setTargetBtn = CreateFlatButton(nil, cfgCard, 128, 24, "Применить")
setTargetBtn:SetPoint("TOP", maxQtyLimitInput, "TOP", 0, 0)
setTargetBtn:SetPoint("RIGHT", cfgCard, "RIGHT", -12, 0)
setTargetBtn:SetColors({ 0.45, 0.32, 0.02, 1 }, { 0.62, 0.44, 0.03, 1 }, { 0.92, 0.70, 0.03, 0.9 }, { 1, 0.96, 0.85 })

-- Defined after targetNameText / targetSubText / idInput / goldInput so upvalues resolve cleanly
local function ApplyPreviewItemID(itemID)
  local id = tonumber(itemID)
  if not id or id <= 0 then return false end
  idInput:SetText(tostring(id))
  local icon, nm, r, g, b = GetItemVisuals(id)
  itemIcon:SetTexture(icon)
  iconFrame:SetBackdropBorderColor(r, g, b, 0.9)
  targetNameText:SetText(nm)
  targetNameText:SetTextColor(r, g, b)
  targetSubText:SetText(string.format("|cff64748bID %d  |  Укажите цену и нажмите Применить|r", id))
  goldInput:SetFocus()
  return true
end

local SetCfgOpen

local function PreviewDraggedItem()
  if not GetCursorInfo then return false end
  local kind, itemID = GetCursorInfo()
  if kind == "item" and itemID then
    ClearCursor()
    if SetCfgOpen then SetCfgOpen(true) end
    return ApplyPreviewItemID(itemID)
  end
  return false
end

iconFrame:SetScript("OnReceiveDrag", PreviewDraggedItem)
iconFrame:SetScript("OnClick", PreviewDraggedItem)
iconFrame:SetScript("OnEnter", function(self)
  local sel = tonumber(idInput:GetText()) or ForeverSniperDB.selectedID
  if GameTooltip then
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    if sel and sel > 0 then
      GameTooltip:SetItemByID(sel)
      GameTooltip:AddLine(" ")
    end
    GameTooltip:AddLine("Перетащите предмет из сумки сюда для автозаполнения ID", 0.58, 0.75, 0.90)
    GameTooltip:Show()
  end
end)

-- ============================================================================
-- Section 2: Preset Selector & Update CTA inside Header Bar
-- ============================================================================
local presetPickerBtn = CreateFlatButton(nil, presetBar, 214, 22, "Шаблон: не выбран")
presetPickerBtn:SetPoint("LEFT", 0, 0)
presetPickerBtn.label:SetJustifyH("LEFT")
presetPickerBtn.label:ClearAllPoints()
presetPickerBtn.label:SetPoint("LEFT", 10, 0)
presetPickerBtn.label:SetPoint("RIGHT", -22, 0)
presetPickerBtn.arrow = presetPickerBtn:CreateTexture(nil, "OVERLAY")
presetPickerBtn.arrow:SetSize(10, 10)
presetPickerBtn.arrow:SetPoint("RIGHT", -7, 0)
presetPickerBtn.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
presetPickerBtn.arrow:SetTexCoord(0, 1, 0, 1)
presetPickerBtn.arrow:SetVertexColor(0.75, 0.82, 0.92, 0.9)
presetPickerBtn:SetColors({ 0.06, 0.09, 0.16, 1 }, { 0.10, 0.15, 0.25, 1 }, { 0.20, 0.28, 0.40, 0.85 }, { 0.96, 0.85, 0.45 })
presetPickerBtn:HookScript("OnEnter", function(self)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Выбор и управление шаблонами", 0.96, 0.70, 0.03)
  if ForeverSniperDB.autoScan then
    GameTooltip:AddLine("Недоступно во время сканирования — нажмите Пауза.", 0.95, 0.40, 0.45, true)
  else
    GameTooltip:AddLine("Клик: открыть список шаблонов (выбрать, создать, удалить).", 0.85, 0.90, 0.96, true)
  end
  GameTooltip:Show()
end)
presetPickerBtn:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

local wlSaveBtn = CreateFlatButton(nil, presetBar, 104, 22, "• Обновить")
wlSaveBtn:SetPoint("LEFT", presetPickerBtn, "RIGHT", 6, 0)
wlSaveBtn:SetColors({ 0.02, 0.44, 0.30, 1 }, { 0.04, 0.58, 0.40, 1 }, { 0.92, 0.70, 0.03, 0.95 }, { 1, 0.98, 0.85 })
wlSaveBtn:Hide()
wlSaveBtn:HookScript("OnEnter", function(self)
  if not GameTooltip then return end
  local ap = ForeverSniperDB.activePreset
  local p = ap and ForeverSniperDB.presets and ForeverSniperDB.presets[ap]
  if not p then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Обновить шаблон «" .. ap .. "»", 0.96, 0.70, 0.03)
  local curWL, preWL = ForeverSniperDB.watchlist or {}, p.watchlist or {}
  local curQty, preQty = ForeverSniperDB.qtyLimits or {}, p.qtyLimits or {}
  local shown = 0
  for id, price in pairs(curWL) do
    if not preWL[id] then
      local _, iname = GetItemVisuals(id)
      GameTooltip:AddDoubleLine("+ " .. iname, FormatCoinsPlain(price), 0.0, 0.82, 0.95, 0.85, 0.92, 0.98)
      shown = shown + 1
    elseif preWL[id] ~= price or (curQty[id] or 0) ~= (preQty[id] or 0) then
      local _, iname = GetItemVisuals(id)
      GameTooltip:AddDoubleLine("~ " .. iname, FormatCoinsPlain(preWL[id]) .. " -> " .. FormatCoinsPlain(price), 0.96, 0.70, 0.03, 0.98, 0.92, 0.70)
      shown = shown + 1
    end
    if shown >= 8 then break end
  end
  for id in pairs(preWL) do
    if not curWL[id] and shown < 10 then
      local _, iname = GetItemVisuals(id)
      GameTooltip:AddLine("- Удалён: " .. iname, 0.95, 0.40, 0.45)
      shown = shown + 1
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Клик: сохранить текущие товары и цены в шаблон", 0.06, 0.85, 0.55)
  GameTooltip:Show()
end)
wlSaveBtn:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

local wlBox = CreateFrame("Frame", nil, f, "BackdropTemplate")
wlBox:SetPoint("TOPLEFT", presetBar, "BOTTOMLEFT", 0, -6)
wlBox:SetPoint("TOPRIGHT", presetBar, "BOTTOMRIGHT", 0, -6)
wlBox:SetHeight(112)
wlBox:SetBackdrop(FLAT_BACKDROP)
wlBox:SetBackdropColor(0.028, 0.042, 0.082, 1)
wlBox:SetBackdropBorderColor(0.15, 0.21, 0.32, 1)
wlBox:EnableMouse(true)
wlBox:SetScript("OnReceiveDrag", PreviewDraggedItem)

do
  local colHdr = CreateFrame("Frame", nil, wlBox)
  colHdr:SetPoint("TOPLEFT", 6, -5)
  colHdr:SetPoint("TOPRIGHT", -6, -5)
  colHdr:SetHeight(16)
  local c1 = colHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c1:SetPoint("LEFT", 36, 0); c1:SetText("|cff64748bТовар|r")
  local c2 = colHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c2:SetPoint("LEFT", 190, 0); c2:SetText("|cff64748bЛимит|r")
  local c3 = colHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c3:SetPoint("LEFT", 278, 0); c3:SetText("|cff64748bАХ мин.|r")
  local c4 = colHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c4:SetPoint("RIGHT", -28, 0); c4:SetText("|cff64748bОсталось|r")
end

local isCfgOpen = false
local isCfgNewMode = false
local function ResetManualInputs()
  idInput:SetText("")
  goldInput:SetText("")
  silverInput:SetText("")
  copperInput:SetText("")
  maxQtyLimitInput:SetText("")
  itemIcon:SetTexture(134400)
  iconFrame:SetBackdropBorderColor(0.25, 0.33, 0.45, 1)
  targetNameText:SetText("Новый предмет")
  targetNameText:SetTextColor(0.85, 0.90, 0.96)
  targetSubText:SetText("|cff64748bПеретащите предмет из сумки или введите ID|r")
  setTargetBtn:SetLabel("Добавить")
end

local function SyncAdaptiveLayout()
  if ForeverSniperDB.miniMode then return end
  local rowsVis = isCfgOpen and 6 or 10
  local boxH = 34 + rowsVis * 34
  wlBox:SetHeight(boxH)
  f:SetHeight((isCfgOpen and 416 or 286) + boxH)
end

SetCfgOpen = function(open)
  isCfgOpen = not not open
  if ForeverSniperDB.miniMode then
    cfgCard:Hide()
    return
  end
  wlBox:ClearAllPoints()
  if isCfgOpen then
    cfgCard:Show()
    wlBox:SetPoint("TOPLEFT", cfgCard, "BOTTOMLEFT", 0, -6)
    wlBox:SetPoint("TOPRIGHT", cfgCard, "BOTTOMRIGHT", 0, -6)
    addToggleBtn:SetLabel("- Скрыть форму")
    addToggleBtn:SetColors({ 0.24, 0.18, 0.04, 1 }, { 0.36, 0.26, 0.06, 1 }, { 0.92, 0.70, 0.03, 0.9 }, { 1, 0.94, 0.75 })
  else
    cfgCard:Hide()
    wlBox:SetPoint("TOPLEFT", presetBar, "BOTTOMLEFT", 0, -6)
    wlBox:SetPoint("TOPRIGHT", presetBar, "BOTTOMRIGHT", 0, -6)
    addToggleBtn:SetLabel("+ Добавить товар")
    addToggleBtn:SetColors({ 0.08, 0.13, 0.22, 1 }, { 0.13, 0.20, 0.32, 1 }, { 0.92, 0.70, 0.03, 0.65 }, { 0.98, 0.88, 0.55 })
  end
  SyncAdaptiveLayout()
end

addToggleBtn:SetScript("OnClick", function()
  if not isCfgOpen then
    isCfgNewMode = true
    ResetManualInputs()
    SetCfgOpen(true)
  else
    isCfgNewMode = false
    SetCfgOpen(false)
  end
end)

local wlScroll = CreateFrame("ScrollFrame", "ForeverSniperWLScroll", wlBox, "UIPanelScrollFrameTemplate")
wlScroll:SetPoint("TOPLEFT", 6, -24)
wlScroll:SetPoint("BOTTOMRIGHT", -12, 6)

-- Hide Blizzard's clunky medieval scroll arrows and use a sleek flat thumb
local wlScrollBar = _G["ForeverSniperWLScrollScrollBar"]
if wlScrollBar then
  local up = _G["ForeverSniperWLScrollScrollBarScrollUpButton"]
  local dn = _G["ForeverSniperWLScrollScrollBarScrollDownButton"]
  if up then up:Hide(); up:SetSize(1, 1) end
  if dn then dn:Hide(); dn:SetSize(1, 1) end
  local thumb = wlScrollBar:GetThumbTexture()
  if thumb then
    thumb:SetColorTexture(0.24, 0.32, 0.46, 0.85)
    thumb:SetWidth(4)
  end
end

local wlContent = CreateFrame("Frame", nil, wlScroll)
wlContent:SetSize(490, 168)
wlScroll:SetScrollChild(wlContent)

local wlRows = {}

-- Zero-State Onboarding Panel inside wlBox (shown when watchlist is empty)
do
  local ob = CreateFrame("Frame", nil, wlBox)
  ob:SetAllPoints()
  ob:Hide()
  local obTitle = ob:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  obTitle:SetPoint("TOP", 0, -30)
  obTitle:SetText("|cfff59e0bСписок отслеживания пуст|r")
  local obSub = ob:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  obSub:SetPoint("TOP", obTitle, "BOTTOM", 0, -6)
  obSub:SetText("|cff94a3b8Загрузите готовые наборы под рынок Forever или вставьте Импорт|r")
  local obBtn = CreateFlatButton(nil, ob, 250, 28, "Загрузить 5 PRO-наборов под Forever")
  obBtn:SetPoint("TOP", obSub, "BOTTOM", 0, -14)
  obBtn:SetColors({ 0.02, 0.42, 0.30, 1 }, { 0.04, 0.56, 0.40, 1 }, { 0.06, 0.73, 0.51, 0.9 }, { 1, 1, 1 })
  ob.btn = obBtn
  wlBox.emptyPanel = ob
end

f.miniContextText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
f.miniContextText:SetPoint("TOPLEFT", toolRail, "TOPRIGHT", 12, -1)
f.miniContextText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -61)
f.miniContextText:SetJustifyH("LEFT")
f.miniContextText:SetWordWrap(false)
f.miniContextText:Hide()

-- ============================================================================
-- Section 3: Live Market Monitor Card (Clean 2-Column Readout)
-- ============================================================================
local dealCard = CreateFrame("Frame", nil, f, "BackdropTemplate")
dealCard:SetPoint("TOPLEFT", wlBox, "BOTTOMLEFT", 0, -10)
dealCard:SetPoint("TOPRIGHT", wlBox, "BOTTOMRIGHT", 0, -10)
dealCard:SetHeight(80)
dealCard:SetBackdrop(FLAT_BACKDROP)
dealCard:SetBackdropColor(0.067, 0.094, 0.153, 1)
dealCard:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)

local dealStripe = dealCard:CreateTexture(nil, "ARTWORK")
dealStripe:SetWidth(3)
dealStripe:SetPoint("TOPLEFT", 1, -1)
dealStripe:SetPoint("BOTTOMLEFT", 1, 1)
dealStripe:SetColorTexture(0.25, 0.33, 0.45, 0.65)

local dealBadge = dealCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dealBadge:SetPoint("TOPLEFT", 14, -8)
dealBadge:SetText("|cff94a3b8ОЖИДАНИЕ|r")

local dealDelta = dealCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dealDelta:SetPoint("TOPRIGHT", -14, -8)
dealDelta:SetText("")

local dealQtyRight = dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dealQtyRight:SetPoint("TOPRIGHT", -14, -26)
dealQtyRight:SetJustifyH("RIGHT")
dealQtyRight:SetText("")

local dealTitle = dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dealTitle:SetPoint("TOPLEFT", 14, -26)
dealTitle:SetPoint("RIGHT", dealQtyRight, "LEFT", -8, 0)
dealTitle:SetJustifyH("LEFT")
dealTitle:SetWordWrap(false)
dealTitle:SetText("|cffcbd5e1Нажмите «Старт скан» при открытом окне аукциона|r")

local dealTotalRight = dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dealTotalRight:SetPoint("BOTTOMRIGHT", -14, 9)
dealTotalRight:SetJustifyH("RIGHT")
dealTotalRight:SetText("")

local dealMeta = dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dealMeta:SetPoint("BOTTOMLEFT", 14, 9)
dealMeta:SetPoint("RIGHT", dealTotalRight, "LEFT", -8, 0)
dealMeta:SetJustifyH("LEFT")
dealMeta:SetWordWrap(false)
dealMeta:SetText("")

-- ============================================================================
-- Section 4: Execution Dock (Utility Row + Full-Width Hero Buy CTA)
-- ============================================================================
local execRow = CreateFrame("Frame", nil, f)
execRow:SetPoint("TOPLEFT", dealCard, "BOTTOMLEFT", 0, -8)
execRow:SetPoint("TOPRIGHT", dealCard, "BOTTOMRIGHT", 0, -8)
execRow:SetHeight(28)

local scanBtn = CreateFlatButton("ForeverSniperScanBtn", execRow, 188, 28, "Старт скан")
scanBtn:SetPoint("LEFT", 0, 0)

local trackBtn = CreateFlatButton(nil, execRow, 158, 28, DOT_GRAY .. " Выбрано: 0")
trackBtn:SetPoint("LEFT", scanBtn, "RIGHT", 6, 0)

local skipBtn = CreateFlatButton(nil, execRow, 142, 28, "Сброс лота")
skipBtn:SetPoint("RIGHT", 0, 0)
skipBtn:SetFlatEnabled(false)

local function RefreshTrackBtn()
  local total = state.allItems and #state.allItems or 0
  local active = state.queue and #state.queue or 0
  if total == 0 then
    trackBtn:SetLabel(DOT_GRAY .. " Нет целей")
    trackBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.13, 0.17, 0.25, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.65, 0.72, 0.82 })
  elseif active > 1 then
    trackBtn:SetLabel(DOT_GREEN .. string.format(" По кругу: %d/%d", active, total))
    trackBtn:SetColors({ 0.07, 0.10, 0.17, 1 }, { 0.12, 0.17, 0.27, 1 }, { 0.18, 0.25, 0.36, 0.85 }, { 0.85, 0.92, 0.98 })
  elseif active == 1 then
    trackBtn:SetLabel(DOT_AMBER .. string.format(" Фокус: 1/%d", total))
    trackBtn:SetColors({ 0.07, 0.10, 0.17, 1 }, { 0.12, 0.17, 0.27, 1 }, { 0.18, 0.25, 0.36, 0.85 }, { 0.96, 0.86, 0.55 })
  else
    trackBtn:SetLabel(DOT_GRAY .. string.format(" Выбрано: 0/%d", total))
    trackBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.13, 0.17, 0.25, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.65, 0.72, 0.82 })
  end
end

trackBtn:SetScript("OnClick", function()
  local all = state.allItems or {}
  if #all == 0 then return end
  ForeverSniperDB.tracked = ForeverSniperDB.tracked or {}
  local active = state.queue and #state.queue or 0
  if active < #all then
    for _, id in ipairs(all) do ForeverSniperDB.tracked[id] = true end
  elseif #all > 1 then
    local keep = ForeverSniperDB.selectedID or all[1]
    for _, id in ipairs(all) do ForeverSniperDB.tracked[id] = (id == keep) end
  end
  if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
  UpdateStatus()
end)

trackBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Режим обхода сканера (по моноклям)", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Если включено 2+ глаза — сканер автоматически", 0.85, 0.90, 0.96, true)
  GameTooltip:AddLine("идёт по кругу. Если 1 — бьёт в одну цель.", 0.85, 0.90, 0.96, true)
  GameTooltip:AddLine("Клик: включить все глаза / фокус на текущем.", 0.60, 0.72, 0.84, true)
  GameTooltip:Show()
end)
trackBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local buyBtn = CreateFlatButton("ForeverSniperBuyBtn", f, 500, 46, "Нет активного лота")
buyBtn:SetPoint("TOPLEFT", execRow, "BOTTOMLEFT", 0, -8)
buyBtn:SetPoint("TOPRIGHT", execRow, "BOTTOMRIGHT", 0, -8)
buyBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
buyBtn.label:SetFontObject("GameFontNormalLarge")
buyBtn.label:SetWidth(484)
buyBtn.label:SetWordWrap(false)
buyBtn:SetColors({ 0.11, 0.15, 0.22, 1 }, { 0.11, 0.15, 0.22, 1 }, { 0.20, 0.27, 0.38, 1 }, { 0.72, 0.78, 0.88 })
buyBtn:SetFlatEnabled(false)

-- ============================================================================
-- Detailed Session Purchase Log Window
-- ============================================================================
local logFrame = CreateFrame("Frame", "ForeverSniperLogFrame", UIParent, "BackdropTemplate")
local RenderLogFrame
local logTab = "session"
local logCloseBtn, logClearBtn, logExportBtn
local tabSessionBtn, tabItemsBtn, tabDaysBtn, tabHoursBtn

do
logFrame:SetSize(740, 596)
logFrame:SetPoint("CENTER")
logFrame:SetFrameStrata("DIALOG")
logFrame:SetToplevel(true)
logFrame:SetClampedToScreen(true)
logFrame:SetMovable(true)
logFrame:EnableMouse(true)
logFrame:RegisterForDrag("LeftButton")
logFrame:SetScript("OnDragStart", logFrame.StartMoving)
logFrame:SetScript("OnDragStop", logFrame.StopMovingOrSizing)
logFrame:SetBackdrop(FLAT_BACKDROP)
logFrame:SetBackdropColor(0.043, 0.067, 0.125, 1)
logFrame:SetBackdropBorderColor(0.22, 0.28, 0.40, 1)
AttachDropShadow(logFrame, 14, 0.80)
logFrame:Hide()

local logAccent = logFrame:CreateTexture(nil, "ARTWORK")
logAccent:SetHeight(2)
logAccent:SetPoint("TOPLEFT", 1, -1)
logAccent:SetPoint("TOPRIGHT", -1, -1)
logAccent:SetColorTexture(1, 1, 1, 1)
logAccent:SetGradient("HORIZONTAL", CreateColor(0.92, 0.70, 0.03, 1), CreateColor(0.06, 0.73, 0.51, 1))

local logTitle = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
logTitle:SetPoint("TOPLEFT", 16, -12)
logTitle:SetText("|cfff59e0bАналитика и лог покупок|r")

logCloseBtn = CreateFlatButton(nil, logFrame, 24, 24, "X")
logCloseBtn:SetPoint("TOPRIGHT", -14, -12)
logCloseBtn:SetColors({ 0.10, 0.13, 0.21, 1 }, { 0.55, 0.14, 0.18, 1 }, { 0.22, 0.28, 0.40, 1 }, { 0.85, 0.89, 0.95 })
logCloseBtn:SetScript("OnClick", function() logFrame:Hide() end)

logClearBtn = CreateFlatButton(nil, logFrame, 104, 24, "Очистить")
logClearBtn:SetPoint("RIGHT", logCloseBtn, "LEFT", -8, 0)
logClearBtn:SetColors({ 0.28, 0.10, 0.13, 1 }, { 0.45, 0.14, 0.18, 1 }, { 0.65, 0.22, 0.28, 0.85 }, { 1, 0.86, 0.88 })

logExportBtn = CreateFlatButton(nil, logFrame, 118, 24, "Экспорт отчёта")
logExportBtn:SetPoint("RIGHT", logClearBtn, "LEFT", -6, 0)
logExportBtn:SetColors({ 0.08, 0.22, 0.36, 1 }, { 0.12, 0.30, 0.48, 1 }, { 0.0, 0.71, 0.85, 0.75 }, { 0.9, 0.97, 1 })

tabSessionBtn = CreateFlatButton(nil, logFrame, 136, 22, "Сессия")
tabSessionBtn:SetPoint("TOPLEFT", 14, -44)
tabItemsBtn = CreateFlatButton(nil, logFrame, 136, 22, "По товарам")
tabItemsBtn:SetPoint("LEFT", tabSessionBtn, "RIGHT", 8, 0)
tabDaysBtn = CreateFlatButton(nil, logFrame, 136, 22, "По дням")
tabDaysBtn:SetPoint("LEFT", tabItemsBtn, "RIGHT", 8, 0)
tabHoursBtn = CreateFlatButton(nil, logFrame, 136, 22, "По часам (24ч)")
tabHoursBtn:SetPoint("LEFT", tabDaysBtn, "RIGHT", 8, 0)
f._tabSalesBtn = CreateFlatButton(nil, logFrame, 136, 22, "Продажи")
f._tabSalesBtn:SetPoint("LEFT", tabHoursBtn, "RIGHT", 8, 0)

-- 3 KPI Summary Cards (Qty, Total Spent, Weighted Avg / Win-Rate)
local function CreateKpiCard(xOffset, w, labelTxt, accentR, accentG, accentB)
  local c = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
  c:SetSize(w, 46)
  c:SetPoint("TOPLEFT", xOffset, -72)
  c:SetBackdrop(FLAT_BACKDROP)
  c:SetBackdropColor(0.067, 0.094, 0.153, 1)
  c:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)

  local top = c:CreateTexture(nil, "ARTWORK")
  top:SetHeight(2)
  top:SetPoint("TOPLEFT", 1, -1)
  top:SetPoint("TOPRIGHT", -1, -1)
  top:SetColorTexture(accentR, accentG, accentB, 0.85)

  local lbl = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lbl:SetPoint("TOPLEFT", 10, -8)
  lbl:SetWidth(w - 20)
  lbl:SetJustifyH("LEFT")
  lbl:SetWordWrap(false)
  lbl:SetText("|cff94a3b8" .. labelTxt .. "|r")
  c.lbl = lbl

  local val = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  val:SetPoint("BOTTOMLEFT", 10, 7)
  val:SetPoint("BOTTOMRIGHT", -10, 7)
  val:SetJustifyH("LEFT")
  val:SetWordWrap(false)
  val:SetText("—")
  c.val = val
  return c
end

local kpiQtyCard   = CreateKpiCard(14,  232, "КУПЛЕНО (СДЕЛОК)", 0.0,  0.71, 0.85)
local kpiSpentCard = CreateKpiCard(254, 232, "ВСЕГО ПОТРАЧЕНО",  0.92, 0.70, 0.03)
local kpiAvgCard   = CreateKpiCard(494, 232, "СРЕДНЯЯ ЗА ШТУКУ", 0.06, 0.73, 0.51)

-- Grouped Per-Item Summary Section (Session tab)
local sumSectionHdr = logFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sumSectionHdr:SetPoint("TOPLEFT", 16, -126)
sumSectionHdr:SetText("|cfff59e0bСВОДКА ПО ПРЕДМЕТАМ|r")

local sumBox = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
sumBox:SetPoint("TOPLEFT", 14, -142)
sumBox:SetPoint("TOPRIGHT", -14, -142)
sumBox:SetHeight(92)
sumBox:SetBackdrop(FLAT_BACKDROP)
sumBox:SetBackdropColor(0.028, 0.042, 0.082, 1)
sumBox:SetBackdropBorderColor(0.15, 0.21, 0.32, 1)

local sumScroll = CreateFrame("ScrollFrame", "ForeverSniperSumScroll", sumBox, "UIPanelScrollFrameTemplate")
sumScroll:SetPoint("TOPLEFT", 4, -4)
sumScroll:SetPoint("BOTTOMRIGHT", -14, 4)

local sumScrollBar = _G["ForeverSniperSumScrollScrollBar"]
if sumScrollBar then
  local up = _G["ForeverSniperSumScrollScrollBarScrollUpButton"]
  local dn = _G["ForeverSniperSumScrollScrollBarScrollDownButton"]
  if up then up:Hide(); up:SetSize(1, 1) end
  if dn then dn:Hide(); dn:SetSize(1, 1) end
  local thumb = sumScrollBar:GetThumbTexture()
  if thumb then
    thumb:SetColorTexture(0.24, 0.32, 0.46, 0.85)
    thumb:SetWidth(4)
  end
end

local sumContent = CreateFrame("Frame", nil, sumScroll)
sumContent:SetSize(688, 96)
sumScroll:SetScrollChild(sumContent)
local sumRows = {}

local sumEmpty = sumBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sumEmpty:SetPoint("CENTER")
sumEmpty:SetText("|cff64748bНет покупок за текущую сессию|r")

-- Chronological Deal Log Header (Session tab)
local detSectionHdr = logFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
detSectionHdr:SetPoint("TOPLEFT", 16, -244)
detSectionHdr:SetText("|cff94a3b8ДЕТАЛЬНЫЙ ЛОГ СДЕЛОК|r")

local logColHdr = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
logColHdr:SetPoint("TOPLEFT", 14, -260)
logColHdr:SetPoint("TOPRIGHT", -14, -260)
logColHdr:SetHeight(22)
logColHdr:SetBackdrop(FLAT_BACKDROP)
logColHdr:SetBackdropColor(0.067, 0.094, 0.153, 1)
logColHdr:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)

local chTime = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chTime:SetPoint("LEFT", 8, 0); chTime:SetWidth(56); chTime:SetJustifyH("LEFT"); chTime:SetText("|cff94a3b8Время|r")
local chItem = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chItem:SetPoint("LEFT", chTime, "RIGHT", 6, 0); chItem:SetWidth(330); chItem:SetJustifyH("LEFT"); chItem:SetText("|cff94a3b8Предмет|r")
local chQty = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chQty:SetPoint("LEFT", chItem, "RIGHT", 6, 0); chQty:SetWidth(54); chQty:SetJustifyH("RIGHT"); chQty:SetText("|cff94a3b8Шт|r")
local chUnit = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chUnit:SetPoint("LEFT", chQty, "RIGHT", 6, 0); chUnit:SetWidth(98); chUnit:SetJustifyH("RIGHT"); chUnit:SetText("|cff94a3b8За шт|r")
local chTotal = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chTotal:SetPoint("RIGHT", -16, 0); chTotal:SetWidth(104); chTotal:SetJustifyH("RIGHT"); chTotal:SetText("|cff94a3b8Итого|r")

local logBox = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
logBox:SetPoint("TOPLEFT", logColHdr, "BOTTOMLEFT", 0, -2)
logBox:SetPoint("BOTTOMRIGHT", -14, 14)
logBox:SetBackdrop(FLAT_BACKDROP)
logBox:SetBackdropColor(0.028, 0.042, 0.082, 1)
logBox:SetBackdropBorderColor(0.15, 0.21, 0.32, 1)

local logScroll = CreateFrame("ScrollFrame", "ForeverSniperLogScroll", logBox, "UIPanelScrollFrameTemplate")
logScroll:SetPoint("TOPLEFT", 4, -4)
logScroll:SetPoint("BOTTOMRIGHT", -14, 4)

local logScrollBar = _G["ForeverSniperLogScrollScrollBar"]
if logScrollBar then
  local up = _G["ForeverSniperLogScrollScrollBarScrollUpButton"]
  local dn = _G["ForeverSniperLogScrollScrollBarScrollDownButton"]
  if up then up:Hide(); up:SetSize(1, 1) end
  if dn then dn:Hide(); dn:SetSize(1, 1) end
  local thumb = logScrollBar:GetThumbTexture()
  if thumb then
    thumb:SetColorTexture(0.24, 0.32, 0.46, 0.85)
    thumb:SetWidth(4)
  end
end

local logContent = CreateFrame("Frame", nil, logScroll)
logContent:SetSize(688, 290)
logScroll:SetScrollChild(logContent)
local logRows = {}

local logEmpty = logBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
logEmpty:SetPoint("CENTER")
logEmpty:SetText("|cff64748bСделки появятся здесь автоматически после выкупа лотов|r")

-- Persistent All-Time / Daily Analytics Table (По товарам / По дням / По часам tabs)
local anaColHdr = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
anaColHdr:SetPoint("TOPLEFT", 14, -126)
anaColHdr:SetPoint("TOPRIGHT", -14, -126)
anaColHdr:SetHeight(22)
anaColHdr:SetBackdrop(FLAT_BACKDROP)
anaColHdr:SetBackdropColor(0.067, 0.094, 0.153, 1)
anaColHdr:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)
anaColHdr:Hide()

local ac1 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac1:SetPoint("LEFT", 12, 0); ac1:SetWidth(148); ac1:SetJustifyH("LEFT")
local ac2 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac2:SetPoint("LEFT", ac1, "RIGHT", 6, 0); ac2:SetWidth(74); ac2:SetJustifyH("RIGHT")
local ac3 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac3:SetPoint("LEFT", ac2, "RIGHT", 6, 0); ac3:SetWidth(80); ac3:SetJustifyH("RIGHT")
local ac4 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac4:SetPoint("LEFT", ac3, "RIGHT", 6, 0); ac4:SetWidth(84); ac4:SetJustifyH("RIGHT")
local ac5 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac5:SetPoint("LEFT", ac4, "RIGHT", 6, 0); ac5:SetWidth(84); ac5:SetJustifyH("RIGHT")
local ac6 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac6:SetPoint("LEFT", ac5, "RIGHT", 6, 0); ac6:SetWidth(64); ac6:SetJustifyH("RIGHT")
local ac7 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac7:SetPoint("RIGHT", -20, 0); ac7:SetWidth(98); ac7:SetJustifyH("RIGHT")

local anaBox = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
anaBox:SetPoint("TOPLEFT", anaColHdr, "BOTTOMLEFT", 0, -2)
anaBox:SetPoint("BOTTOMRIGHT", -14, 14)
anaBox:SetBackdrop(FLAT_BACKDROP)
anaBox:SetBackdropColor(0.028, 0.042, 0.082, 1)
anaBox:SetBackdropBorderColor(0.15, 0.21, 0.32, 1)
anaBox:Hide()

local anaEmpty = anaBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
anaEmpty:SetPoint("CENTER")
anaEmpty:SetText("|cff64748bСтатистика пока не накоплена|r")
anaEmpty:Hide()

local anaScroll = CreateFrame("ScrollFrame", "ForeverSniperAnaScroll", anaBox, "UIPanelScrollFrameTemplate")
anaScroll:SetPoint("TOPLEFT", 4, -4)
anaScroll:SetPoint("BOTTOMRIGHT", -14, 4)

local anaScrollBar = _G["ForeverSniperAnaScrollScrollBar"]
if anaScrollBar then
  local up = _G["ForeverSniperAnaScrollScrollBarScrollUpButton"]
  local dn = _G["ForeverSniperAnaScrollScrollBarScrollDownButton"]
  if up then up:Hide(); up:SetSize(1, 1) end
  if dn then dn:Hide(); dn:SetSize(1, 1) end
  local thumb = anaScrollBar:GetThumbTexture()
  if thumb then thumb:SetColorTexture(0.24, 0.32, 0.46, 0.85); thumb:SetWidth(4) end
end

local anaContent = CreateFrame("Frame", nil, anaScroll)
anaContent:SetSize(688, 380)
anaScroll:SetScrollChild(anaContent)
local anaRows = {}

local function FormatWinRate(buys, missed)
  local tot = (buys or 0) + (missed or 0)
  if tot == 0 then return "|cff64748b—|r" end
  local pct = math.floor((buys / tot) * 100 + 0.5)
  local col = pct >= 75 and "|cff10b981" or (pct >= 50 and "|cfff59e0b" or "|cfff43f5e")
  return string.format("%s%d%%|r", col, pct)
end

local function RefreshLogTabButtons()
  local function StyleTab(btn, active)
    if active then
      btn:SetColors({ 0.04, 0.16, 0.14, 1 }, { 0.06, 0.24, 0.20, 1 }, { 0.06, 0.73, 0.51, 0.85 }, { 0.85, 1, 0.94 })
    else
      btn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.13, 0.17, 0.25, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.65, 0.72, 0.82 })
    end
  end
  StyleTab(tabSessionBtn, logTab == "session")
  StyleTab(tabItemsBtn, logTab == "items")
  StyleTab(tabDaysBtn, logTab == "days")
  StyleTab(tabHoursBtn, logTab == "hours")
  if f._tabSalesBtn then StyleTab(f._tabSalesBtn, logTab == "sales") end
  logClearBtn:SetLabel((logTab == "session" or logTab == "sales") and "Очистить" or "Сбросить базу")
end

local function GetAnaRow(i)
  local row = anaRows[i]
  if not row then
    row = CreateFrame("Frame", nil, anaContent, "BackdropTemplate")
    row:SetSize(684, 24); row:SetBackdrop(FLAT_BACKDROP); row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
      if not GameTooltip then return end
      if self.salesInfo then
        local si = self.salesInfo
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cff10b981" .. (si.name or "Продажа") .. " — Выгода|r")
        GameTooltip:AddDoubleLine("Продано:", string.format("%d шт (%d сд.)", si.qty or 0, si.deals or 0), 0.85, 0.90, 0.96, 1, 1, 1)
        GameTooltip:AddDoubleLine("Грязная выручка:", FormatCoinsPlain(si.gross or 0), 0.85, 0.90, 0.96, 0.96, 0.85, 0.45)
        GameTooltip:AddDoubleLine("Комиссия АХ (5%):", "-" .. FormatCoinsPlain(si.cut or 0), 0.85, 0.90, 0.96, 0.95, 0.35, 0.40)
        GameTooltip:AddDoubleLine("Чистая выручка:", FormatCoinsPlain(si.net or 0), 0.85, 0.90, 0.96, 0.85, 0.95, 1)
        if (si.avgBuy or 0) > 0 then
          GameTooltip:AddDoubleLine("Ср. цена покупки:", FormatCoinsPlain(si.avgBuy), 0.85, 0.90, 0.96, 1, 1, 1)
          GameTooltip:AddDoubleLine("Ср. продажа (-5%):", FormatCoinsPlain(si.avgSellNet or 0), 0.85, 0.90, 0.96, 0.78, 0.86, 0.96)
          local pCol = (si.profit or 0) >= 0 and {0.06, 0.85, 0.55} or {0.95, 0.35, 0.40}
          local pSign = (si.profit or 0) >= 0 and "+" or "-"
          GameTooltip:AddDoubleLine("Чистая выгода:", string.format("%s%s (%+d%%)", pSign, FormatCoinsPlain(math.abs(si.profit or 0)), si.roi or 0), 0.85, 0.90, 0.96, pCol[1], pCol[2], pCol[3])
        else
          GameTooltip:AddLine("Нет истории покупок по этому предмету в снайпере", 0.65, 0.72, 0.82)
        end
        GameTooltip:Show()
        return
      end
      if not self.roiItemID then return end
      local t = EnsureTelemetryDB()
      local it = t.items and t.items[self.roiItemID]
      if not it then return end
      local _, iname = GetItemVisuals(self.roiItemID)
      local qty = it.qty or 0
      local avgU = (qty > 0) and math.floor((it.spent or 0) / qty) or 0
      local avgFloor = ((it.scanCnt or 0) > 0) and math.floor((it.scanSum or 0) / it.scanCnt) or 0
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("|cfff59e0b" .. (it.name or iname) .. " — ROI Аналитика|r")
      if avgFloor > 0 then
        local netResale = math.floor(avgFloor * 0.95)
        GameTooltip:AddDoubleLine("Ср. мин. АХ (рынок):", FormatCoinsPlain(avgFloor), 0.85, 0.90, 0.96, 0.96, 0.85, 0.45)
        GameTooltip:AddDoubleLine("Выручка после 5% АХ:", FormatCoinsPlain(netResale), 0.85, 0.90, 0.96, 0.78, 0.86, 0.96)
        if avgU > 0 then
          local netUnit = netResale - avgU
          local netTot = netUnit * qty
          local roi = math.floor((netUnit / avgU) * 100 + 0.5)
          local rc = roi > 0 and {0.06, 0.85, 0.55} or {0.95, 0.35, 0.40}
          GameTooltip:AddDoubleLine("Ср. цена покупки:", FormatCoinsPlain(avgU), 0.85, 0.90, 0.96, 1, 1, 1)
          GameTooltip:AddDoubleLine("Чистый ROI (после 5%):", string.format("%+d%%", roi), 0.85, 0.90, 0.96, rc[1], rc[2], rc[3])
          GameTooltip:AddDoubleLine("Чистая прибыль (" .. qty .. " шт):", (netTot >= 0 and "+" or "-") .. FormatCoinsPlain(math.abs(netTot)), 0.85, 0.90, 0.96, rc[1], rc[2], rc[3])
        end
      else
        GameTooltip:AddLine("Недостаточно сканов для расчёта рынка", 0.65, 0.72, 0.82)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row:SetScript("OnMouseUp", function(self, btn)
      if btn == "LeftButton" and self.roiItemID then
        selectedAnaItemID = self.roiItemID
        RenderLogFrame()
      end
    end)
    row.barFill = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    row.barFill:SetPoint("TOPLEFT", 1, -1)
    row.barFill:SetPoint("BOTTOMLEFT", 1, 1)
    row.barFill:SetColorTexture(0.06, 0.73, 0.51, 0.22)
    row.barFill:Hide()
    row.ico = row:CreateTexture(nil, "ARTWORK"); row.ico:SetSize(16, 16); row.ico:SetPoint("LEFT", 6, 0); row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.c1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c1:SetJustifyH("LEFT"); row.c1:SetWordWrap(false)
    row.c2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c2:SetPoint("LEFT", row.c1, "RIGHT", 6, 0); row.c2:SetWidth(74); row.c2:SetJustifyH("RIGHT"); row.c2:SetWordWrap(false)
    row.c3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c3:SetPoint("LEFT", row.c2, "RIGHT", 6, 0); row.c3:SetWidth(80); row.c3:SetJustifyH("RIGHT"); row.c3:SetWordWrap(false)
    row.c4 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c4:SetPoint("LEFT", row.c3, "RIGHT", 6, 0); row.c4:SetWidth(84); row.c4:SetJustifyH("RIGHT"); row.c4:SetWordWrap(false)
    row.c5 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c5:SetPoint("LEFT", row.c4, "RIGHT", 6, 0); row.c5:SetWidth(84); row.c5:SetJustifyH("RIGHT"); row.c5:SetWordWrap(false)
    row.c6 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c6:SetPoint("LEFT", row.c5, "RIGHT", 6, 0); row.c6:SetWidth(64); row.c6:SetJustifyH("RIGHT"); row.c6:SetWordWrap(false)
    row.c7 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c7:SetPoint("RIGHT", -6, 0); row.c7:SetWidth(98); row.c7:SetJustifyH("RIGHT"); row.c7:SetWordWrap(false)
    anaRows[i] = row
  end
  row.roiItemID = nil
  row.salesInfo = nil
  return row
end

RenderLogFrame = function()
  RefreshLogTabButtons()
  local isSession = (logTab == "session")
  if isSession then
    sumSectionHdr:Show(); sumBox:Show(); detSectionHdr:Show(); logColHdr:Show(); logBox:Show()
    anaColHdr:Hide(); anaBox:Hide()
  else
    sumSectionHdr:Hide(); sumBox:Hide(); detSectionHdr:Hide(); logColHdr:Hide(); logBox:Hide()
    anaColHdr:Show(); anaBox:Show()
    anaBox:ClearAllPoints()
    anaBox:SetPoint("TOPLEFT", anaColHdr, "BOTTOMLEFT", 0, -2)
    anaBox:SetPoint("BOTTOMRIGHT", -14, 14)
  end

  if not isSession then
    if logTab == "sales" then
      local s = f._sales and f._sales.ensure() or { totalQty = 0, totalDeals = 0, totalGross = 0, totalNet = 0, totalCut = 0, byItem = {} }
      local t = EnsureTelemetryDB()
      local buyAvgByName = {}
      for id, it in pairs(t.items or {}) do
        if (it.qty or 0) > 0 and (it.spent or 0) > 0 then
          local nm = it.name
          if not nm or nm == "" then
            local _, visName = GetItemVisuals(id)
            nm = visName
          end
          if nm and nm ~= "" then
            buyAvgByName[nm] = math.floor(it.spent / it.qty)
          end
        end
      end

      local skeys = {}
      local totMatchedProfit, totMatchedCost = 0, 0
      for nm, it in pairs(s.byItem or {}) do
        table.insert(skeys, nm)
        local avgBuy = buyAvgByName[it.name or nm] or 0
        if avgBuy > 0 and (it.qty or 0) > 0 then
          local cost = avgBuy * it.qty
          totMatchedCost = totMatchedCost + cost
          totMatchedProfit = totMatchedProfit + ((it.net or 0) - cost)
        end
      end
      table.sort(skeys, function(a, b)
        return (s.byItem[a].net or 0) > (s.byItem[b].net or 0)
      end)

      if totMatchedCost > 0 then
        local totRoi = math.floor((totMatchedProfit / totMatchedCost) * 100 + 0.5)
        local pSign = totMatchedProfit >= 0 and "|cff10b981+" or "|cfff43f5e-"
        local rCol = totRoi >= 0 and "|cff10b981" or "|cfff43f5e"
        kpiQtyCard.lbl:SetText("|cff10b981ВЫГОДА (ПРОДАЖА - ПОКУПКА)|r")
        kpiQtyCard.val:SetFontObject("GameFontNormalLarge")
        kpiQtyCard.val:SetText(string.format("%s|r%s %s(%+d%%)|r", pSign, FormatCoins(math.abs(totMatchedProfit)), rCol, totRoi))
      else
        kpiQtyCard.lbl:SetText("|cff10b981ЧИСТАЯ ВЫРУЧКА (ПОЧТА)|r")
        kpiQtyCard.val:SetFontObject("GameFontNormalLarge")
        kpiQtyCard.val:SetText((s.totalNet or 0) > 0 and FormatCoins(s.totalNet) or ("|cff64748b0|r" .. ICON_COPPER))
      end

      kpiSpentCard.lbl:SetText("|cff94a3b8ПРОДАНО · ВЫРУЧКА (-5%)|r")
      kpiSpentCard.val:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d) ·|r %s", s.totalQty or 0, s.totalDeals or 0, (s.totalNet or 0) > 0 and FormatCoins(s.totalNet) or ("0" .. ICON_COPPER)))

      local os = state.ownedSummary
      kpiAvgCard.lbl:SetText("|cff94a3b8НА АУКЦИОНЕ СЕЙЧАС|r")
      if os then
        local pendingTxt = (os.soldCount and os.soldCount > 0) and string.format(" |cfff59e0b(+%d продано, 1ч)|r", os.soldCount) or ""
        kpiAvgCard.val:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d) ·|r %s%s", os.activeQty or 0, os.activeCount or 0, (os.activeValue or 0) > 0 and FormatCoins(os.activeValue) or ("0" .. ICON_COPPER), pendingTxt))
      else
        kpiAvgCard.val:SetText("|cff64748bОткройте вкладку Аукционы|r")
      end

      for _, r in ipairs(anaRows) do r:Hide() end
      ac1:SetText("|cff94a3b8Предмет|r"); ac2:SetText("|cff94a3b8Продано|r"); ac3:SetText("|cff94a3b8Ср. покупка|r")
      ac4:SetText("|cff94a3b8Ср. прод(-5%)|r"); ac5:SetText("|cff94a3b8Выручка (-5%)|r")
      ac6:SetText("|cff94a3b8ROI|r"); ac6:Show()
      ac7:SetText("|cff94a3b8Выгода|r"); ac7:Show()

      local y = 0
      for i, nm in ipairs(skeys) do
        local it = s.byItem[nm]
        local row = GetAnaRow(i)
        row.roiItemID = nil
        local qty = it.qty or 0
        local net = it.net or 0
        local avgSellNet = (qty > 0) and math.floor(net / qty) or 0
        local avgBuy = buyAvgByName[it.name or nm] or 0
        local profit, roi = 0, 0
        if avgBuy > 0 and qty > 0 then
          local cost = avgBuy * qty
          profit = net - cost
          roi = math.floor((profit / cost) * 100 + 0.5)
        end
        row.salesInfo = {
          name = it.name or nm, qty = qty, deals = it.deals or 0,
          gross = it.gross or 0, cut = it.cut or 0, net = net,
          avgBuy = avgBuy, avgSellNet = avgSellNet, profit = profit, roi = roi,
        }
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
        row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
        row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)
        row.barFill:Hide()
        row.ico:Hide()
        row.c1:ClearAllPoints(); row.c1:SetPoint("LEFT", 8, 0); row.c1:SetWidth(148)
        row.c1:SetText(it.name or nm); row.c1:SetTextColor(0.95, 0.98, 1)
        row.c2:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d)|r", qty, it.deals or 0))
        row.c3:SetText(avgBuy > 0 and FormatCoins(avgBuy) or "|cff475569—|r")
        row.c4:SetText(avgSellNet > 0 and FormatCoins(avgSellNet) or "|cff475569—|r")
        row.c5:SetText(net > 0 and FormatCoins(net) or "|cff475569—|r")
        row.c6:Show()
        if avgBuy > 0 then
          local rCol = roi >= 0 and "|cff10b981" or "|cfff43f5e"
          local pSign = profit >= 0 and "|cff10b981+|r" or "|cfff43f5e-|r"
          row.c6:SetText(string.format("%s%+d%%|r", rCol, roi))
          row.c7:SetText(pSign .. FormatCoins(math.abs(profit)))
        else
          row.c6:SetText("|cff475569—|r")
          row.c7:SetText("|cff475569—|r")
        end
        row.c7:Show()
        row:Show(); y = y + 26
      end
      anaContent:SetHeight(math.max(380, y))
      anaEmpty:SetText("|cff64748bОткройте почту с выручкой АХ для учёта продаж|r")
      if y == 0 then anaEmpty:Show() else anaEmpty:Hide() end
      if anaScrollBar then
        if y <= 380 then anaScrollBar:Hide() else anaScrollBar:Show() end
      end
      return
    end
    anaEmpty:SetText("|cff64748bСтатистика пока не накоплена|r")
    local t = EnsureTelemetryDB()
    local totBuys, totQty, totSpent, totSaved, totMissed, totDips, totMktSaved = 0, 0, 0, 0, 0, 0, 0
    for _, d in pairs(t.days or {}) do
      totBuys = totBuys + (d.buys or 0)
      totQty = totQty + (d.qty or 0)
      totSpent = totSpent + (d.spent or 0)
      totSaved = totSaved + (d.saved or 0)
      totMktSaved = totMktSaved + (d.mktSaved or 0)
      totMissed = totMissed + (d.missed or 0)
      totDips = totDips + (d.dips or 0)
    end
    local computedMktSaved, totNetProfit = 0, 0
    for _, it in pairs(t.items or {}) do
      if (it.qty or 0) > 0 and (it.scanCnt or 0) > 0 then
        local avgFloor = math.floor((it.scanSum or 0) / it.scanCnt)
        local avgBuy = math.floor((it.spent or 0) / it.qty)
        if avgFloor > avgBuy then
          computedMktSaved = computedMktSaved + (avgFloor - avgBuy) * it.qty
        end
        local netResale = math.floor(avgFloor * 0.95)
        totNetProfit = totNetProfit + (netResale - avgBuy) * it.qty
      end
    end
    local totalRealSaved = math.max(totMktSaved, computedMktSaved)

    if totalRealSaved > 0 then
      local roiPct = (totSpent > 0) and math.floor((totNetProfit / totSpent) * 100 + 0.5) or 0
      local roiCol = roiPct > 0 and "|cff10b981" or "|cfff43f5e"
      kpiQtyCard.lbl:SetText("|cff10b981СЭКОНОМЛЕНО ВСЕГО · ROI|r")
      kpiQtyCard.val:SetFontObject("GameFontNormalLarge")
      kpiQtyCard.val:SetText(string.format("%s %s(%+d%%)|r", FormatCoins(totalRealSaved), roiCol, roiPct))
    elseif totSaved > 0 then
      kpiQtyCard.lbl:SetText("|cff10b981СЭКОНОМЛЕНО ВСЕГО|r")
      kpiQtyCard.val:SetFontObject("GameFontNormalLarge")
      kpiQtyCard.val:SetText(FormatCoins(totSaved))
    else
      kpiQtyCard.lbl:SetText("|cff94a3b8СЭКОНОМЛЕНО ВСЕГО|r")
      kpiQtyCard.val:SetFontObject("GameFontNormal")
      kpiQtyCard.val:SetText("|cff64748b0|r" .. ICON_COPPER)
    end
    kpiSpentCard.lbl:SetText("|cff94a3b8КУПЛЕНО · ПОТРАЧЕНО|r")
    kpiSpentCard.val:SetText(string.format("|cffffffff%d шт|r |cff64748b·|r %s", totQty, totSpent > 0 and FormatCoins(totSpent) or ("0" .. ICON_COPPER)))
    kpiAvgCard.lbl:SetText("|cff94a3b8WIN-RATE / СРЫВЫ|r")
    kpiAvgCard.val:SetText(string.format("%s |cff64748b(%d / %d)|r", FormatWinRate(totBuys, totMissed), totBuys, totMissed))

    for _, r in ipairs(anaRows) do r:Hide() end
    local y = 0
    if logTab == "items" then
      ac1:SetText("|cff94a3b8Предмет|r"); ac2:SetText("|cff94a3b8Куплено|r"); ac3:SetText("|cff94a3b8Срывы / WR|r")
      ac4:SetText("|cff94a3b8Ср. мин. АХ|r"); ac5:SetText("|cff94a3b8Ср. покупка|r")
      ac6:SetText("|cff94a3b8ROI (-5%)|r"); ac6:Show()
      ac7:SetText("|cff94a3b8Чист. прибыль|r"); ac7:Show()
      local keys = {}
      for id in pairs(t.items or {}) do table.insert(keys, id) end
      table.sort(keys, function(a, b)
        local ia, ib = t.items[a], t.items[b]
        if (ia.spent or 0) ~= (ib.spent or 0) then return (ia.spent or 0) > (ib.spent or 0) end
        return (ia.scanCnt or 0) > (ib.scanCnt or 0)
      end)
      for i, id in ipairs(keys) do
        local it = t.items[id]
        local row = GetAnaRow(i)
        row.salesInfo = nil
        row.roiItemID = id
        local icon, nm, r, g, b = GetItemVisuals(id)
        local qty = it.qty or 0
        local avgU = (qty > 0) and math.floor((it.spent or 0) / qty) or 0
        local avgFloor = ((it.scanCnt or 0) > 0) and math.floor((it.scanSum or 0) / it.scanCnt) or 0
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
        row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
        row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)
        row.barFill:Hide()
        row.ico:Show(); row.ico:SetTexture(icon)
        row.c1:ClearAllPoints(); row.c1:SetPoint("LEFT", row.ico, "RIGHT", 6, 0); row.c1:SetWidth(128)
        row.c1:SetText(it.name or nm); row.c1:SetTextColor(r, g, b)
        row.c2:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d)|r", qty, it.buys or 0))
        row.c3:SetText(string.format("|cff64748b%d /|r %s", it.missed or 0, FormatWinRate(it.buys, it.missed)))
        row.c4:SetText(avgFloor > 0 and FormatCoins(avgFloor) or "|cff64748b—|r")
        row.c5:SetText(avgU > 0 and FormatCoins(avgU) or (it.minDip and FormatCoins(it.minDip) or "|cff64748b—|r"))
        row.c6:Show(); row.c7:Show()
        if avgU > 0 and avgFloor > 0 then
          local netResale = math.floor(avgFloor * 0.95)
          local netUnit = netResale - avgU
          local netTot = netUnit * qty
          local roi = math.floor((netUnit / avgU) * 100 + 0.5)
          local rCol = roi > 0 and "|cff10b981" or "|cfff43f5e"
          row.c6:SetText(string.format("%s%+d%%|r", rCol, roi))
          row.c7:SetText(string.format("%s%s|r %s", rCol, netTot >= 0 and "+" or "-", FormatCoins(math.abs(netTot))))
        else
          row.c6:SetText("|cff475569—|r")
          row.c7:SetText("|cff475569—|r")
        end
        row:Show(); y = y + 26
      end
    elseif logTab == "days" then
      ac1:SetText("|cff94a3b8Дата|r"); ac2:SetText("|cff94a3b8Сделок|r"); ac3:SetText("|cff94a3b8Срывы / WR|r")
      ac4:SetText("|cff94a3b8Просадок|r"); ac5:SetText("|cff94a3b8Сэкономлено|r")
      ac6:SetText(""); ac6:Hide()
      ac7:SetText("|cff94a3b8Потрачено|r"); ac7:Show()
      local days = {}
      for dk in pairs(t.days or {}) do table.insert(days, dk) end
      table.sort(days, function(a, b) return a > b end)
      for i, dk in ipairs(days) do
        local d = t.days[dk]
        local row = GetAnaRow(i)
        row.roiItemID = nil
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
        row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
        row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)
        row.barFill:Hide()
        row.ico:Hide()
        row.c1:ClearAllPoints(); row.c1:SetPoint("LEFT", 8, 0); row.c1:SetWidth(148)
        row.c1:SetText(dk); row.c1:SetTextColor(0.92, 0.96, 1)
        row.c2:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d)|r", d.qty or 0, d.buys or 0))
        row.c3:SetText(string.format("|cff64748b%d /|r %s", d.missed or 0, FormatWinRate(d.buys, d.missed)))
        row.c4:SetText(string.format("|cfff59e0b%d|r", d.dips or 0))
        local dSav = d.mktSaved or 0
        if #days == 1 and totalRealSaved > dSav then dSav = totalRealSaved end
        row.c5:SetText(dSav > 0 and ("|cff10b981+|r" .. FormatCoins(dSav)) or "|cff475569—|r")
        row.c6:Hide()
        row.c7:Show(); row.c7:SetText((d.spent or 0) > 0 and FormatCoins(d.spent) or "|cff64748b—|r")
        row:Show(); y = y + 26
      end
    else
      ac1:SetText("|cff94a3b8Час (24ч)|r"); ac2:SetText("|cff94a3b8Куплено|r"); ac3:SetText("|cff94a3b8Срывы / WR|r")
      ac4:SetText("|cff94a3b8Просадок|r"); ac5:SetText("|cff94a3b8Сэкономлено|r")
      ac6:SetText(""); ac6:Hide()
      ac7:SetText("|cff94a3b8Потрачено|r"); ac7:Show()
      local maxAct = 1
      for hr = 0, 23 do
        local h = t.hours and t.hours[hr]
        local act = h and ((h.dips or 0) + (h.buys or 0) + (h.missed or 0)) or 0
        if act > maxAct then maxAct = act end
      end
      for hr = 0, 23 do
        local i = hr + 1
        local h = (t.hours and t.hours[hr]) or { buys = 0, qty = 0, spent = 0, mktSaved = 0, missed = 0, dips = 0 }
        local act = (h.dips or 0) + (h.buys or 0) + (h.missed or 0)
        local row = GetAnaRow(i)
        row.roiItemID = nil
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
        row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
        row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)
        row.ico:Hide()
        if act > 0 then
          row.barFill:SetWidth(math.max(6, math.floor(680 * (act / maxAct))))
          if act == maxAct then
            row.barFill:SetColorTexture(0.92, 0.70, 0.03, 0.24)
          else
            row.barFill:SetColorTexture(0.06, 0.73, 0.51, 0.18)
          end
          row.barFill:Show()
        else
          row.barFill:Hide()
        end
        row.c1:ClearAllPoints(); row.c1:SetPoint("LEFT", 8, 0); row.c1:SetWidth(148)
        row.c1:SetText(string.format("%02d:00 - %02d:59", hr, hr))
        row.c1:SetTextColor(act > 0 and 0.95 or 0.45, act > 0 and 0.98 or 0.52, act > 0 and 1.0 or 0.62)
        row.c2:SetText((h.buys or 0) > 0 and string.format("|cffffffff%d шт|r |cff64748b(%d)|r", h.qty or 0, h.buys or 0) or "|cff4755690|r")
        row.c3:SetText(string.format("|cff64748b%d /|r %s", h.missed or 0, FormatWinRate(h.buys, h.missed)))
        row.c4:SetText((h.dips or 0) > 0 and string.format("|cfff59e0b%d|r", h.dips) or "|cff4755690|r")
        local hSav = h.mktSaved or 0
        row.c5:SetText(hSav > 0 and ("|cff10b981+|r" .. FormatCoins(hSav)) or "|cff475569—|r")
        row.c6:Hide()
        row.c7:Show(); row.c7:SetText((h.spent or 0) > 0 and FormatCoins(h.spent) or "|cff475569—|r")
        row:Show(); y = y + 26
      end
    end
    anaContent:SetHeight(math.max(380, y))
    if y == 0 then anaEmpty:Show() else anaEmpty:Hide() end
    if anaScrollBar then
      if y <= 380 then anaScrollBar:Hide() else anaScrollBar:Show() end
    end
    return
  end

  kpiQtyCard.lbl:SetText("|cff94a3b8КУПЛЕНО (СДЕЛОК)|r")
  kpiSpentCard.lbl:SetText("|cff94a3b8ВСЕГО ПОТРАЧЕНО|r")
  kpiAvgCard.lbl:SetText("|cff94a3b8СРЕДНЯЯ ЗА ШТУКУ|r")
  local hist = state.sessionBuys.history or {}
  local sb = state.sessionBuys
  local totalQty = sb.totalQty or 0
  local totalCopper = sb.totalCopper or 0
  local totalMktSaved = sb.totalMktSaved or 0
  local overallAvg = (totalQty > 0) and math.floor(totalCopper / totalQty) or 0

  kpiQtyCard.val:SetFontObject("GameFontNormal")
  kpiQtyCard.val:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d)|r", totalQty, #hist))
  kpiSpentCard.val:SetText(totalCopper > 0 and FormatCoins(totalCopper) or "|cff64748b0|r" .. ICON_COPPER)
  if totalMktSaved > 0 then
    kpiAvgCard.lbl:SetText("|cff10b981СЭКОНОМЛЕНО (СЕССИЯ)|r")
    kpiAvgCard.val:SetText(FormatCoins(totalMktSaved))
  else
    kpiAvgCard.lbl:SetText("|cff94a3b8СРЕДНЯЯ ЗА ШТУКУ|r")
    kpiAvgCard.val:SetText(overallAvg > 0 and FormatCoins(overallAvg) or "|cff64748b—|r")
  end

  -- Aggregate per-item summary
  local byItem = {}
  local itemOrder = {}
  for _, h in ipairs(hist) do
    local id = h.itemID or 0
    if not byItem[id] then
      byItem[id] = { itemID = id, name = h.name, qty = 0, total = 0, deals = 0 }
      table.insert(itemOrder, id)
    end
    local agg = byItem[id]
    agg.qty = agg.qty + (tonumber(h.qty) or 1)
    agg.total = agg.total + (tonumber(h.totalCost) or 0)
    agg.deals = agg.deals + 1
    if h.name and not agg.name then agg.name = h.name end
  end
  table.sort(itemOrder, function(a, b) return byItem[a].total > byItem[b].total end)

  for _, r in ipairs(sumRows) do r:Hide() end
  local sy = 0
  for i, id in ipairs(itemOrder) do
    local agg = byItem[id]
    local srow = sumRows[i]
    if not srow then
      srow = CreateFrame("Frame", nil, sumContent, "BackdropTemplate")
      srow:SetSize(684, 22)
      srow:SetBackdrop(FLAT_BACKDROP)
      srow:SetBackdropColor(0.055, 0.078, 0.135, 1)
      srow:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.35)

      srow.ico = srow:CreateTexture(nil, "ARTWORK")
      srow.ico:SetSize(16, 16); srow.ico:SetPoint("LEFT", 6, 0)
      srow.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

      srow.nm = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      srow.nm:SetPoint("LEFT", srow.ico, "RIGHT", 6, 0); srow.nm:SetWidth(320); srow.nm:SetJustifyH("LEFT"); srow.nm:SetWordWrap(false)

      srow.q = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      srow.q:SetPoint("LEFT", srow.nm, "RIGHT", 6, 0); srow.q:SetWidth(84); srow.q:SetJustifyH("RIGHT")

      srow.avg = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      srow.avg:SetPoint("LEFT", srow.q, "RIGHT", 8, 0); srow.avg:SetWidth(120); srow.avg:SetJustifyH("RIGHT")

      srow.tot = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      srow.tot:SetPoint("RIGHT", -6, 0); srow.tot:SetWidth(104); srow.tot:SetJustifyH("RIGHT")

      sumRows[i] = srow
    end

    local icon, nm, r, g, b = GetItemVisuals(agg.itemID)
    local avgU = math.floor(agg.total / math.max(1, agg.qty))
    srow:ClearAllPoints()
    srow:SetPoint("TOPLEFT", 0, -sy)
    srow.ico:SetTexture(icon)
    srow.nm:SetText(agg.name or nm)
    srow.nm:SetTextColor(r, g, b)
    srow.q:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d)|r", agg.qty, agg.deals))
    srow.avg:SetText("|cff94a3b8Ср:|r " .. FormatCoins(avgU))
    srow.tot:SetText(FormatCoins(agg.total))
    srow:Show()
    sy = sy + 24
  end
  sumContent:SetHeight(math.max(96, sy))
  if #itemOrder == 0 then sumEmpty:Show() else sumEmpty:Hide() end
  if sumScrollBar then
    if #itemOrder <= 4 then sumScrollBar:Hide() else sumScrollBar:Show() end
  end

  for _, r in ipairs(logRows) do r:Hide() end

  local rowH = 24
  local y = 0
  local idx = 0
  for i = #hist, 1, -1 do
    idx = idx + 1
    local h = hist[i]
    local row = logRows[idx]
    if not row then
      row = CreateFrame("Frame", nil, logContent, "BackdropTemplate")
      row:SetSize(684, rowH)
      row:SetBackdrop(FLAT_BACKDROP)
      row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)
      row:EnableMouse(true)
      row:SetScript("OnEnter", function(self)
        local h = self.dealRef
        if not GameTooltip or not h then return end
        local qty = math.max(1, tonumber(h.qty) or 1)
        local total = tonumber(h.totalCost) or 0
        local unitAvg = math.floor(total / qty)
        local t = EnsureTelemetryDB()
        local it = h.itemID and t.items and t.items[h.itemID]
        local avgFloor = (it and (it.scanCnt or 0) > 0) and math.floor((it.scanSum or 0) / it.scanCnt) or 0
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cfff59e0b" .. (h.name or ("Item #" .. tostring(h.itemID))) .. " x" .. qty .. "|r")
        GameTooltip:AddDoubleLine("Куплено по:", FormatCoinsPlain(unitAvg) .. "/шт", 0.85, 0.90, 0.96, 1, 1, 1)
        if avgFloor > 0 then
          local netResale = math.floor(avgFloor * 0.95)
          local netTot = (netResale - unitAvg) * qty
          local roi = (unitAvg > 0) and math.floor(((netResale - unitAvg) / unitAvg) * 100 + 0.5) or 0
          local rc = roi > 0 and {0.06, 0.85, 0.55} or {0.95, 0.35, 0.40}
          GameTooltip:AddDoubleLine("Ср. мин. АХ (рынок):", FormatCoinsPlain(avgFloor), 0.85, 0.90, 0.96, 0.96, 0.85, 0.45)
          GameTooltip:AddDoubleLine("Выручка (-5% АХ):", FormatCoinsPlain(netResale) .. "/шт", 0.85, 0.90, 0.96, 0.78, 0.86, 0.96)
          GameTooltip:AddDoubleLine("ROI сделки:", string.format("%+d%% (%s%s)", roi, netTot >= 0 and "+" or "-", FormatCoinsPlain(math.abs(netTot))), 0.85, 0.90, 0.96, rc[1], rc[2], rc[3])
        end
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row:SetScript("OnMouseUp", function(self, btn)
      if btn == "LeftButton" and self.roiItemID then
        selectedAnaItemID = self.roiItemID
        RenderLogFrame()
      end
    end)

      row.t = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.t:SetPoint("LEFT", 6, 0); row.t:SetWidth(56); row.t:SetJustifyH("LEFT")

      row.ico = row:CreateTexture(nil, "ARTWORK")
      row.ico:SetSize(16, 16); row.ico:SetPoint("LEFT", row.t, "RIGHT", 6, 0)
      row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

      row.nm = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.nm:SetPoint("LEFT", row.ico, "RIGHT", 6, 0); row.nm:SetWidth(308); row.nm:SetJustifyH("LEFT"); row.nm:SetWordWrap(false)

      row.q = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.q:SetPoint("LEFT", row.nm, "RIGHT", 6, 0); row.q:SetWidth(54); row.q:SetJustifyH("RIGHT"); row.q:SetWordWrap(false)

      row.u = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.u:SetPoint("LEFT", row.q, "RIGHT", 6, 0); row.u:SetWidth(98); row.u:SetJustifyH("RIGHT"); row.u:SetWordWrap(false)

      row.tot = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.tot:SetPoint("RIGHT", -6, 0); row.tot:SetWidth(104); row.tot:SetJustifyH("RIGHT"); row.tot:SetWordWrap(false)

      logRows[idx] = row
    end

    local icon, nm, r, g, b = GetItemVisuals(h.itemID)
    local qty = math.max(1, tonumber(h.qty) or 1)
    local total = tonumber(h.totalCost) or 0
    local unitAvg = math.floor(total / qty)

    row.dealRef = h
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetBackdropColor(idx % 2 == 1 and 0.055 or 0.040, idx % 2 == 1 and 0.078 or 0.058, idx % 2 == 1 and 0.135 or 0.105, 1)
    row.t:SetText("|cff64748b" .. (h.timeStr or "--:--:--") .. "|r")
    row.ico:SetTexture(icon)
    row.nm:SetText(h.name or nm)
    row.nm:SetTextColor(r, g, b)
    row.q:SetText("|cffffffffx" .. qty .. "|r")
    row.u:SetText(FormatCoins(unitAvg))
    row.tot:SetText(FormatCoins(total))
    row:Show()
    y = y + rowH + 4
  end

  logContent:SetHeight(math.max(220, y))
  if #hist == 0 then logEmpty:Show() else logEmpty:Hide() end
  if logScrollBar then
    if #hist <= 10 then logScrollBar:Hide() else logScrollBar:Show() end
  end
end
end -- end LogFrame scope

local function RefreshSessionBar()
  local sb = state.sessionBuys
  local count = #(sb.history or {})
  if count > 0 then
    logBtn.railText:SetText("|cff10b981Лог (" .. count .. ")|r")
    if ForeverSniperDB.railExpanded then
      logBadgeCount:Hide()
    else
      logBadgeCount:SetText("|cff10b981" .. count .. "|r")
      logBadgeCount:Show()
    end
  else
    logBtn.railText:SetText("Лог (0)")
    logBadgeCount:Hide()
  end
  if logFrame:IsShown() then
    RenderLogFrame()
  end
end

local function RecordCompletedPurchase(att)
  if not att then return end
  local sb = state.sessionBuys
  local qty = math.max(1, att.qty or 1)
  local total = att.totalCost or 0
  local unitAvg = math.floor(total / qty)
  sb.totalQty = sb.totalQty + qty
  sb.totalCopper = sb.totalCopper + total
  table.insert(sb.history, att)
  if #sb.history > 100 then table.remove(sb.history, 1) end
  local saved = (att.maxPrice and att.maxPrice > 0) and math.max(0, (att.maxPrice * qty) - total) or 0
  local t = EnsureTelemetryDB()
  local it = t.items and t.items[att.itemID]
  local avgFloor = (it and (it.scanCnt or 0) > 0) and math.floor((it.scanSum or 0) / it.scanCnt) or 0
  local mktSaved = (avgFloor > 0) and math.max(0, (avgFloor * qty) - total) or 0
  sb.totalMktSaved = (sb.totalMktSaved or 0) + mktSaved
  RecordTelemetryBuy(att.itemID, qty, total, att.name, saved, mktSaved)
  sb.lastOutcome = string.format(DOT_GREEN .. " |cff10b981Куплено:|r x%d по %s/шт (%s)", qty, FormatCoinsPlain(unitAvg), FormatCoinsPlain(total))
  RefreshSessionBar()

  -- Track bought count separately from base qtyLimits so preset dirty-state is unaffected
  local baseCap = GetBaseQtyCap(att.itemID)
  if baseCap > 0 then
    ForeverSniperDB.boughtByItem = ForeverSniperDB.boughtByItem or {}
    local newBought = (ForeverSniperDB.boughtByItem[att.itemID] or 0) + qty
    ForeverSniperDB.boughtByItem[att.itemID] = newBought
    local remaining = math.max(0, baseCap - newBought)
    if remaining > 0 then
      UpdateStatus()
    else
      -- Keep item & base limit intact, turn off its monocle so it stops buying
      ForeverSniperDB.tracked = ForeverSniperDB.tracked or {}
      ForeverSniperDB.tracked[att.itemID] = false
      RebuildQueue()
      if #(state.queue or {}) == 0 then
        ForeverSniperDB.autoScan = false
        dealBadge:SetText(DOT_GREEN .. " |cff10b981ЛИМИТ ВЫКУПЛЕН - СКАН НА ПАУЗЕ|r")
      end
      UpdateStatus()
      print(string.format("|cff10b981Goblin Broker:|r лимит по %s выкуплен (глаз-монокль выключен).", att.name or ("Item #" .. tostring(att.itemID))))
    end
  end
end

local function ClearSessionHistory()
  state.sessionBuys = {
    totalQty = 0,
    totalCopper = 0,
    history = {},
    lastOutcome = "|cff94a3b8История сессии очищена|r",
  }
  RefreshSessionBar()
end

tabSessionBtn:SetScript("OnClick", function() logTab = "session"; RenderLogFrame() end)
tabItemsBtn:SetScript("OnClick", function() logTab = "items"; RenderLogFrame() end)
tabDaysBtn:SetScript("OnClick", function() logTab = "days"; RenderLogFrame() end)
tabHoursBtn:SetScript("OnClick", function() logTab = "hours"; RenderLogFrame() end)
if f._tabSalesBtn then f._tabSalesBtn:SetScript("OnClick", function() logTab = "sales"; RenderLogFrame() end) end

-- Passive Sales Tracker (Mailbox Invoices + Owned Auctions + System Sale Chat, 0% Ban Risk)
do
  local function EnsureSalesDB()
    ForeverSniperDB.sales = ForeverSniperDB.sales or {
      totalQty = 0,
      totalDeals = 0,
      totalGross = 0,
      totalNet = 0,
      totalCut = 0,
      byItem = {},
      history = {},
      seenMail = {},
    }
    local s = ForeverSniperDB.sales
    s.byItem = s.byItem or {}
    s.history = s.history or {}
    s.seenMail = s.seenMail or {}
    return s
  end

  local errSoldPat = nil
  if type(ERR_AUCTION_SOLD_S) == "string" and ERR_AUCTION_SOLD_S ~= "" then
    errSoldPat = "^" .. ERR_AUCTION_SOLD_S:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
  end

  local function OnMailInboxUpdate()
    if not GetInboxNumItems or not GetInboxHeaderInfo or not GetInboxInvoiceInfo then return end
    local s = EnsureSalesDB()
    local nowSec = time and time() or 0
    -- Prune old deduplication keys (> 35 days)
    for k, ts in pairs(s.seenMail) do
      if nowSec > 0 and (nowSec - ts) > 3024000 then
        s.seenMail[k] = nil
      end
    end

    local num = GetInboxNumItems() or 0
    local occCounts = {}
    local newlyAdded = 0
    local newlyNet = 0

    for i = 1, num do
      local _, _, _, _, money, _, daysLeft, _, wasRead, _, _, _, isGM = GetInboxHeaderInfo(i)
      if (tonumber(money) or 0) > 0 and not wasRead and not isGM and GetInboxText then
        pcall(GetInboxText, i)
      end
      local invoiceType, itemName, playerName, bid, buyout, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(i)
      if invoiceType == "seller" and itemName and itemName ~= "" then
        local qty = tonumber(count) or 1
        local gross = tonumber(buyout) or tonumber(bid) or 0
        local cut = tonumber(consignment) or 0
        local net = (gross > 0) and math.max(0, gross - cut) or (tonumber(money) or 0)
        if gross == 0 and net > 0 then gross = net + cut end
        local dayBucket = math.floor((tonumber(daysLeft) or 30) * 24)
        local sig = string.format("%s|%s|%d|%d|%d", itemName, playerName or "", qty, gross, dayBucket)
        occCounts[sig] = (occCounts[sig] or 0) + 1
        local uniqKey = sig .. "#" .. occCounts[sig]
        if not s.seenMail[uniqKey] and net > 0 then
          s.seenMail[uniqKey] = nowSec
          s.totalQty = (s.totalQty or 0) + qty
          s.totalDeals = (s.totalDeals or 0) + 1
          s.totalGross = (s.totalGross or 0) + gross
          s.totalCut = (s.totalCut or 0) + cut
          s.totalNet = (s.totalNet or 0) + net
          local it = s.byItem[itemName]
          if not it then
            it = { name = itemName, qty = 0, deals = 0, gross = 0, cut = 0, net = 0 }
            s.byItem[itemName] = it
          end
          it.qty = (it.qty or 0) + qty
          it.deals = (it.deals or 0) + 1
          it.gross = (it.gross or 0) + gross
          it.cut = (it.cut or 0) + cut
          it.net = (it.net or 0) + net
          table.insert(s.history, 1, {
            timeStr = date and date("%H:%M:%S") or "",
            dateStr = TodayKey(),
            name = itemName,
            qty = qty,
            gross = gross,
            cut = cut,
            net = net,
            buyer = playerName or "",
          })
          if #s.history > 100 then table.remove(s.history) end
          newlyAdded = newlyAdded + qty
          newlyNet = newlyNet + net
        end
      end
    end

    if newlyAdded > 0 then
      print(string.format("|cff10b981Goblin Broker [Продажи]:|r учтено %d шт из почты (+%s чистыми).", newlyAdded, FormatCoinsPlain(newlyNet)))
      if logFrame:IsShown() and logTab == "sales" then
        RenderLogFrame()
      end
    end
  end

  local function OnOwnedAuctionsUpdated()
    if not C_AuctionHouse or not C_AuctionHouse.GetNumOwnedAuctions or not C_AuctionHouse.GetOwnedAuctionInfo then return end
    local num = C_AuctionHouse.GetNumOwnedAuctions() or 0
    local activeCount, activeQty, activeValue = 0, 0, 0
    local soldCount, soldValue = 0, 0
    local soldStatus = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold) or 1
    for i = 1, num do
      local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
      if info then
        local q = info.quantity or 1
        local amt = info.buyoutAmount or info.bidAmount or 0
        if info.status == soldStatus then
          soldCount = soldCount + 1
          soldValue = soldValue + (amt * q)
        else
          activeCount = activeCount + 1
          activeQty = activeQty + q
          activeValue = activeValue + (amt * q)
        end
      end
    end
    state.ownedSummary = {
      activeCount = activeCount,
      activeQty = activeQty,
      activeValue = activeValue,
      soldCount = soldCount,
      soldValue = soldValue,
    }
    if logFrame:IsShown() and logTab == "sales" then
      RenderLogFrame()
    end
  end

  local function OnSystemSaleChat(msg)
    if not errSoldPat or type(msg) ~= "string" then return end
    local soldName = msg:match(errSoldPat)
    if soldName and soldName ~= "" then
      state.sessionBuys.lastOutcome = DOT_GREEN .. " |cff10b981Продано:|r " .. soldName
      RefreshSessionBar()
      if IsSoundEnabled() and PlaySound then
        pcall(PlaySound, 120, "Master")
      end
    end
  end

  f._sales = {
    ensure = EnsureSalesDB,
    onMailInboxUpdate = OnMailInboxUpdate,
    onOwnedAuctionsUpdated = OnOwnedAuctionsUpdated,
    onSystemChat = OnSystemSaleChat,
  }
end

logExportBtn:SetScript("OnClick", function()
  local t = EnsureTelemetryDB()
  local lines = { "# Goblin Broker: Forever Telemetry (" .. TodayKey() .. ")" }
  for dk, d in pairs(t.days or {}) do
    table.insert(lines, string.format("DAY;%s;buys=%d;qty=%d;missed=%d;dips=%d;spent=%d;saved=%d;mktSaved=%d",
      dk, d.buys or 0, d.qty or 0, d.missed or 0, d.dips or 0, d.spent or 0, d.saved or 0, d.mktSaved or 0))
  end
  for id, it in pairs(t.items or {}) do
    local avgFloor = ((it.scanCnt or 0) > 0) and math.floor((it.scanSum or 0) / it.scanCnt) or 0
    table.insert(lines, string.format("ITEM;%d;%s;buys=%d;qty=%d;missed=%d;dips=%d;spent=%d;avgFloor=%d;mktSaved=%d",
      id, it.name or "", it.buys or 0, it.qty or 0, it.missed or 0, it.dips or 0, it.spent or 0, avgFloor, it.mktSaved or 0))
  end
  if f._sales and f._sales.ensure then
    local s = f._sales.ensure()
    for _, it in pairs(s.byItem or {}) do
      table.insert(lines, string.format("SALE;%s;qty=%d;deals=%d;gross=%d;cut=%d;net=%d",
        it.name or "", it.qty or 0, it.deals or 0, it.gross or 0, it.cut or 0, it.net or 0))
    end
  end
  OpenExportModal("Экспорт аналитики", table.concat(lines, "\n"))
  print("|cff06b6d4Goblin Broker:|r экспорт аналитики готов — скопируйте Ctrl+C.")
end)

logClearBtn:SetScript("OnClick", function()
  if logTab == "session" then
    ClearSessionHistory()
  elseif logTab == "sales" then
    ForeverSniperDB.sales = { totalQty = 0, totalDeals = 0, totalGross = 0, totalNet = 0, totalCut = 0, byItem = {}, history = {}, seenMail = {} }
    RenderLogFrame()
    print("|cff94a3b8Goblin Broker:|r статистика продаж очищена.")
  else
    ForeverSniperDB.telemetry = { days = {}, items = {}, hours = {} }
    RenderLogFrame()
    print("|cff94a3b8Goblin Broker:|r аналитика по дням, часам и товарам сброшена.")
  end
end)
logBtn:SetScript("OnClick", function()
  if logFrame:IsShown() then
    logFrame:Hide()
  else
    RenderLogFrame()
    logFrame:Show()
  end
end)

logBtn:HookScript("OnEnter", function(self)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  local sb = state.sessionBuys
  GameTooltip:AddLine("|cfff59e0bЛог покупок за сессию|r")
  if sb.totalQty > 0 then
    GameTooltip:AddDoubleLine("Всего куплено:", string.format("%d шт | %s", sb.totalQty, FormatCoinsPlain(sb.totalCopper)), 0.85, 0.90, 0.96, 0.06, 0.85, 0.55)
  end
  local hist = sb.history or {}
  if #hist == 0 then
    GameTooltip:AddLine("Пока нет завершённых покупок.", 0.65, 0.72, 0.82)
  else
    local shown = 0
    for i = #hist, 1, -1 do
      local h = hist[i]
      GameTooltip:AddDoubleLine(
        string.format("%s x%d", h.name or ("Item #" .. tostring(h.itemID)), h.qty),
        FormatCoinsPlain(h.totalCost),
        0.9, 0.94, 0.98, 0.06, 0.85, 0.55
      )
      shown = shown + 1
      if shown >= 6 then break end
    end
  end
  GameTooltip:Show()
end)
logBtn:HookScript("OnLeave", function()
  if GameTooltip then GameTooltip:Hide() end
end)

-- ============================================================================
-- Helpers & UI State Sync (Execution controls live in Execution Dock above)
-- ============================================================================
local buyHotkeySuffixCache = ""
local function RefreshBuyHotkeyCache()
  if not GetBindingKey then
    buyHotkeySuffixCache = ""
    return
  end
  local key = GetBindingKey("FOREVERSNIPER_BUY")
  if key and key ~= "" then
    buyHotkeySuffixCache = "  |cfffef08a[" .. key .. "]|r"
  else
    buyHotkeySuffixCache = ""
  end
end

local function GetBuyHotkeySuffix()
  return buyHotkeySuffixCache
end

local function ApplyRailState()
  local expanded = not not ForeverSniperDB.railExpanded
  toolRail:SetWidth(expanded and 134 or 36)
  f:SetWidth(expanded and 670 or 572)
  railToggleBtn:SetLabel(expanded and "<< Свернуть" or ">>")
  for _, btn in ipairs(railButtons) do
    if expanded then
      btn.railText:Show()
    else
      btn.railText:Hide()
    end
  end
  RefreshSessionBar()
end

railToggleBtn:SetScript("OnClick", function()
  ForeverSniperDB.railExpanded = not ForeverSniperDB.railExpanded
  ApplyRailState()
end)

local function ApplyMiniMode()
  local isMini = not not ForeverSniperDB.miniMode
  ApplyRailState()
  if isMini then
    presetBar:Hide()
    cfgCard:Hide()
    railDiv:Hide()
    importBtn:Hide()
    if f._baitBtn then f._baitBtn:Hide() end
    if f._skip1Btn then f._skip1Btn:Hide() end
    wlBox:Hide()
    if f.presetMenu then f.presetMenu:Hide() end
    dealCard:ClearAllPoints()
    dealCard:SetPoint("TOPLEFT", toolRail, "TOPRIGHT", 10, -18)
    dealCard:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -78)
    f.miniContextText:Show()
    f:SetHeight(262)
    miniBtn:SetColors({ 0.04, 0.16, 0.14, 1 }, { 0.06, 0.24, 0.20, 1 }, { 0.06, 0.73, 0.51, 0.8 }, { 0.85, 1, 0.94 })
    miniBtn.railText:SetText("|cff10b981Полный вид|r")
  else
    presetBar:Show()
    railDiv:Show()
    importBtn:Show()
    if f._baitBtn then f._baitBtn:Show() end
    if f._skip1Btn then f._skip1Btn:Show() end
    wlBox:Show()
    SetCfgOpen(isCfgOpen)
    f.miniContextText:Hide()
    dealCard:ClearAllPoints()
    dealCard:SetPoint("TOPLEFT", wlBox, "BOTTOMLEFT", 0, -10)
    dealCard:SetPoint("TOPRIGHT", wlBox, "BOTTOMRIGHT", 0, -10)
    SyncAdaptiveLayout()
    miniBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.85, 0.90, 0.96 })
    miniBtn.railText:SetText("Мини-режим")
  end
end

miniBtn:SetScript("OnClick", function()
  ForeverSniperDB.miniMode = not ForeverSniperDB.miniMode
  ApplyMiniMode()
end)

local function RefreshBuyButtonText()
  local deal = state.pendingDeal
  if not deal then
    buyBtn:SetLabel("Нет активного лота" .. GetBuyHotkeySuffix())
    buyBtn:SetColors({ 0.11, 0.15, 0.22, 1 }, { 0.11, 0.15, 0.22, 1 }, { 0.20, 0.27, 0.38, 1 }, { 0.72, 0.78, 0.88 })
    buyBtn:SetFlatEnabled(false)
    return
  end

  local cap = GetQtyCap(deal.itemID)
  local effectiveMax = (cap > 0) and math.min(deal.qty or 1, cap) or (deal.qty or 1)
  local chosenQty = math.max(1, effectiveMax)
  local totalCost = deal.exactCostForQty and deal.exactCostForQty(chosenQty) or ((deal.unitPrice or 0) * chosenQty)
  local hk = GetBuyHotkeySuffix()

  if deal.stage == "confirm" then
    local rem = math.max(0, math.ceil(10 - (GetTime() - (deal.confirmAt or GetTime()))))
    buyBtn:SetLabel(string.format("ПОДТВЕРДИТЬ x%d (%dс) | %s%s", chosenQty, rem, FormatCoinsPlain(totalCost), hk))
    buyBtn:SetColors({ 0.68, 0.40, 0.03, 1 }, { 0.85, 0.50, 0.04, 1 }, { 0.96, 0.62, 0.04, 1 }, { 1, 1, 1 })
    dealStripe:SetColorTexture(0.96, 0.62, 0.04, 1)
    dealCard:SetBackdropBorderColor(0.96, 0.62, 0.04, 0.8)
    dealBadge:SetText("|cfff59e0bПОДТВЕРЖДЕНИЕ (ПКМ — отмена)|r")
  else
    buyBtn:SetLabel(string.format("КУПИТЬ x%d  |  %s%s", chosenQty, FormatCoinsPlain(totalCost), hk))
    buyBtn:SetColors({ 0.02, 0.48, 0.34, 1 }, { 0.04, 0.62, 0.44, 1 }, { 0.06, 0.73, 0.51, 0.95 }, { 1, 1, 1 })
    dealStripe:SetColorTexture(0.06, 0.73, 0.51, 1)
    dealCard:SetBackdropBorderColor(0.06, 0.73, 0.51, 0.75)
    dealBadge:SetText("|cff10b981НАЙДЕН ВЫГОДНЫЙ ЛОТ|r")
  end
  buyBtn:SetFlatEnabled(true)

  local avgUnit = math.floor(totalCost / math.max(1, chosenQty))
  local avgText = (avgUnit > (deal.unitPrice or 0))
    and string.format("  |cff94a3b8(ср ~%s)|r", FormatCoins(avgUnit))
    or ""
  dealMeta:SetText(string.format("|cff94a3b8Цена:|r %s|cff94a3b8/шт|r%s", FormatCoins(deal.unitPrice), avgText))
  dealTotalRight:SetText(string.format("|cfff59e0bИтого:|r %s", FormatCoins(totalCost)))
end

local function SyncInputsFromSelected()
  local sel = ForeverSniperDB.selectedID
  local lim = sel and ForeverSniperDB.watchlist[sel]
  if sel and lim then
    idInput:SetText(tostring(sel))
    goldInput:SetText(tostring(math.floor(lim / 10000)))
    silverInput:SetText(tostring(math.floor((lim % 10000) / 100)))
    copperInput:SetText(tostring(lim % 100))
    local cap = GetBaseQtyCap(sel)
    maxQtyLimitInput:SetText(cap > 0 and tostring(cap) or "")
  else
    idInput:SetText("")
    goldInput:SetText("")
    silverInput:SetText("")
    copperInput:SetText("")
    maxQtyLimitInput:SetText("")
  end
end

local function RenderWatchlist()
  if ForeverSniperDB.miniMode or not f:IsShown() then return end
  for _, row in ipairs(wlRows) do
    row:Hide()
  end

  local allItems = state.allItems or {}
  if wlBox.emptyPanel then
    if #allItems == 0 then wlBox.emptyPanel:Show() else wlBox.emptyPanel:Hide() end
  end
  local needScroll = (#allItems > (isCfgOpen and 6 or 10))
  local rowW = needScroll and 476 or 486
  wlContent:SetWidth(rowW)

  local rowH = 30
  local y = 0
  for i, itemID in ipairs(allItems) do
    local row = wlRows[i]
    if not row then
      row = CreateFrame("Button", nil, wlContent, "BackdropTemplate")
      row:SetSize(rowW, rowH)
      row:SetBackdrop(FLAT_BACKDROP)
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

      row.bar = row:CreateTexture(nil, "ARTWORK")
      row.bar:SetWidth(3)
      row.bar:SetPoint("TOPLEFT", 1, -1)
      row.bar:SetPoint("BOTTOMLEFT", 1, 1)

      row.eye = CreateFrame("Button", nil, row, "BackdropTemplate")
      row.eye:SetSize(20, 20)
      row.eye:SetPoint("LEFT", 7, 0)
      row.eye:SetBackdrop(FLAT_BACKDROP)
      row.eye.tex = row.eye:CreateTexture(nil, "ARTWORK")
      row.eye.tex:SetPoint("TOPLEFT", 1, -1)
      row.eye.tex:SetPoint("BOTTOMRIGHT", -1, 1)
      row.eye.tex:SetTexture("Interface\\AddOns\\ForeverSniper\\eye_monocle.tga")
      row.eye.tex:SetTexCoord(0, 1, 0, 1)
      row.eye:SetScript("OnEnter", function(self)
        local id = self.itemID
        local on = id and IsItemTracked(id)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if on then
          GameTooltip:AddLine("Гоблин следит за товаром (ВКЛ)", 0.06, 0.73, 0.51)
          GameTooltip:AddLine("Клик: исключить из кругового обхода", 0.80, 0.86, 0.94)
        else
          GameTooltip:AddLine("Товар пропущен (ВЫКЛ)", 0.65, 0.72, 0.82)
          GameTooltip:AddLine("Клик: включить гоблина-наблюдателя", 0.80, 0.86, 0.94)
        end
        GameTooltip:Show()
      end)
      row.eye:SetScript("OnLeave", function() GameTooltip:Hide() end)

      row.ico = row:CreateTexture(nil, "ARTWORK")
      row.ico:SetSize(18, 18)
      row.ico:SetPoint("LEFT", row.eye, "RIGHT", 6, 0)
      row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

      row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.name:SetPoint("LEFT", row.ico, "RIGHT", 6, 0)
      row.name:SetWidth(132)
      row.name:SetJustifyH("LEFT")
      row.name:SetWordWrap(false)

      row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.price:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
      row.price:SetWidth(84)
      row.price:SetJustifyH("LEFT")
      row.price:SetWordWrap(false)

      row.live = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.live:SetPoint("LEFT", row.price, "RIGHT", 4, 0)
      row.live:SetJustifyH("LEFT")
      row.live:SetWordWrap(false)

      row.cap = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.cap:SetPoint("RIGHT", -28, 0)
      row.cap:SetWidth(74)
      row.cap:SetJustifyH("RIGHT")
      row.cap:SetWordWrap(false)
      row.live:SetPoint("RIGHT", row.cap, "LEFT", -6, 0)

      row.eye:SetScript("OnClick", function(self)
        local id = self.itemID
        if not id then return end
        ForeverSniperDB.tracked = ForeverSniperDB.tracked or {}
        local nextState = not IsItemTracked(id)
        ForeverSniperDB.tracked[id] = nextState
        if not nextState and ForeverSniperDB.selectedID == id then
          ForeverSniperDB.selectedID = nil
        elseif nextState then
          ForeverSniperDB.selectedID = id
          if GetBaseQtyCap(id) > 0 and GetQtyCap(id) == 0 and ForeverSniperDB.boughtByItem then
            ForeverSniperDB.boughtByItem[id] = nil
          end
        end
        if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
        ClearPendingDeal()
        UpdateStatus()
        SyncInputsFromSelected()
      end)

      row.del = CreateFlatButton(nil, row, 20, 20, "x")
      row.del:SetPoint("RIGHT", -4, 0)
      row.del:SetColors({ 0.12, 0.15, 0.22, 1 }, { 0.55, 0.14, 0.18, 1 }, { 0.20, 0.26, 0.36, 1 }, { 0.75, 0.80, 0.88 })
      row.del:SetScript("OnClick", function(self)
        local id = self.itemID
        if not id then return end
        ForeverSniperDB.watchlist[id] = nil
        if ForeverSniperDB.qtyLimits then ForeverSniperDB.qtyLimits[id] = nil end
        if ForeverSniperDB.boughtByItem then ForeverSniperDB.boughtByItem[id] = nil end
        if ForeverSniperDB.tracked then ForeverSniperDB.tracked[id] = nil end
        if ForeverSniperDB.selectedID == id then
          ForeverSniperDB.selectedID = nil
        end
        if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
        ClearPendingDeal()
        UpdateStatus()
        SyncInputsFromSelected()
      end)

      row:SetScript("OnEnter", function(self)
        if not GameTooltip or not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
        if self.diffKind == "new" then
          GameTooltip:AddLine(" ")
          GameTooltip:AddLine("+ Новая позиция (нет в шаблоне «" .. (self.apName or "") .. "»)", 0.0, 0.82, 0.95, true)
          GameTooltip:AddLine("Нажмите «• Обновить» сверху для сохранения.", 0.65, 0.75, 0.85, true)
        elseif self.diffKind == "mod" then
          GameTooltip:AddLine(" ")
          GameTooltip:AddLine("* Отличается от шаблона «" .. (self.apName or "") .. "»:", 0.96, 0.70, 0.03, true)
          if self.diffOldPrice ~= self.curLim then
            GameTooltip:AddDoubleLine("Цена:", FormatCoinsPlain(self.diffOldPrice) .. " -> " .. FormatCoinsPlain(self.curLim), 0.85, 0.90, 0.96, 0.98, 0.92, 0.70)
          end
          if self.diffOldQty ~= self.curBaseCap then
            local oq = (self.diffOldQty and self.diffOldQty > 0) and tostring(self.diffOldQty) or "все"
            local cq = (self.curBaseCap and self.curBaseCap > 0) and tostring(self.curBaseCap) or "все"
            GameTooltip:AddDoubleLine("Кол-во:", oq .. " -> " .. cq, 0.85, 0.90, 0.96, 0.98, 0.92, 0.70)
          end
          GameTooltip:AddLine("Нажмите «• Обновить» сверху для сохранения.", 0.65, 0.75, 0.85, true)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("ЛКМ: выбрать цель  |  ПКМ / 2x клик: изменить цену и кол-во", 0.55, 0.65, 0.78)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row:SetScript("OnMouseUp", function(self, btn)
      if btn == "LeftButton" and self.roiItemID then
        selectedAnaItemID = self.roiItemID
        RenderLogFrame()
      end
    end)

      local function OpenRowEdit(self)
        local id = self.itemID
        if not id then return end
        isCfgNewMode = false
        ForeverSniperDB.selectedID = id
        SyncInputsFromSelected()
        setTargetBtn:SetLabel("Сохранить")
        ClearPendingDeal()
        SetCfgOpen(true)
        UpdateStatus()
        goldInput:SetFocus()
        if goldInput.HighlightText then goldInput:HighlightText() end
      end

      row:SetScript("OnClick", function(self, mouseBtn)
        local id = self.itemID
        if not id then return end
        if mouseBtn == "RightButton" then
          OpenRowEdit(self)
          return
        end
        isCfgNewMode = false
        ForeverSniperDB.selectedID = id
        SyncInputsFromSelected()
        setTargetBtn:SetLabel("Сохранить")
        ClearPendingDeal()
        UpdateStatus()
      end)

      row:SetScript("OnDoubleClick", OpenRowEdit)

      wlRows[i] = row
    end

    local icon, nm, r, g, b = GetItemVisuals(itemID)
    local isSel = (itemID == ForeverSniperDB.selectedID)
    local isTracked = IsItemTracked(itemID)
    local lim = ForeverSniperDB.watchlist[itemID] or 0
    local cap = GetQtyCap(itemID)

    row.dealRef = h
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetWidth(rowW)
    row.itemID = itemID
    row.eye.itemID = itemID
    row.del.itemID = itemID
    row.apName = ap
    row.diffKind = diffKind
    row.diffOldPrice = diffOldPrice
    row.diffOldQty = diffOldQty
    row.curLim = lim
    row.curBaseCap = baseCap
    if isTracked then
      row.eye:SetBackdropColor(0.04, 0.16, 0.14, 1)
      row.eye:SetBackdropBorderColor(0.06, 0.73, 0.51, 0.9)
      row.eye.tex:SetDesaturated(false)
      row.eye.tex:SetVertexColor(1, 1, 1, 1)
    else
      row.eye:SetBackdropColor(0.06, 0.08, 0.12, 0.85)
      row.eye:SetBackdropBorderColor(0.18, 0.24, 0.34, 0.6)
      row.eye.tex:SetDesaturated(true)
      row.eye.tex:SetVertexColor(0.45, 0.50, 0.60, 0.45)
    end
    row.ico:SetTexture(icon)
    row.ico:SetDesaturated(not isTracked)
    row.ico:SetAlpha(isTracked and 1 or 0.45)
    row.name:SetText(nm)
    row.name:SetTextColor(r, g, b)
    row.name:SetAlpha(isTracked and 1 or 0.5)
    local ap = ForeverSniperDB.activePreset
    local apData = ap and ForeverSniperDB.presets and ForeverSniperDB.presets[ap]
    local baseCap = GetBaseQtyCap(itemID)
    local remCap = GetQtyCap(itemID)
    local diffKind, diffOldPrice, diffOldQty = nil, nil, nil
    if apData and apData.watchlist then
      local prePrice = apData.watchlist[itemID]
      local preQty = (apData.qtyLimits and apData.qtyLimits[itemID]) or 0
      if not prePrice then
        diffKind = "new"
      elseif prePrice ~= lim or preQty ~= baseCap then
        diffKind = "mod"
        diffOldPrice = prePrice
        diffOldQty = preQty
      end
    end

    if diffKind == "new" then
      row.price:SetText(FormatCoins(lim) .. " |cff06b6d4+|r")
    elseif diffKind == "mod" then
      row.price:SetText(FormatCoins(lim) .. " |cfff59e0b*|r")
    else
      row.price:SetText(FormatCoins(lim))
    end
    row.price:SetAlpha(isTracked and 1 or 0.5)
    local seen = state.lastSeenByItem and state.lastSeenByItem[itemID]
    if seen then
      if (seen.availBelow or 0) > 0 and seen.lowestPrice then
        row.live:SetText(string.format("|cff10b981АХ:%s (x%d)|r", FormatCoinsPlain(seen.lowestPrice), seen.availBelow))
      elseif seen.lowestPrice then
        row.live:SetText(string.format("|cfff59e0bАХ:%s|r", FormatCoinsPlain(seen.lowestPrice)))
      else
        row.live:SetText("|cff64748bнет на АХ|r")
      end
    else
      row.live:SetText("|cff475569-|r")
    end
    if baseCap > 0 then
      if remCap == 0 then
        row.cap:SetText("|cff10b981выкуп.|r")
      elseif remCap < baseCap then
        row.cap:SetText(string.format("|cfff59e0b%d|r|cff64748b/%d|r", remCap, baseCap))
      else
        row.cap:SetText(string.format("|cfff59e0bост. %d|r", baseCap))
      end
    else
      row.cap:SetText("|cff64748bвсе|r")
    end

    if seen and (seen.availBelow or 0) > 0 then
      row:SetBackdropColor(0.03, 0.16, 0.12, 1)
      row:SetBackdropBorderColor(0.06, 0.73, 0.51, 0.85)
      row.bar:SetColorTexture(0.06, 0.73, 0.51, 1)
    elseif isSel then
      row:SetBackdropColor(0.11, 0.16, 0.26, 1)
      row:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.7)
      row.bar:SetColorTexture(0.92, 0.70, 0.03, 1)
    else
      row:SetBackdropColor(0.055, 0.078, 0.135, 1)
      row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.6)
      row.bar:SetColorTexture(0.14, 0.20, 0.30, 0)
    end

    row:Show()
    y = y + rowH + 4
  end

  wlContent:SetHeight(math.max(168, y))
  if wlScrollBar then
    if #(state.allItems or {}) <= 6 then
      wlScrollBar:Hide()
      wlScroll:SetPoint("BOTTOMRIGHT", -4, 4)
    else
      wlScrollBar:Show()
      wlScroll:SetPoint("BOTTOMRIGHT", -14, 4)
    end
  end
end

UpdateStatus = function()
  RebuildQueue()
  RefreshTrackBtn()

  if not state.ahOpen then
    statusText:SetText(DOT_AMBER .. " |cfff59e0bНет окна АХ|r")
    statusPill:SetBackdropBorderColor(0.96, 0.62, 0.04, 0.55)
  elseif state.throttled then
    statusText:SetText(DOT_AMBER .. " |cfff59e0bПауза АХ...|r")
    statusPill:SetBackdropBorderColor(0.96, 0.62, 0.04, 0.7)
  elseif state.pendingDeal and ForeverSniperDB.autoScan then
    statusText:SetText(DOT_GREEN .. " |cff10b981Лот найден|r")
    statusPill:SetBackdropBorderColor(0.06, 0.73, 0.51, 0.85)
  elseif ForeverSniperDB.autoScan then
    statusText:SetText(DOT_GREEN .. string.format(" |cff10b981Скан: %d|r", state.queryCount))
    statusPill:SetBackdropBorderColor(0.06, 0.73, 0.51, 0.7)
  else
    statusText:SetText(DOT_GRAY .. " |cff94a3b8Пауза|r")
    statusPill:SetBackdropBorderColor(0.18, 0.25, 0.36, 1)
  end

  if ForeverSniperDB.autoScan then
    scanBtn:SetLabel("Пауза")
    scanBtn:SetColors({ 0.14, 0.11, 0.05, 1 }, { 0.22, 0.17, 0.07, 1 }, { 0.92, 0.62, 0.04, 0.70 }, { 0.99, 0.88, 0.55 })
  else
    scanBtn:SetLabel("Старт скан")
    scanBtn:SetColors({ 0.08, 0.13, 0.21, 1 }, { 0.12, 0.19, 0.30, 1 }, { 0.06, 0.73, 0.51, 0.55 }, { 0.86, 0.96, 0.92 })
  end

  local sel = ForeverSniperDB.selectedID
  if not (isCfgOpen and isCfgNewMode) then
    if sel and ForeverSniperDB.watchlist[sel] then
      local icon, nm, r, g, b = GetItemVisuals(sel)
      itemIcon:SetTexture(icon)
      iconFrame:SetBackdropBorderColor(r, g, b, 0.9)
      targetNameText:SetText(nm)
      targetNameText:SetTextColor(r, g, b)
      targetSubText:SetText(string.format("|cff64748bID %d  |  Перетащите предмет из сумки на иконку|r", sel))
    else
      itemIcon:SetTexture(134400)
      iconFrame:SetBackdropBorderColor(0.25, 0.33, 0.45, 1)
      targetNameText:SetText("Нет выбранного предмета")
      targetNameText:SetTextColor(0.65, 0.72, 0.82)
      targetSubText:SetText("|cff64748bЗадайте ID и цену ниже или нажмите Импорт|r")
    end
  end

  SyncAdaptiveLayout()
  if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
  if ForeverSniperDB.activePreset and ForeverSniperDB.presets and ForeverSniperDB.presets[ForeverSniperDB.activePreset] then
    if ForeverSniperDB.presetDirty then
      presetPickerBtn:SetLabel(string.format("|cfff59e0bШаблон: %s *|r", ForeverSniperDB.activePreset))
      presetPickerBtn:SetColors({ 0.14, 0.11, 0.04, 1 }, { 0.22, 0.16, 0.06, 1 }, { 0.92, 0.70, 0.03, 0.85 }, { 0.99, 0.88, 0.45 })
      wlSaveBtn:Show()
    else
      presetPickerBtn:SetLabel(string.format("|cff10b981Шаблон: %s|r", ForeverSniperDB.activePreset))
      presetPickerBtn:SetColors({ 0.04, 0.14, 0.12, 1 }, { 0.06, 0.20, 0.17, 1 }, { 0.06, 0.73, 0.51, 0.7 }, { 0.85, 1, 0.94 })
      wlSaveBtn:Hide()
    end
  else
    ForeverSniperDB.presetDirty = false
    wlSaveBtn:Hide()
    presetPickerBtn:SetLabel("|cfff59e0bШаблон: не выбран|r")
    presetPickerBtn:SetColors({ 0.06, 0.09, 0.16, 1 }, { 0.10, 0.15, 0.25, 1 }, { 0.20, 0.28, 0.40, 0.85 }, { 0.96, 0.85, 0.45 })
  end
  presetPickerBtn:SetFlatEnabled(not ForeverSniperDB.autoScan)
  if ForeverSniperDB.autoScan and f.presetMenu and f.presetMenu:IsShown() then
    f.presetMenu:Hide()
  end
  if f.miniContextText then
    if sel and ForeverSniperDB.watchlist[sel] then
      local _, mnm = GetItemVisuals(sel)
      local qTotal = #(state.queue or {})
      f.miniContextText:SetText(string.format("|cff94a3b8Цель %d/%d:|r |cfff8fafc%s|r", state.idx or 1, math.max(1, qTotal), mnm))
    else
      f.miniContextText:SetText("|cff64748bНет активной цели — откройте полный режим|r")
    end
  end
  RenderWatchlist()

  if not state.pendingDeal then
    RefreshBuyButtonText()
  end
end

ClearPendingDeal = function(keepLowestMsg, allowServerCancel)
  local prev = state.pendingDeal
  if allowServerCancel and prev and prev.isCommodity and prev.stage == "confirm" then
    if C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
      pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
  end
  state.pendingDeal = nil
  if not keepLowestMsg then
    state.lastDisplayedDealItem = nil
  end
  skipBtn:SetFlatEnabled(false)
  dealStripe:SetColorTexture(0.25, 0.33, 0.45, 0.65)
  dealCard:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)
  dealBadge:SetText("|cff94a3b8ОЖИДАНИЕ|r")
  dealDelta:SetText("")
  dealQtyRight:SetText("")
  dealTotalRight:SetText("")
  if not keepLowestMsg then
    dealTitle:SetText(state.ahOpen
      and "|cffcbd5e1Ожидание лота ниже заданного лимита...|r"
      or "|cff94a3b8Откройте окно аукциона для начала сканирования|r")
    local hasBind = GetBindingKey and (GetBindingKey("FOREVERSNIPER_BUY") ~= nil)
    dealMeta:SetText(hasBind and "" or "|cff64748bСовет: назначьте колесо мыши в ESC -> Назначение клавиш -> Goblin Broker|r")
  end
  RefreshBuyButtonText()
end

local function SetPendingDeal(deal)
  local wasReady = state.pendingDeal and state.pendingDeal.stage == "ready"
  state.pendingDeal = deal
  local _, itemName, r, g, b = GetItemVisuals(deal.itemID)
  itemName = deal.name or itemName

  local cap = GetQtyCap(deal.itemID)

  local pct = 0
  if deal.maxPrice and deal.maxPrice > 0 and deal.unitPrice and deal.unitPrice <= deal.maxPrice then
    pct = math.floor(((deal.maxPrice - deal.unitPrice) / deal.maxPrice) * 100 + 0.5)
  end
  local extraReady = 0
  if state.lastSeenByItem then
    for id, s in pairs(state.lastSeenByItem) do
      if id ~= deal.itemID and IsItemTracked(id) and (s.availBelow or 0) > 0 then
        extraReady = extraReady + 1
      end
    end
  end
  local extraTxt = extraReady > 0 and string.format("  |cff10b981(+%d в плюсе)|r", extraReady) or ""
  if pct > 0 then
    dealDelta:SetText(string.format("|cff10b981-%d%% выгоднее лимита|r%s", pct, extraTxt))
  else
    dealDelta:SetText("|cffcbd5e1В пределах лимита|r" .. extraTxt)
  end

  local hex = string.format("%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
  dealTitle:SetText(string.format("|cff%s%s|r", hex, itemName))
  if cap > 0 and (deal.qty or 1) > cap then
    dealQtyRight:SetText(string.format("|cff10b981x %d|r |cff94a3b8/ %d шт.|r", cap, deal.qty or 1))
  else
    dealQtyRight:SetText(string.format("|cff10b981x %d шт.|r", deal.qty or 1))
  end
  skipBtn:SetFlatEnabled(true)
  RefreshBuyButtonText()

  if not wasReady then
    RecordTelemetryDip(deal.itemID, deal.unitPrice, itemName)
    PlayDealAlert()
  end
end

-- Fast buy flow (shared between mouse click and direct keybinding)
local function ExecuteBuyAction(mouseButton)
  local now = GetTime()
  if (now - (state.lastBuyExecAt or 0)) < 0.025 then return end
  state.lastBuyExecAt = now
  local deal = state.pendingDeal
  if not deal or not state.ahOpen then return end

  local function GetAffordableQty(d, desiredQty)
    local qty = math.max(1, desiredQty or 1)
    if not GetMoney then return qty end
    local myMoney = GetMoney() or 0
    local costFn = d.exactCostForQty
    local unitP = d.unitPrice or 0
    local fullCost = costFn and costFn(qty) or (unitP * qty)
    if fullCost <= myMoney then return qty end
    local oneCost = costFn and costFn(1) or unitP
    if oneCost > myMoney then return 0 end
    local lo, hi, best = 1, qty, 1
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local c = costFn and costFn(mid) or (unitP * mid)
      if c <= myMoney then
        best = mid
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    return best
  end

  if mouseButton == "RightButton" then
    ClearPendingDeal(false, true)
    return
  end

  local cap = GetQtyCap(deal.itemID)
  local effectiveMax = (cap > 0) and math.min(deal.qty or 1, cap) or (deal.qty or 1)
  local chosenQty = math.max(1, effectiveMax)

  if not deal.isCommodity then
    if GetMoney and (GetMoney() or 0) < (deal.unitPrice or 0) then
      dealBadge:SetText("|cfff43f5eНЕДОСТАТОЧНО ЗОЛОТА!|r")
      return
    end
    -- Execute PlaceBid FIRST for minimum latency, then record UI/receipt
    C_AuctionHouse.PlaceBid(deal.auctionID, deal.unitPrice)
    state.pauseScanUntil = GetTime() + 0.6
    local _, nm = GetItemVisuals(deal.itemID)
    local att = {
      itemID = deal.itemID,
      name = deal.name or nm,
      qty = 1,
      totalCost = deal.unitPrice,
      maxPrice = deal.maxPrice,
      at = GetTime(),
      timeStr = date and date("%H:%M:%S") or "",
    }
    RecordCompletedPurchase(att)
    ClearPendingDeal()
    return
  end

  if deal.stage == "ready" then
    chosenQty = GetAffordableQty(deal, chosenQty)
    if chosenQty < 1 then
      dealBadge:SetText("|cfff43f5eНЕДОСТАТОЧНО ЗОЛОТА!|r")
      return
    end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
      dealBadge:SetText("|cfff59e0bСЛОТ АХ ЗАНЯТ — НАЖМИТЕ ЕЩЁ РАЗ|r")
      return
    end
    C_AuctionHouse.StartCommoditiesPurchase(deal.itemID, chosenQty)
    state.pauseScanUntil = GetTime() + 1.5
    deal.maxAvailQty = deal.maxAvailQty or deal.qty
    deal.qty = chosenQty
    deal.stage = "confirm"
    deal.quoteReady = false
    deal.confirmAt = GetTime()
    RefreshBuyButtonText()
    return
  end

  if deal.stage == "confirm" then
    -- Wait for server COMMODITY_PRICE_UPDATED quote (~50ms), with 0.60s lag fallback
    if not deal.quoteReady and (GetTime() - (deal.confirmAt or 0)) < 0.60 then
      if not deal.waitBadgeShown then
        deal.waitBadgeShown = true
        dealBadge:SetText(DOT_AMBER .. " |cfff59e0bЖДЁМ ОТВЕТ СЕРВЕРА...|r")
      end
      return
    end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
      if not deal.throttleBadgeShown then
        deal.throttleBadgeShown = true
        dealBadge:SetText("|cfff59e0bСЛОТ АХ ЗАНЯТ — ЖМЁМ...|r")
      end
      return
    end
    local totalCost = deal.exactCostForQty and deal.exactCostForQty(chosenQty) or ((deal.unitPrice or 0) * chosenQty)
    local _, nm = GetItemVisuals(deal.itemID)
    state.lastPurchaseAttempt = {
      itemID = deal.itemID,
      name = deal.name or nm,
      qty = chosenQty,
      totalCost = totalCost,
      maxPrice = deal.maxPrice,
      at = GetTime(),
      timeStr = date and date("%H:%M:%S") or "",
    }
    C_AuctionHouse.ConfirmCommoditiesPurchase(deal.itemID, chosenQty)
    state.pauseScanUntil = GetTime() + 0.6
    ClearPendingDeal(false, false)
  end
end

function ForeverSniper_OnBuyHotkey()
  ExecuteBuyAction("LeftButton")
end

buyBtn:SetScript("OnClick", function(_, mouseButton)
  ExecuteBuyAction(mouseButton)
end)

skipBtn:SetScript("OnClick", function()
  ClearPendingDeal(false, true)
end)

local function ApplyManualTarget()
  local id = tonumber(idInput:GetText() or "")
  local g = tonumber(goldInput:GetText() or "") or 0
  local s = tonumber(silverInput:GetText() or "") or 0
  local c = tonumber(copperInput:GetText() or "") or 0
  local maxQ = tonumber(maxQtyLimitInput:GetText() or "") or 0
  local copper = math.floor(g * 10000 + s * 100 + c)
  if not id or id <= 0 or copper <= 0 then
    return false
  end
  ForeverSniperDB.watchlist[id] = copper
  ForeverSniperDB.qtyLimits = ForeverSniperDB.qtyLimits or {}
  ForeverSniperDB.qtyLimits[id] = (maxQ > 0) and math.floor(maxQ) or nil
  if ForeverSniperDB.boughtByItem then ForeverSniperDB.boughtByItem[id] = nil end
  ForeverSniperDB.selectedID = id
  if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
  idInput:ClearFocus()
  goldInput:ClearFocus()
  silverInput:ClearFocus()
  copperInput:ClearFocus()
  maxQtyLimitInput:ClearFocus()
  isCfgNewMode = false
  ClearPendingDeal()
  if SetCfgOpen then SetCfgOpen(false) end
  UpdateStatus()
  ResetManualInputs()
  return true
end

local inputOrder = { idInput, goldInput, silverInput, copperInput, maxQtyLimitInput }
for idx, box in ipairs(inputOrder) do
  box:SetScript("OnEnterPressed", function()
    ApplyManualTarget()
  end)
  box:SetScript("OnTabPressed", function()
    local nxt = inputOrder[(idx % #inputOrder) + 1]
    nxt:SetFocus()
    if nxt.HighlightText then nxt:HighlightText() end
  end)
end

local lastIdFocusAt = 0
idInput:HookScript("OnEditFocusGained", function()
  lastIdFocusAt = GetTime()
end)
idInput:HookScript("OnEditFocusLost", function()
  lastIdFocusAt = GetTime()
end)

local function TryInsertItemLink(link)
  if f._tryBaitInsert and f._tryBaitInsert(link) then
    return
  end
  if (idInput:HasFocus() or (GetTime() - lastIdFocusAt) < 0.25) and type(link) == "string" then
    local itemID = link:match("item:(%d+)")
    if itemID then
      ApplyPreviewItemID(itemID)
    end
  end
end

if hooksecurefunc then
  if ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", TryInsertItemLink)
  end
  if HandleModifiedItemClick then
    hooksecurefunc("HandleModifiedItemClick", TryInsertItemLink)
  end
end

setTargetBtn:SetScript("OnClick", function()
  if not ApplyManualTarget() then
    print("|cfff59e0bGoblin Broker:|r укажите корректный ID и цену (з / с / м).")
  end
end)

local function SendTargetQuery()
  local rotated = false
  if #state.queue > 1 and not state.pendingDeal then
    state.idx = (state.idx % #state.queue) + 1
    ForeverSniperDB.selectedID = state.queue[state.idx]
    rotated = true
  end
  local targetID = ForeverSniperDB.selectedID
  if not targetID or not state.ahOpen then return end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    if not state.throttled then
      state.throttled = true
      statusText:SetText(DOT_AMBER .. " |cfff59e0bПауза АХ...|r")
      statusPill:SetBackdropBorderColor(0.96, 0.62, 0.04, 0.7)
    end
    return
  end

  -- Send AH network query FIRST for minimum latency, then update UI
  local itemKey = GetCachedItemKey(targetID)
  C_AuctionHouse.SendSearchQuery(itemKey, PRICE_SORTS, false)

  state.throttled = false
  state.lastQueryAt = GetTime()
  state.queryCount = state.queryCount + 1
  state.cleanQueryStreak = (state.cleanQueryStreak or 0) + 1
  if state.cleanQueryStreak >= 3 and (state.queryInterval or 0.25) > 0.25 then
    state.cleanQueryStreak = 0
    state.queryInterval = math.max(0.25, state.queryInterval - 0.05)
  end
  statusText:SetText(DOT_GREEN .. string.format(" |cff10b981Скан: %d|r", state.queryCount))
  statusPill:SetBackdropBorderColor(0.06, 0.73, 0.51, 0.7)
  if rotated then
    local _, nm, r, g, b = GetItemVisuals(targetID)
    if ForeverSniperDB.miniMode then
      if f.miniContextText then
        f.miniContextText:SetText(string.format("|cff94a3b8Цель %d/%d:|r |cfff8fafc%s|r", state.idx or 1, math.max(1, #(state.queue or {})), nm))
      end
    else
      local icon = GetItemVisuals(targetID)
      itemIcon:SetTexture(icon)
      iconFrame:SetBackdropBorderColor(r, g, b, 0.9)
      targetNameText:SetText(nm)
      targetNameText:SetTextColor(r, g, b)
      targetSubText:SetText(string.format("|cff64748bID %d  |  Перетащите предмет из сумки на иконку|r", targetID))
    end
  end
end

local function ToggleScan()
  if not ForeverSniperDB.autoScan then
    -- Always apply current setup inputs (ID, price, max qty) before starting scan
    if not ApplyManualTarget() and not ForeverSniperDB.selectedID then
      print("|cfff59e0bGoblin Broker:|r сначала укажите ID предмета и макс. цену.")
      return
    end
  end
  ForeverSniperDB.autoScan = not ForeverSniperDB.autoScan
  UpdateStatus()
  if ForeverSniperDB.autoScan then
    state.lastQueryAt = 0
    SendTargetQuery()
  end
end

function ForeverSniper_OnScanHotkey()
  ToggleScan()
end

scanBtn:SetScript("OnClick", ToggleScan)

-- ============================================================================
-- Import Modal (Matching Goblin Broker Brand)
-- ============================================================================
local imp = CreateFrame("Frame", "ForeverSniperImportFrame", UIParent, "BackdropTemplate")
imp:SetSize(460, 250)
imp:SetPoint("CENTER")
imp:SetBackdrop(FLAT_BACKDROP)
imp:SetBackdropColor(0.043, 0.067, 0.125, 0.98)
imp:SetBackdropBorderColor(0.22, 0.28, 0.40, 1)
imp:SetFrameStrata("FULLSCREEN_DIALOG")
imp:EnableMouse(true)
imp:SetMovable(true)
imp:RegisterForDrag("LeftButton")
imp:SetScript("OnDragStart", imp.StartMoving)
imp:SetScript("OnDragStop", imp.StopMovingOrSizing)
AttachDropShadow(imp, 14, 0.80)
imp:Hide()

local impAccent = imp:CreateTexture(nil, "ARTWORK")
impAccent:SetHeight(2)
impAccent:SetPoint("TOPLEFT", 1, -1)
impAccent:SetPoint("TOPRIGHT", -1, -1)
impAccent:SetColorTexture(1, 1, 1, 1)
impAccent:SetGradient("HORIZONTAL", CreateColor(0.92, 0.70, 0.03, 1), CreateColor(0.06, 0.73, 0.51, 1))

local impTitle = imp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
impTitle:SetPoint("TOPLEFT", 16, -14)
impTitle:SetText("|cfff59e0bИмпорт из Goblin Broker: Forever|r")

local impBoxBg = CreateFrame("Frame", nil, imp, "BackdropTemplate")
impBoxBg:SetPoint("TOPLEFT", 16, -38)
impBoxBg:SetPoint("BOTTOMRIGHT", -16, 48)
impBoxBg:SetBackdrop(FLAT_BACKDROP)
impBoxBg:SetBackdropColor(0.025, 0.038, 0.070, 1)
impBoxBg:SetBackdropBorderColor(0.18, 0.24, 0.35, 1)

local scroll = CreateFrame("ScrollFrame", nil, impBoxBg, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 8, -8)
scroll:SetPoint("BOTTOMRIGHT", -28, 8)

local editBox = CreateFrame("EditBox", nil, scroll)
editBox:SetMultiLine(true)
editBox:SetFontObject("GameFontHighlightSmall")
editBox:SetWidth(392)
editBox:SetAutoFocus(true)
editBox:SetScript("OnEscapePressed", function() imp:Hide() end)
scroll:SetScrollChild(editBox)

local impReplace = CreateFlatButton(nil, imp, 132, 28, "Заменить всё")
impReplace:SetPoint("BOTTOMLEFT", 16, 12)
impReplace:SetColors({ 0.45, 0.32, 0.02, 1 }, { 0.62, 0.44, 0.03, 1 }, { 0.92, 0.70, 0.03, 0.9 }, { 1, 0.96, 0.85 })

local impAdd = CreateFlatButton(nil, imp, 132, 28, "Добавить")
impAdd:SetPoint("LEFT", impReplace, "RIGHT", 8, 0)
impAdd:SetColors({ 0.02, 0.48, 0.34, 1 }, { 0.04, 0.62, 0.44, 1 }, { 0.06, 0.73, 0.51, 0.9 }, { 1, 1, 1 })

local impCancel = CreateFlatButton(nil, imp, 96, 28, "Отмена")
impCancel:SetPoint("LEFT", impAdd, "RIGHT", 8, 0)

local function RunImport(replaceAll)
  local text = editBox:GetText() or ""
  local added = 0
  local nextList = replaceAll and {} or (ForeverSniperDB.watchlist or {})
  local firstID = nil
  ForeverSniperDB.qtyLimits = ForeverSniperDB.qtyLimits or {}
  local nextQty = replaceAll and {} or ForeverSniperDB.qtyLimits
  for idStr, priceStr, qtyStr in string.gmatch(text, "(%d+)=(%d+):?(%d*)") do
    local id = tonumber(idStr)
    local p = tonumber(priceStr)
    local q = tonumber(qtyStr)
    if id and p and p > 0 then
      nextList[id] = p
      if q and q > 0 then
        nextQty[id] = q
      end
      if not firstID then firstID = id end
      added = added + 1
    end
  end
  ForeverSniperDB.qtyLimits = nextQty
  ForeverSniperDB.watchlist = nextList
  if replaceAll then
    ForeverSniperDB.selectedID = firstID
    ForeverSniperDB.activePreset = nil
    ForeverSniperDB.boughtByItem = {}
  elseif not ForeverSniperDB.selectedID then
    ForeverSniperDB.selectedID = firstID
  end
  if not replaceAll and SyncActivePresetSnapshot then
    SyncActivePresetSnapshot()
  end
  imp:Hide()
  ClearPendingDeal()
  UpdateStatus()
  SyncInputsFromSelected()
  print(string.format("|cfff59e0bGoblin Broker:|r импортировано %d позиций.", added))
end

local function OpenImportModal()
  impTitle:SetText("|cfff59e0bИмпорт из Goblin Broker: Forever|r")
  impReplace:Show()
  impAdd:Show()
  impCancel:ClearAllPoints()
  impCancel:SetPoint("LEFT", impAdd, "RIGHT", 8, 0)
  impCancel:SetLabel("Отмена")
  editBox:SetText("")
  imp:Show()
  editBox:SetFocus()
end

OpenExportModal = function(titleText, bodyText)
  impTitle:SetText("|cff06b6d4" .. (titleText or "Экспорт (Ctrl+C)") .. "|r")
  impReplace:Hide()
  impAdd:Hide()
  impCancel:ClearAllPoints()
  impCancel:SetPoint("BOTTOMRIGHT", -16, 12)
  impCancel:SetLabel("Закрыть")
  editBox:SetText(bodyText or "")
  editBox:HighlightText()
  imp:Show()
  editBox:SetFocus()
end

impCancel:SetScript("OnClick", function() imp:Hide() end)
impReplace:SetScript("OnClick", function() RunImport(true) end)
impAdd:SetScript("OnClick", function() RunImport(false) end)

importBtn:SetScript("OnClick", OpenImportModal)

-- ============================================================================
-- Bait Posting ("На живца"): Post 1 unit at minimum duration (2h/12h)
-- ============================================================================
do
local function EnsureBaitsDB()
  ForeverSniperDB.baits = ForeverSniperDB.baits or {}
  return ForeverSniperDB.baits
end
local baitModal, RenderBaitList
local BAIT_QTY = 1
local BAIT_DURATION = 1 -- Shortest AH duration tier (1 = min tier: 2h/12h)

local function FindBagItemLocation(itemID)
  if not itemID then return nil, 0 end
  local getNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  local getItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
  local getInfo = C_Container and C_Container.GetContainerItemInfo
  if not getNumSlots then return nil, 0 end

  local totalCount = 0
  local firstLoc = nil
  local maxBag = (NUM_BAG_SLOTS or 4) + 2
  for bag = 0, maxBag do
    local slots = getNumSlots(bag) or 0
    for slot = 1, slots do
      local slotItemID, count, isBound = nil, 1, false
      if getInfo then
        local info = getInfo(bag, slot)
        if info then
          slotItemID = info.itemID
          count = info.stackCount or 1
          isBound = not not info.isBound
        end
      end
      if not slotItemID and getItemID then
        slotItemID = getItemID(bag, slot)
        if slotItemID and GetContainerItemInfo then
          local _, c = GetContainerItemInfo(bag, slot)
          if c then count = c end
        end
      end
      if slotItemID == itemID then
        local loc = ItemLocation and ItemLocation.CreateFromBagAndSlot and ItemLocation:CreateFromBagAndSlot(bag, slot)
        if (not isBound) and loc and C_Item and C_Item.IsBound then
          local okB, bRes = pcall(C_Item.IsBound, loc)
          if okB and bRes then isBound = true end
        end
        if not isBound then
          totalCount = totalCount + (count or 1)
          if not firstLoc and loc then
            firstLoc = loc
          end
        end
      end
    end
  end
  return firstLoc, totalCount
end

local function IsBaitCommodity(itemID)
  if C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.MakeItemKey then
    local info = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(itemID))
    if info and info.isCommodity ~= nil then
      return info.isCommodity
    end
  end
  if GetItemInfo then
    local _, _, _, _, _, _, _, maxStack = GetItemInfo(itemID)
    if maxStack then
      return maxStack > 1
    end
  end
  return true
end

local baitModalFrame = CreateFrame("Frame", "ForeverSniperBaitFrame", UIParent, "BackdropTemplate")
baitModal = baitModalFrame
baitModal:SetSize(560, 440)
baitModal:SetPoint("CENTER")
baitModal:SetFrameStrata("DIALOG")
baitModal:SetMovable(true)
baitModal:EnableMouse(true)
baitModal:RegisterForDrag("LeftButton")
baitModal:SetScript("OnDragStart", baitModal.StartMoving)
baitModal:SetScript("OnDragStop", baitModal.StopMovingOrSizing)
baitModal:SetBackdrop(FLAT_BACKDROP)
baitModal:SetBackdropColor(0.043, 0.059, 0.098, 0.98)
baitModal:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.75)
AttachDropShadow(baitModal, 10, 0.6)
baitModal:Hide()

local baitTitle = baitModal:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
baitTitle:SetPoint("TOPLEFT", 16, -14)
baitTitle:SetText("|cfff59e0bНа живца|r |cff94a3b8(1 шт)|r")

local baitCloseBtn = CreateFlatButton(nil, baitModal, 24, 22, "X")
baitCloseBtn:SetPoint("TOPRIGHT", -12, -12)
baitCloseBtn:SetColors({ 0.12, 0.16, 0.24, 1 }, { 0.25, 0.14, 0.18, 1 }, { 0.30, 0.36, 0.48, 0.8 }, { 0.85, 0.90, 0.96 })
baitCloseBtn:SetScript("OnClick", function() baitModal:Hide() end)

local baitHotkeyBtn = CreateFlatButton(nil, baitModal, 144, 22, "Хоткей: нет")
baitHotkeyBtn:SetPoint("RIGHT", baitCloseBtn, "LEFT", -6, 0)
baitHotkeyBtn:SetColors({ 0.08, 0.12, 0.20, 1 }, { 0.14, 0.20, 0.32, 1 }, { 0.92, 0.70, 0.03, 0.75 }, { 0.98, 0.94, 0.54 })
baitHotkeyBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

local baitSkip1Btn = CreateFlatButton(nil, baitModal, 134, 22, "Пропуск 1шт: ВЫКЛ")
baitSkip1Btn:SetPoint("RIGHT", baitHotkeyBtn, "LEFT", -6, 0)
local function RefreshBaitSkip1Btn()
  if ForeverSniperDB.skipSingleBait then
    baitSkip1Btn:SetLabel("Пропуск 1шт: |cff10b981ВКЛ|r")
    baitSkip1Btn:SetColors({ 0.04, 0.16, 0.14, 1 }, { 0.06, 0.24, 0.20, 1 }, { 0.06, 0.73, 0.51, 0.85 }, { 0.85, 1, 0.94 })
  else
    baitSkip1Btn:SetLabel("Пропуск 1шт: |cff64748bВЫКЛ|r")
    baitSkip1Btn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.13, 0.17, 0.25, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.65, 0.72, 0.82 })
  end
  if f._refreshRailSkip1Btn then f._refreshRailSkip1Btn() end
end
baitSkip1Btn:SetScript("OnClick", function()
  ForeverSniperDB.skipSingleBait = not ForeverSniperDB.skipSingleBait
  RefreshBaitSkip1Btn()
end)
baitSkip1Btn:HookScript("OnEnter", function(self)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Пропуск лотов по 1 шт (снайпер)", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Когда ВКЛ — снайпер игнорирует стакаемые лоты по 1 шт, чтобы не клевать на свою/чужую наживку и ловить реальные пачки (2+ шт).", 0.85, 0.90, 0.96, true)
  GameTooltip:Show()
end)
baitSkip1Btn:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
f._refreshSkip1Btn = RefreshBaitSkip1Btn

local baitCapturingKey = false
local function RefreshBaitHotkeyBtn()
  if baitCapturingKey then
    baitHotkeyBtn:SetLabel("|cfffef08aНажмите клавишу...|r")
    baitHotkeyBtn:SetColors({ 0.45, 0.32, 0.02, 1 }, { 0.55, 0.38, 0.03, 1 }, { 0.96, 0.78, 0.12, 0.95 }, { 1, 0.98, 0.85 })
    return
  end
  local k = GetBindingKey and GetBindingKey("FOREVERSNIPER_BAIT")
  if k and k ~= "" then
    baitHotkeyBtn:SetLabel("Хоткей: |cfffef08a" .. k .. "|r")
  else
    baitHotkeyBtn:SetLabel("Хоткей: |cff64748bне задан|r")
  end
  baitHotkeyBtn:SetColors({ 0.08, 0.12, 0.20, 1 }, { 0.14, 0.20, 0.32, 1 }, { 0.92, 0.70, 0.03, 0.75 }, { 0.98, 0.94, 0.54 })
end

local function StopBaitKeyCapture()
  baitCapturingKey = false
  baitHotkeyBtn:EnableKeyboard(false)
  baitHotkeyBtn:EnableMouseWheel(false)
  RefreshBaitHotkeyBtn()
end

local function ApplyBaitBindingCombo(combo)
  if InCombatLockdown and InCombatLockdown() then
    print("|cfff43f5eGoblin Broker:|r нельзя менять клавиши в бою.")
    StopBaitKeyCapture()
    return
  end
  if GetBindingKey and SetBinding then
    local old1, old2 = GetBindingKey("FOREVERSNIPER_BAIT")
    if old1 then SetBinding(old1, nil) end
    if old2 then SetBinding(old2, nil) end
    if combo and combo ~= "" then
      SetBinding(combo, "FOREVERSNIPER_BAIT")
    end
    if SaveBindings and GetCurrentBindingSet then
      pcall(SaveBindings, GetCurrentBindingSet())
    end
  end
  StopBaitKeyCapture()
end

baitHotkeyBtn:SetScript("OnClick", function(self, btn)
  if btn == "RightButton" then
    ApplyBaitBindingCombo(nil)
    print("|cfff59e0bGoblin Broker [На живца]:|r хоткей сброшен.")
    return
  end
  if baitCapturingKey then
    StopBaitKeyCapture()
    return
  end
  baitCapturingKey = true
  self:EnableKeyboard(true)
  self:EnableMouseWheel(true)
  RefreshBaitHotkeyBtn()
end)

baitHotkeyBtn:SetScript("OnKeyDown", function(_, key)
  if not baitCapturingKey then return end
  if key == "ESCAPE" then
    StopBaitKeyCapture()
    return
  end
  if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL" or key == "LALT" or key == "RALT" then
    return
  end
  local prefix = ((IsShiftKeyDown and IsShiftKeyDown()) and "SHIFT-" or "")
    .. ((IsControlKeyDown and IsControlKeyDown()) and "CTRL-" or "")
    .. ((IsAltKeyDown and IsAltKeyDown()) and "ALT-" or "")
  ApplyBaitBindingCombo(prefix .. key)
end)

baitHotkeyBtn:SetScript("OnMouseWheel", function(_, delta)
  if not baitCapturingKey then return end
  local prefix = ((IsShiftKeyDown and IsShiftKeyDown()) and "SHIFT-" or "")
    .. ((IsControlKeyDown and IsControlKeyDown()) and "CTRL-" or "")
    .. ((IsAltKeyDown and IsAltKeyDown()) and "ALT-" or "")
  ApplyBaitBindingCombo(prefix .. (delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN"))
end)

baitHotkeyBtn:HookScript("OnEnter", function(self)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Хоткей «На живца»", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("ЛКМ: назначить клавишу или колесо мыши", 0.85, 0.90, 0.96)
  GameTooltip:AddLine("ПКМ: сбросить клавишу", 0.65, 0.75, 0.85)
  GameTooltip:AddLine("Выставляет 1 шт выбранной (★) наживки без открытия этого окна.", 0.60, 0.72, 0.84, true)
  GameTooltip:Show()
end)
baitHotkeyBtn:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
baitModal:HookScript("OnHide", function()
  if baitCapturingKey then StopBaitKeyCapture() end
end)
baitModal.RefreshHotkey = RefreshBaitHotkeyBtn

local baitHint = baitModal:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitHint:SetPoint("TOPLEFT", 16, -38)
baitHint:SetPoint("TOPRIGHT", -16, -38)
baitHint:SetJustifyH("LEFT")
baitHint:SetText("|cff94a3b8Перетащите предмет из сумки или введите ID и цену. Клик «Выставить 1 шт» ставит ровно 1 шт на минимальный срок.|r")

-- Add / Edit Card inside baitModal
local baitEditCard = CreateFrame("Frame", nil, baitModal, "BackdropTemplate")
baitEditCard:SetPoint("TOPLEFT", 14, -64)
baitEditCard:SetPoint("TOPRIGHT", -14, -64)
baitEditCard:SetHeight(86)
baitEditCard:SetBackdrop(FLAT_BACKDROP)
baitEditCard:SetBackdropColor(0.067, 0.094, 0.153, 1)
baitEditCard:SetBackdropBorderColor(0.16, 0.23, 0.35, 1)

local baitIconFrame = CreateFrame("Button", nil, baitEditCard, "BackdropTemplate")
baitIconFrame:SetSize(36, 36)
baitIconFrame:SetPoint("TOPLEFT", 10, -10)
baitIconFrame:SetBackdrop(FLAT_BACKDROP)
baitIconFrame:SetBackdropColor(0.03, 0.04, 0.08, 1)
baitIconFrame:SetBackdropBorderColor(0.25, 0.35, 0.50, 1)

local baitIconTex = baitIconFrame:CreateTexture(nil, "ARTWORK")
baitIconTex:SetPoint("TOPLEFT", 2, -2)
baitIconTex:SetPoint("BOTTOMRIGHT", -2, 2)
baitIconTex:SetTexture("Interface\\Icons\\INV_Misc_Fish_02")
baitIconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local baitNameText = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
baitNameText:SetPoint("TOPLEFT", baitIconFrame, "TOPRIGHT", 10, -1)
baitNameText:SetPoint("RIGHT", -12, 0)
baitNameText:SetJustifyH("LEFT")
baitNameText:SetText("|cff94a3b8Выберите предмет для наживки|r")

local baitSubText = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitSubText:SetPoint("TOPLEFT", baitNameText, "BOTTOMLEFT", 0, -3)
baitSubText:SetPoint("RIGHT", -12, 0)
baitSubText:SetJustifyH("LEFT")
baitSubText:SetText("|cff64748bПеретащите из сумки на иконку, Shift+клик или введите ID|r")

local baitIdLabel = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitIdLabel:SetPoint("BOTTOMLEFT", 10, 12)
baitIdLabel:SetText("|cff94a3b8ID:|r")

local baitIdInput = CreateFrame("EditBox", nil, baitEditCard, "BackdropTemplate")
StyleFlatBox(baitIdInput, 76, 22)
baitIdInput:SetPoint("LEFT", baitIdLabel, "RIGHT", 6, 0)
baitIdInput:SetNumeric(true)
baitIdInput:SetJustifyH("CENTER")

local baitLastIdFocusAt = 0
baitIdInput:HookScript("OnEditFocusGained", function() baitLastIdFocusAt = GetTime() end)
baitIdInput:HookScript("OnEditFocusLost", function() baitLastIdFocusAt = GetTime() end)

local baitPriceLabel = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitPriceLabel:SetPoint("LEFT", baitIdInput, "RIGHT", 12, 0)
baitPriceLabel:SetText("|cff94a3b8Цена:|r")

local baitGoldInput = CreateFrame("EditBox", nil, baitEditCard, "BackdropTemplate")
StyleFlatBox(baitGoldInput, 54, 22)
baitGoldInput:SetPoint("LEFT", baitPriceLabel, "RIGHT", 6, 0)
baitGoldInput:SetNumeric(true)
baitGoldInput:SetJustifyH("RIGHT")

local baitGUnit = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitGUnit:SetPoint("LEFT", baitGoldInput, "RIGHT", 3, 0)
baitGUnit:SetText("|cffffd700з|r")

local baitSilverInput = CreateFrame("EditBox", nil, baitEditCard, "BackdropTemplate")
StyleFlatBox(baitSilverInput, 36, 22)
baitSilverInput:SetPoint("LEFT", baitGUnit, "RIGHT", 6, 0)
baitSilverInput:SetNumeric(true)
baitSilverInput:SetMaxLetters(2)
baitSilverInput:SetJustifyH("RIGHT")

local baitSUnit = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitSUnit:SetPoint("LEFT", baitSilverInput, "RIGHT", 3, 0)
baitSUnit:SetText("|cffc7c7cfс|r")

local baitCopperInput = CreateFrame("EditBox", nil, baitEditCard, "BackdropTemplate")
StyleFlatBox(baitCopperInput, 36, 22)
baitCopperInput:SetPoint("LEFT", baitSUnit, "RIGHT", 6, 0)
baitCopperInput:SetNumeric(true)
baitCopperInput:SetMaxLetters(2)
baitCopperInput:SetJustifyH("RIGHT")

local baitCUnit = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitCUnit:SetPoint("LEFT", baitCopperInput, "RIGHT", 3, 0)
baitCUnit:SetText("|cffeda55fм|r")

local baitSaveBtn = CreateFlatButton(nil, baitEditCard, 98, 22, "Сохранить")
baitSaveBtn:SetPoint("RIGHT", -10, 0)
baitSaveBtn:SetPoint("CENTER", baitCopperInput, "CENTER", 0, 0)
baitSaveBtn:ClearAllPoints()
baitSaveBtn:SetPoint("RIGHT", baitEditCard, "RIGHT", -10, 0)
baitSaveBtn:SetPoint("TOP", baitIdInput, "TOP", 0, 0)
baitSaveBtn:SetColors({ 0.45, 0.32, 0.02, 1 }, { 0.62, 0.44, 0.03, 1 }, { 0.92, 0.70, 0.03, 0.9 }, { 1, 0.96, 0.85 })

local function ApplyBaitPreviewItemID(itemID, presetCopper)
  local id = tonumber(itemID)
  if not id or id <= 0 then return false end
  baitIdInput:SetText(tostring(id))
  local icon, nm, r, g, b = GetItemVisuals(id)
  baitIconTex:SetTexture(icon)
  baitIconFrame:SetBackdropBorderColor(r, g, b, 0.9)
  baitNameText:SetText(nm)
  baitNameText:SetTextColor(r, g, b)
  local _, bagCount = FindBagItemLocation(id)
  baitSubText:SetText(string.format("|cff64748bID %d  |  В сумках: |r%s%d шт|r", id, bagCount > 0 and "|cff10b981" or "|cfff43f5e", bagCount))
  local existing = presetCopper or EnsureBaitsDB()[id]
  if existing and existing > 0 then
    local gVal = math.floor(existing / 10000)
    local sVal = math.floor((existing % 10000) / 100)
    local cVal = existing % 100
    baitGoldInput:SetText(gVal > 0 and tostring(gVal) or "")
    baitSilverInput:SetText(sVal > 0 and tostring(sVal) or "")
    baitCopperInput:SetText(cVal > 0 and tostring(cVal) or "")
  else
    baitGoldInput:SetText("")
    baitSilverInput:SetText("")
    baitCopperInput:SetText("")
  end
  baitGoldInput:SetFocus()
  return true
end

local function PreviewBaitDraggedItem()
  if not GetCursorInfo then return false end
  local kind, itemID = GetCursorInfo()
  if kind == "item" and itemID then
    ClearCursor()
    return ApplyBaitPreviewItemID(itemID)
  end
  return false
end

baitIconFrame:SetScript("OnReceiveDrag", PreviewBaitDraggedItem)
baitIconFrame:SetScript("OnClick", PreviewBaitDraggedItem)
baitIconFrame:SetScript("OnEnter", function(self)
  local sel = tonumber(baitIdInput:GetText())
  if GameTooltip then
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if sel and sel > 0 then
      GameTooltip:SetItemByID(sel)
      GameTooltip:AddLine(" ")
    end
    GameTooltip:AddLine("Перетащите предмет из сумки для автозаполнения", 0.58, 0.75, 0.90)
    GameTooltip:Show()
  end
end)
baitIconFrame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

f._tryBaitInsert = function(link)
  if not baitModal:IsShown() then return false end
  if (baitIdInput:HasFocus() or (GetTime() - baitLastIdFocusAt) < 0.25) and type(link) == "string" then
    local itemID = link:match("item:(%d+)")
    if itemID then
      ApplyBaitPreviewItemID(itemID)
      return true
    end
  end
  return false
end

-- List Container inside baitModal
local baitListBox = CreateFrame("Frame", nil, baitModal, "BackdropTemplate")
baitListBox:SetPoint("TOPLEFT", baitEditCard, "BOTTOMLEFT", 0, -10)
baitListBox:SetPoint("BOTTOMRIGHT", -14, 14)
baitListBox:SetBackdrop(FLAT_BACKDROP)
baitListBox:SetBackdropColor(0.055, 0.078, 0.125, 1)
baitListBox:SetBackdropBorderColor(0.14, 0.20, 0.30, 1)

local baitScroll = CreateFrame("ScrollFrame", "ForeverSniperBaitScroll", baitListBox, "UIPanelScrollFrameTemplate")
baitScroll:SetPoint("TOPLEFT", 6, -6)
baitScroll:SetPoint("BOTTOMRIGHT", -26, 6)

local baitContent = CreateFrame("Frame", nil, baitScroll)
baitContent:SetSize(496, 200)
baitScroll:SetScrollChild(baitContent)

local baitEmptyText = baitListBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitEmptyText:SetPoint("CENTER")
baitEmptyText:SetText("|cff64748bСписок наживок пуст. Добавьте предмет и цену выше.|r")

local baitRows = {}

local function ExecuteBaitPost(itemID, priceCopper)
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
    print("|cfff59e0bGoblin Broker [На живца]:|r сначала откройте окно аукциона.")
    return
  end
  if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    print("|cfff59e0bGoblin Broker [На живца]:|r слот АХ занят — нажмите ещё раз.")
    return
  end
  if not priceCopper or priceCopper <= 0 then
    print("|cfff59e0bGoblin Broker [На живца]:|r укажите цену больше 0.")
    return
  end
  local itemLoc, bagCount = FindBagItemLocation(itemID)
  if not itemLoc or bagCount < BAIT_QTY then
    print("|cfff59e0bGoblin Broker [На живца]:|r предмета нет в сумках (нужна минимум 1 шт).")
    if RenderBaitList then RenderBaitList() end
    return
  end
  local _, itemName = GetItemVisuals(itemID)
  local isCommodity = IsBaitCommodity(itemID)
  local ok, needsConfirm = false, false

  if state.pendingBaitConfirmID == itemID then
    state.pendingBaitConfirmID = nil
    if isCommodity and C_AuctionHouse and C_AuctionHouse.ConfirmPostCommodity then
      ok = pcall(C_AuctionHouse.ConfirmPostCommodity, itemLoc, BAIT_DURATION, BAIT_QTY, priceCopper)
    elseif (not isCommodity) and C_AuctionHouse and C_AuctionHouse.ConfirmPostItem then
      ok = pcall(C_AuctionHouse.ConfirmPostItem, itemLoc, BAIT_DURATION, BAIT_QTY, priceCopper, priceCopper)
    end
  else
    if isCommodity and C_AuctionHouse and C_AuctionHouse.PostCommodity then
      ok, needsConfirm = pcall(C_AuctionHouse.PostCommodity, itemLoc, BAIT_DURATION, BAIT_QTY, priceCopper)
    elseif (not isCommodity) and C_AuctionHouse and C_AuctionHouse.PostItem then
      ok, needsConfirm = pcall(C_AuctionHouse.PostItem, itemLoc, BAIT_DURATION, BAIT_QTY, priceCopper, priceCopper)
    end
  end

  if ok and needsConfirm == true then
    state.pendingBaitConfirmID = itemID
    print(string.format("|cfff59e0bGoblin Broker [На живца]:|r цена сильно ниже рынка — нажмите |cfffef08aПодтв. цену!|r ещё раз для %s.", itemName or itemID))
  elseif ok then
    print(string.format("|cfff59e0bGoblin Broker [На живца]:|r выставлен 1x %s за %s (мин. срок).", itemName or itemID, FormatCoinsPlain(priceCopper)))
  else
    print("|cfff59e0bGoblin Broker [На живца]:|r не удалось выставить лот (проверьте АХ и предмет).")
  end
  if RenderBaitList then RenderBaitList() end
end

RenderBaitList = function()
  local baits = EnsureBaitsDB()
  local list = {}
  for id, price in pairs(baits) do
    local _, nm = GetItemVisuals(id)
    table.insert(list, { id = id, price = price, name = nm or tostring(id) })
  end
  table.sort(list, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)

  if #list == 0 then
    baitEmptyText:Show()
  else
    baitEmptyText:Hide()
  end

  local ahOpen = AuctionHouseFrame and AuctionHouseFrame:IsShown()
  for i, entry in ipairs(list) do
    local row = baitRows[i]
    if not row then
      row = CreateFrame("Button", nil, baitContent, "BackdropTemplate")
      row:SetHeight(40)
      row:SetPoint("TOPLEFT", 0, -((i - 1) * 44))
      row:SetPoint("TOPRIGHT", 0, -((i - 1) * 44))
      row:SetBackdrop(FLAT_BACKDROP)
      row:SetBackdropColor(0.075, 0.105, 0.17, 0.95)
      row:SetBackdropBorderColor(0.15, 0.22, 0.34, 1)

      row.ico = row:CreateTexture(nil, "ARTWORK")
      row.ico:SetSize(26, 26)
      row.ico:SetPoint("LEFT", 8, 0)
      row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

      row.delBtn = CreateFlatButton(nil, row, 22, 22, "X")
      row.delBtn:SetPoint("RIGHT", -6, 0)
      row.delBtn:SetColors({ 0.18, 0.08, 0.10, 1 }, { 0.32, 0.10, 0.14, 1 }, { 0.45, 0.15, 0.20, 0.8 }, { 0.95, 0.65, 0.70 })

      row.postBtn = CreateFlatButton(nil, row, 108, 24, "Выставить 1 шт")
      row.postBtn:SetPoint("RIGHT", row.delBtn, "LEFT", -6, 0)

      row.priceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.priceText:SetPoint("TOPRIGHT", row.postBtn, "TOPLEFT", -10, 2)
      row.priceText:SetWidth(112)
      row.priceText:SetJustifyH("RIGHT")

      row.metaText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.metaText:SetPoint("TOPRIGHT", row.priceText, "BOTTOMRIGHT", 0, -2)
      row.metaText:SetWidth(112)
      row.metaText:SetJustifyH("RIGHT")
      row.metaText:SetText("|cff64748b1 шт • мин. срок|r")

      row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      row.nameText:SetPoint("TOPLEFT", row.ico, "TOPRIGHT", 8, -1)
      row.nameText:SetPoint("RIGHT", row.priceText, "LEFT", -8, 0)
      row.nameText:SetJustifyH("LEFT")
      row.nameText:SetWordWrap(false)

      row.bagText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.bagText:SetPoint("BOTTOMLEFT", row.ico, "BOTTOMRIGHT", 8, 1)
      row.bagText:SetPoint("RIGHT", row.priceText, "LEFT", -8, 0)
      row.bagText:SetJustifyH("LEFT")

      baitRows[i] = row
    end

    local icon, nm, r, g, b = GetItemVisuals(entry.id)
    local _, bagCount = FindBagItemLocation(entry.id)
    if not ForeverSniperDB.activeBaitID or not baits[ForeverSniperDB.activeBaitID] then
      ForeverSniperDB.activeBaitID = entry.id
    end
    local isActiveBait = (ForeverSniperDB.activeBaitID == entry.id)
    row.itemID = entry.id
    row.priceCopper = entry.price
    row.isActiveBait = isActiveBait
    row.ico:SetTexture(icon)
    row.nameText:SetText((isActiveBait and "|cfff59e0b★ |r" or "") .. nm)
    row.nameText:SetTextColor(r, g, b)
    row:SetBackdropBorderColor(isActiveBait and 0.92 or 0.15, isActiveBait and 0.70 or 0.22, isActiveBait and 0.03 or 0.34, isActiveBait and 0.9 or 1)
    row.bagText:SetText(string.format("|cff94a3b8В сумках:|r %s%d шт|r%s", bagCount > 0 and "|cff10b981" or "|cfff43f5e", bagCount, isActiveBait and "  |cfff59e0b[Хоткей]|r" or ""))
    row.priceText:SetText(FormatCoins(entry.price))

    local needsConfirm = (state.pendingBaitConfirmID == entry.id)
    if not ahOpen then
      row.postBtn:SetLabel("Откройте АХ")
      row.postBtn:SetColors({ 0.10, 0.13, 0.20, 1 }, { 0.14, 0.18, 0.26, 1 }, { 0.20, 0.26, 0.36, 0.6 }, { 0.50, 0.58, 0.70 })
    elseif bagCount < 1 then
      row.postBtn:SetLabel("Нет в сумке")
      row.postBtn:SetColors({ 0.10, 0.13, 0.20, 1 }, { 0.14, 0.18, 0.26, 1 }, { 0.20, 0.26, 0.36, 0.6 }, { 0.50, 0.58, 0.70 })
    elseif needsConfirm then
      row.postBtn:SetLabel("Подтв. цену!")
      row.postBtn:SetColors({ 0.52, 0.14, 0.14, 1 }, { 0.68, 0.18, 0.18, 1 }, { 0.96, 0.35, 0.35, 0.95 }, { 1, 0.95, 0.95 })
    else
      row.postBtn:SetLabel("Выставить 1 шт")
      row.postBtn:SetColors({ 0.45, 0.32, 0.02, 1 }, { 0.62, 0.44, 0.03, 1 }, { 0.92, 0.70, 0.03, 0.95 }, { 1, 0.96, 0.85 })
    end

    row:SetScript("OnClick", function(self)
      ForeverSniperDB.activeBaitID = self.itemID
      ApplyBaitPreviewItemID(self.itemID, self.priceCopper)
      RenderBaitList()
    end)
    row:SetScript("OnEnter", function(self)
      self:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.75)
      if GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Клик по строке: выбрать для хоткея (★) и ред. цены", 0.65, 0.75, 0.85)
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function(self)
      if self.isActiveBait then
        self:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.9)
      else
        self:SetBackdropBorderColor(0.15, 0.22, 0.34, 1)
      end
      if GameTooltip then GameTooltip:Hide() end
    end)

    row.postBtn:SetScript("OnClick", function()
      ForeverSniperDB.activeBaitID = entry.id
      ExecuteBaitPost(entry.id, entry.price)
    end)
    row.delBtn:SetScript("OnClick", function()
      EnsureBaitsDB()[entry.id] = nil
      if ForeverSniperDB.activeBaitID == entry.id then
        ForeverSniperDB.activeBaitID = nil
      end
      if state.pendingBaitConfirmID == entry.id then
        state.pendingBaitConfirmID = nil
      end
      RenderBaitList()
    end)
    row:Show()
  end

  for i = #list + 1, #baitRows do
    baitRows[i]:Hide()
  end
  baitContent:SetHeight(math.max(180, #list * 44))
end

baitSaveBtn:SetScript("OnClick", function()
  local id = tonumber(baitIdInput:GetText())
  local g = tonumber(baitGoldInput:GetText()) or 0
  local s = tonumber(baitSilverInput:GetText()) or 0
  local c = tonumber(baitCopperInput:GetText()) or 0
  local copper = (g * 10000) + (s * 100) + c
  if not id or id <= 0 or copper <= 0 then
    print("|cfff59e0bGoblin Broker [На живца]:|r укажите корректный ID предмета и цену (з / с / м).")
    return
  end
  EnsureBaitsDB()[id] = copper
  ForeverSniperDB.activeBaitID = id
  state.pendingBaitConfirmID = nil
  ApplyBaitPreviewItemID(id, copper)
  RenderBaitList()
end)

baitIdInput:SetScript("OnEnterPressed", function(self)
  local id = tonumber(self:GetText())
  if id and id > 0 then
    ApplyBaitPreviewItemID(id)
  else
    self:ClearFocus()
  end
end)

function ForeverSniper_OnBaitHotkey()
  local baits = EnsureBaitsDB()
  local targetID = ForeverSniperDB.activeBaitID
  if not targetID or not baits[targetID] then
    for id in pairs(baits) do
      targetID = id
      ForeverSniperDB.activeBaitID = id
      break
    end
  end
  if not targetID or not baits[targetID] then
    print("|cfff59e0bGoblin Broker [На живца]:|r список наживок пуст. Добавьте предмет в окне «На живца».")
    return
  end
  ExecuteBaitPost(targetID, baits[targetID])
end

local function ToggleBaitModal()
  if baitModal:IsShown() then
    baitModal:Hide()
  else
    EnsureBaitsDB()
    RefreshBaitHotkeyBtn()
    RefreshBaitSkip1Btn()
    RenderBaitList()
    baitModal:Show()
  end
end

f._baitModal = baitModal
f._renderBaitList = RenderBaitList
if f._baitBtn then f._baitBtn:SetScript("OnClick", ToggleBaitModal) end
end

-- ============================================================================
-- Saved Presets & Inline Popover (Save / Load / Copy / Delete / Export)
-- ============================================================================
local PRO_STARTER_PRESETS = {
  ["[PRO] Топ Рейд-Травы"] = {
    watchlist = { [13468] = 90000, [13466] = 1900, [13463] = 1650, [13464] = 1150, [13465] = 1000, [8845] = 4000 },
    qtyLimits = { [13468] = 5, [13466] = 100, [13463] = 100, [13464] = 100, [13465] = 100, [8845] = 60 },
  },
  ["[PRO] Топ Руда и Арканит"] = {
    watchlist = { [12360] = 335000, [10620] = 1500, [12359] = 1650, [3858] = 800, [12361] = 28000, [12364] = 8800 },
    qtyLimits = { [12360] = 10, [10620] = 200, [12359] = 200, [3858] = 200, [12361] = 20, [12364] = 20 },
  },
  ["[PRO] Ткань и Луноткань"] = {
    watchlist = { [14342] = 560000, [14256] = 7500, [14047] = 420, [4338] = 330, [4306] = 160 },
    qtyLimits = { [14342] = 10, [14256] = 60, [14047] = 500, [4338] = 400, [4306] = 400 },
  },
  ["[PRO] Наложение чар"] = {
    watchlist = { [20725] = 520000, [14344] = 23000, [16204] = 1400, [11176] = 1450, [11137] = 650, [11083] = 390 },
    qtyLimits = { [20725] = 10, [14344] = 40, [16204] = 200, [11176] = 200, [11137] = 200, [11083] = 200 },
  },
  ["[PRO] Рейд-Химия и Настои"] = {
    watchlist = { [13510] = 165000, [13512] = 215000, [13511] = 155000, [13457] = 14500, [13452] = 7000, [13446] = 2600 },
    qtyLimits = { [13510] = 5, [13512] = 5, [13511] = 5, [13457] = 40, [13452] = 60, [13446] = 100 },
  },
}

local function CopyTableShallow(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do out[k] = v end
  return out
end

SyncActivePresetSnapshot = function()
  local ap = ForeverSniperDB.activePreset
  local p = ap and ForeverSniperDB.presets and ForeverSniperDB.presets[ap]
  if not p then
    ForeverSniperDB.presetDirty = false
    return
  end
  local curWL = ForeverSniperDB.watchlist or {}
  local preWL = p.watchlist or {}
  local curQty = ForeverSniperDB.qtyLimits or {}
  local preQty = p.qtyLimits or {}

  for id, price in pairs(curWL) do
    if preWL[id] ~= price then ForeverSniperDB.presetDirty = true; return end
    if (curQty[id] or 0) ~= (preQty[id] or 0) then ForeverSniperDB.presetDirty = true; return end
  end
  for id, price in pairs(preWL) do
    if curWL[id] ~= price then ForeverSniperDB.presetDirty = true; return end
  end
  ForeverSniperDB.presetDirty = false
end

local function LoadPresetByName(nm)
  if not nm then
    ForeverSniperDB.activePreset = nil
    ForeverSniperDB.presetDirty = false
    UpdateStatus()
    return
  end
  local p = ForeverSniperDB.presets and ForeverSniperDB.presets[nm]
  if not p then return end
  ForeverSniperDB.activePreset = nm
  ForeverSniperDB.presetDirty = false
  ForeverSniperDB.watchlist = CopyTableShallow(p.watchlist)
  ForeverSniperDB.qtyLimits = CopyTableShallow(p.qtyLimits)
  ForeverSniperDB.tracked = CopyTableShallow(p.tracked)
  ForeverSniperDB.boughtByItem = {}
  ForeverSniperDB.selectedID = nil
  state.lastSeenByItem = {}
  if C_Item and C_Item.RequestLoadItemDataByID then
    for id in pairs(p.watchlist or {}) do
      C_Item.RequestLoadItemDataByID(id)
    end
  end
  ClearPendingDeal()
  UpdateStatus()
  SyncInputsFromSelected()
  local cnt = 0
  for _ in pairs(p.watchlist or {}) do cnt = cnt + 1 end
  print(string.format("|cff10b981Goblin Broker:|r активен шаблон «%s» (%d поз.).", nm, cnt))
end

do
  local menu = CreateFrame("Frame", nil, f, "BackdropTemplate")
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetBackdrop(FLAT_BACKDROP)
  menu:SetBackdropColor(0.043, 0.067, 0.125, 0.98)
  menu:SetBackdropBorderColor(0.24, 0.32, 0.46, 1)
  menu:SetWidth(416)
  menu:EnableMouse(true)
  AttachDropShadow(menu, 12, 0.85)
  menu:Hide()
  f.presetMenu = menu

  local newInput = CreateFrame("EditBox", nil, menu, "BackdropTemplate")
  StyleFlatBox(newInput, 172, 24)
  newInput:SetPoint("TOPLEFT", 8, -8)

  local newPH = newInput:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  newPH:SetPoint("LEFT", 8, 0)
  newPH:SetText("|cff64748bНовый шаблон...|r")
  newInput:SetScript("OnEscapePressed", function(self) self:ClearFocus(); menu:Hide() end)

  local btnEmpty = CreateFlatButton(nil, menu, 70, 24, "+ Новый")
  btnEmpty:SetPoint("LEFT", newInput, "RIGHT", 6, 0)
  btnEmpty:SetColors({ 0.08, 0.22, 0.36, 1 }, { 0.12, 0.30, 0.48, 1 }, { 0.0, 0.71, 0.85, 0.75 }, { 0.9, 0.97, 1 })
  btnEmpty:SetFlatEnabled(false)

  local btnTracked = CreateFlatButton(nil, menu, 74, 24, "Из отм.")
  btnTracked:SetPoint("LEFT", btnEmpty, "RIGHT", 6, 0)
  btnTracked:SetColors({ 0.14, 0.12, 0.04, 1 }, { 0.24, 0.19, 0.06, 1 }, { 0.92, 0.70, 0.03, 0.8 }, { 0.99, 0.88, 0.45 })
  btnTracked:SetFlatEnabled(false)
  btnTracked:HookScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Создать из отмеченных", 0.96, 0.70, 0.03)
    GameTooltip:AddLine("Сохранит в новый шаблон только товары с включённым глазом-моноклем.", 0.85, 0.90, 0.96, true)
    GameTooltip:Show()
  end)
  btnTracked:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  local btnCopy = CreateFlatButton(nil, menu, 68, 24, "Копия")
  btnCopy:SetPoint("LEFT", btnTracked, "RIGHT", 6, 0)
  btnCopy:SetColors({ 0.02, 0.48, 0.34, 1 }, { 0.04, 0.62, 0.44, 1 }, { 0.06, 0.73, 0.51, 0.9 }, { 1, 1, 1 })
  btnCopy:SetFlatEnabled(false)

  local function RefreshCreatePresetButtons()
    local raw = newInput:GetText() or ""
    if raw == "" then newPH:Show() else newPH:Hide() end
    local nm = raw:gsub("^%s+", ""):gsub("%s+$", "")
    local exists = (nm ~= "" and ForeverSniperDB.presets and ForeverSniperDB.presets[nm] ~= nil)
    local hasTracked = (state.queue and #state.queue > 0)
    if nm == "" then
      btnEmpty:SetFlatEnabled(false)
      btnTracked:SetFlatEnabled(false)
      btnCopy:SetFlatEnabled(false)
      newInput:SetBackdropBorderColor(0.18, 0.24, 0.35, 1)
    elseif exists then
      btnEmpty:SetFlatEnabled(false)
      btnTracked:SetFlatEnabled(false)
      btnCopy:SetFlatEnabled(false)
      newInput:SetBackdropBorderColor(0.95, 0.28, 0.32, 1)
    else
      btnEmpty:SetFlatEnabled(true)
      btnTracked:SetFlatEnabled(hasTracked)
      btnCopy:SetFlatEnabled(true)
      if newInput:HasFocus() then
        newInput:SetBackdropBorderColor(0.92, 0.70, 0.03, 1)
      else
        newInput:SetBackdropBorderColor(0.18, 0.24, 0.35, 1)
      end
    end
  end

  newInput:HookScript("OnTextChanged", RefreshCreatePresetButtons)

  local divTop = menu:CreateTexture(nil, "ARTWORK")
  divTop:SetHeight(1)
  divTop:SetPoint("TOPLEFT", 8, -38)
  divTop:SetPoint("TOPRIGHT", -8, -38)
  divTop:SetColorTexture(0.18, 0.25, 0.36, 0.85)

  local divBot = menu:CreateTexture(nil, "ARTWORK")
  divBot:SetHeight(1)
  divBot:SetColorTexture(0.18, 0.25, 0.36, 0.85)

  local btnPro = CreateFlatButton(nil, menu, 174, 22, "+ 5 [PRO] наборов")
  btnPro:SetColors({ 0.16, 0.13, 0.04, 1 }, { 0.28, 0.21, 0.06, 1 }, { 0.92, 0.70, 0.03, 0.85 }, { 0.99, 0.88, 0.45 })

  local btnNone = CreateFlatButton(nil, menu, 140, 22, "Без шаблона")
  btnNone:SetColors({ 0.10, 0.13, 0.20, 1 }, { 0.18, 0.22, 0.32, 1 }, { 0.24, 0.30, 0.42, 0.8 }, { 0.78, 0.84, 0.92 })

  local mRows = {}
  local function RenderPresetMenu()
    ForeverSniperDB.presets = ForeverSniperDB.presets or {}
    local names = {}
    for nm in pairs(ForeverSniperDB.presets) do table.insert(names, nm) end
    table.sort(names)

    for _, r in ipairs(mRows) do r:Hide() end
    local y = -46
    for i, nm in ipairs(names) do
      local p = ForeverSniperDB.presets[nm]
      local r = mRows[i]
      if not r then
        r = CreateFrame("Frame", nil, menu)
        r:SetSize(400, 24)
        r.sel = CreateFlatButton(nil, r, 326, 22, "")
        r.sel:SetPoint("LEFT", 0, 0)
        r.sel.label:SetJustifyH("LEFT")
        r.sel.label:ClearAllPoints()
        r.sel.label:SetPoint("LEFT", 8, 0)
        r.sel.label:SetPoint("RIGHT", -6, 0)
        r.sel:HookScript("OnEnter", function(self)
          if not GameTooltip or not self.presetName then return end
          local pd = ForeverSniperDB.presets and ForeverSniperDB.presets[self.presetName]
          if not pd then return end
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine("|cfff59e0b" .. self.presetName .. "|r")
          local ids = {}
          for id in pairs(pd.watchlist or {}) do table.insert(ids, id) end
          table.sort(ids)
          if #ids == 0 then
            GameTooltip:AddLine("Пустой шаблон", 0.65, 0.72, 0.82)
          else
            for idxItem, id in ipairs(ids) do
              if idxItem > 10 then
                GameTooltip:AddLine(string.format("... и ещё %d поз.", #ids - 10), 0.65, 0.72, 0.82)
                break
              end
              local _, iname = GetItemVisuals(id)
              local lim = pd.watchlist[id] or 0
              local q = pd.qtyLimits and pd.qtyLimits[id]
              local qTxt = (q and q > 0) and (" <= " .. q) or ""
              GameTooltip:AddDoubleLine(iname, FormatCoinsPlain(lim) .. qTxt, 0.88, 0.92, 0.98, 0.06, 0.85, 0.55)
            end
          end
          GameTooltip:Show()
        end)
        r.sel:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

        r.exp = CreateFlatButton(nil, r, 46, 22, "Эксп.")
        r.exp:SetPoint("LEFT", r.sel, "RIGHT", 2, 0)
        r.exp:SetColors({ 0, 0, 0, 0 }, { 0.12, 0.18, 0.28, 1 }, { 0, 0, 0, 0 }, { 0.55, 0.68, 0.82 })
        r.del = CreateFlatButton(nil, r, 22, 22, "x")
        r.del:SetPoint("LEFT", r.exp, "RIGHT", 2, 0)
        r.del:SetColors({ 0, 0, 0, 0 }, { 0.48, 0.12, 0.16, 1 }, { 0, 0, 0, 0 }, { 0.55, 0.58, 0.65 })
        mRows[i] = r
      end
      local cnt = 0
      for _ in pairs(p.watchlist or {}) do cnt = cnt + 1 end
      local isActive = (nm == ForeverSniperDB.activePreset)
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", 8, y)
      r.sel.presetName = nm
      if isActive then
        r.sel:SetLabel(string.format("%s %s  |cff6ee7b7(%d)|r", DOT_GREEN, nm, cnt))
        r.sel:SetColors({ 0.04, 0.16, 0.14, 0.95 }, { 0.06, 0.22, 0.18, 1 }, { 0.06, 0.73, 0.51, 0.65 }, { 0.88, 1, 0.95 })
      else
        r.sel:SetLabel(string.format("   %s  |cff64748b(%d)|r", nm, cnt))
        r.sel:SetColors({ 0, 0, 0, 0 }, { 0.10, 0.15, 0.24, 1 }, { 0, 0, 0, 0 }, { 0.88, 0.92, 0.98 })
      end
      r.sel:SetScript("OnClick", function()
        menu:Hide()
        LoadPresetByName(nm)
      end)
      r.exp:SetScript("OnClick", function()
        local ids = {}
        for id in pairs(p.watchlist or {}) do table.insert(ids, id) end
        table.sort(ids)
        local lines = {}
        for _, id in ipairs(ids) do
          local price = p.watchlist[id]
          local q = p.qtyLimits and p.qtyLimits[id]
          if q and q > 0 then
            table.insert(lines, string.format("%d=%d:%d", id, price, q))
          else
            table.insert(lines, string.format("%d=%d", id, price))
          end
        end
        menu:Hide()
        OpenExportModal("Экспорт шаблона: " .. nm, table.concat(lines, "\n"))
        print(string.format("|cff06b6d4Goblin Broker:|r экспорт шаблона «%s» (%d поз.) — скопируйте Ctrl+C.", nm, #lines))
      end)
      r.del:SetScript("OnClick", function()
        ForeverSniperDB.presets[nm] = nil
        if ForeverSniperDB.activePreset == nm then
          ForeverSniperDB.activePreset = nil
          ForeverSniperDB.presetDirty = false
          UpdateStatus()
        end
        RenderPresetMenu()
      end)
      r:Show()
      y = y - 25
    end

    if #names == 0 then y = y - 4 end
    divBot:ClearAllPoints()
    divBot:SetPoint("TOPLEFT", 8, y - 2)
    divBot:SetPoint("TOPRIGHT", -8, y - 2)

    local missingPro = 0
    for nm in pairs(PRO_STARTER_PRESETS) do
      if not ForeverSniperDB.presets[nm] then missingPro = missingPro + 1 end
    end

    btnPro:ClearAllPoints()
    btnNone:ClearAllPoints()
    if missingPro > 0 then
      btnPro:Show()
      btnPro:SetPoint("TOPLEFT", 8, y - 9)
      btnNone:SetWidth(220)
      btnNone:SetPoint("LEFT", btnPro, "RIGHT", 6, 0)
    else
      btnPro:Hide()
      btnNone:SetWidth(400)
      btnNone:SetPoint("TOPLEFT", 8, y - 9)
    end
    RefreshCreatePresetButtons()
    menu:SetHeight(-(y - 39))
  end

  local function CreatePresetFromInput(mode)
    local nm = (newInput:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if nm == "" then
      print("|cfff59e0bGoblin Broker:|r введите название шаблона.")
      return
    end
    ForeverSniperDB.presets = ForeverSniperDB.presets or {}
    if ForeverSniperDB.presets[nm] then
      print(string.format("|cfff43f5eGoblin Broker:|r шаблон «%s» уже существует — используйте другое имя или кнопку «• Обновить».", nm))
      return
    end
    if mode == "empty" then
      ForeverSniperDB.presets[nm] = { watchlist = {}, qtyLimits = {}, tracked = {} }
      ForeverSniperDB.activePreset = nm
      ForeverSniperDB.presetDirty = false
      ForeverSniperDB.watchlist = {}
      ForeverSniperDB.qtyLimits = {}
      ForeverSniperDB.tracked = {}
      ForeverSniperDB.boughtByItem = {}
      ForeverSniperDB.selectedID = nil
      state.lastSeenByItem = {}
      ClearPendingDeal()
      UpdateStatus()
    elseif mode == "tracked" then
      local wl, ql, tr = {}, {}, {}
      local cnt = 0
      for id, price in pairs(ForeverSniperDB.watchlist or {}) do
        if IsItemTracked(id) then
          wl[id] = price
          if ForeverSniperDB.qtyLimits and ForeverSniperDB.qtyLimits[id] then
            ql[id] = ForeverSniperDB.qtyLimits[id]
          end
          tr[id] = true
          cnt = cnt + 1
        end
      end
      if cnt == 0 then
        print("|cfff59e0bGoblin Broker:|r нет отмеченных (активных) товаров для создания шаблона.")
        return
      end
      ForeverSniperDB.presets[nm] = { watchlist = wl, qtyLimits = ql, tracked = tr }
      ForeverSniperDB.activePreset = nm
      ForeverSniperDB.presetDirty = false
      ForeverSniperDB.watchlist = CopyTableShallow(wl)
      ForeverSniperDB.qtyLimits = CopyTableShallow(ql)
      ForeverSniperDB.tracked = CopyTableShallow(tr)
      ForeverSniperDB.boughtByItem = {}
      ForeverSniperDB.selectedID = nil
      state.lastSeenByItem = {}
      ClearPendingDeal()
      UpdateStatus()
      SyncInputsFromSelected()
    else
      ForeverSniperDB.presets[nm] = {
        watchlist = CopyTableShallow(ForeverSniperDB.watchlist),
        qtyLimits = CopyTableShallow(ForeverSniperDB.qtyLimits),
        tracked = CopyTableShallow(ForeverSniperDB.tracked),
      }
      ForeverSniperDB.activePreset = nm
      ForeverSniperDB.presetDirty = false
      UpdateStatus()
    end
    newInput:SetText("")
    newInput:ClearFocus()
    RenderPresetMenu()
    print(string.format("|cff10b981Goblin Broker:|r шаблон «%s» создан.", nm))
  end

  btnEmpty:SetScript("OnClick", function() CreatePresetFromInput("empty") end)
  btnTracked:SetScript("OnClick", function() CreatePresetFromInput("tracked") end)
  btnCopy:SetScript("OnClick", function() CreatePresetFromInput("all") end)
  newInput:SetScript("OnEnterPressed", function() CreatePresetFromInput("all") end)

  btnPro:SetScript("OnClick", function()
    ForeverSniperDB.presets = ForeverSniperDB.presets or {}
    local added = 0
    for nm, data in pairs(PRO_STARTER_PRESETS) do
      if not ForeverSniperDB.presets[nm] then
        ForeverSniperDB.presets[nm] = {
          watchlist = CopyTableShallow(data.watchlist),
          qtyLimits = CopyTableShallow(data.qtyLimits),
        }
        added = added + 1
      end
    end
    RenderPresetMenu()
    if added > 0 then
      print(string.format("|cff10b981Goblin Broker:|r добавлено %d PRO-шаблонов.", added))
    else
      print("|cff94a3b8Goblin Broker:|r все 5 PRO-шаблонов уже есть.")
    end
  end)

  btnNone:SetScript("OnClick", function()
    menu:Hide()
    LoadPresetByName(nil)
  end)

  presetPickerBtn:SetScript("OnClick", function()
    if ForeverSniperDB.autoScan then return end
    if menu:IsShown() then
      menu:Hide()
    else
      RenderPresetMenu()
      menu:ClearAllPoints()
      menu:SetPoint("TOPLEFT", presetPickerBtn, "BOTTOMLEFT", 0, -2)
      menu:Show()
    end
  end)
end

wlSaveBtn:SetScript("OnClick", function()
  local ap = ForeverSniperDB.activePreset
  if ap and ForeverSniperDB.presets and ForeverSniperDB.presets[ap] then
    ForeverSniperDB.presets[ap] = {
      watchlist = CopyTableShallow(ForeverSniperDB.watchlist),
      qtyLimits = CopyTableShallow(ForeverSniperDB.qtyLimits),
      tracked = CopyTableShallow(ForeverSniperDB.tracked),
    }
    ForeverSniperDB.presetDirty = false
    UpdateStatus()
    print(string.format("|cff10b981Goblin Broker:|r шаблон «%s» обновлён.", ap))
  end
end)

if wlBox.emptyPanel and wlBox.emptyPanel.btn then
  wlBox.emptyPanel.btn:SetScript("OnClick", function()
    ForeverSniperDB.presets = ForeverSniperDB.presets or {}
    for nm, data in pairs(PRO_STARTER_PRESETS) do
      if not ForeverSniperDB.presets[nm] then
        ForeverSniperDB.presets[nm] = {
          watchlist = CopyTableShallow(data.watchlist),
          qtyLimits = CopyTableShallow(data.qtyLimits),
        }
      end
    end
    LoadPresetByName("[PRO] Топ Рейд-Травы")
  end)
end

-- ============================================================================
-- 1-Second Polling Loop
-- ============================================================================
f:SetScript("OnUpdate", function()
  local now = GetTime()
  if state.pendingDeal and state.pendingDeal.stage == "confirm" then
    local elapsed = now - (state.pendingDeal.confirmAt or now)
    if elapsed >= 10 then
      state.lastConfirmRem = nil
      ClearPendingDeal()
      return
    end
    local rem = math.max(0, math.ceil(10 - elapsed))
    if state.lastConfirmRem ~= rem then
      state.lastConfirmRem = rem
      RefreshBuyButtonText()
    end
    return
  end
  state.lastConfirmRem = nil
  if state.ahOpen and AuctionHouseFrame and not AuctionHouseFrame:IsShown() then
    state.ahOpen = false
    ForeverSniperDB.autoScan = false
    if f.presetMenu then f.presetMenu:Hide() end
    ClearPendingDeal()
    UpdateStatus()
    RefreshOverrideBindings()
    f:Hide()
    return
  end
  if not state.ahOpen or not ForeverSniperDB.autoScan then return end
  if now < (state.pauseScanUntil or 0) then return end
  -- Stop sending search queries as soon as a deal is found so AH throttle stays 100% free for instant purchase
  if state.pendingDeal then return end
  if now - state.lastQueryAt < state.queryInterval then return end
  SendTargetQuery()
end)

-- ============================================================================
-- Events, Minimap Button & AH Hook
-- ============================================================================
RefreshOverrideBindings = function()
  if InCombatLockdown and InCombatLockdown() then return end
  if not ClearOverrideBindings or not SetOverrideBindingClick then return end
  ClearOverrideBindings(f)
  if state.ahOpen and f:IsShown() and GetBindingKey then
    local k1, k2 = GetBindingKey("FOREVERSNIPER_BUY")
    if k1 and k1 ~= "" then SetOverrideBindingClick(f, true, k1, "ForeverSniperBuyBtn", "LeftButton") end
    if k2 and k2 ~= "" then SetOverrideBindingClick(f, true, k2, "ForeverSniperBuyBtn", "LeftButton") end
  end
end

local function HandleBuyMouseWheel(delta)
  if not state.ahOpen or not state.pendingDeal or not GetBindingKey then return false end
  local k1, k2 = GetBindingKey("FOREVERSNIPER_BUY")
  local wantUp = (delta > 0)
  local shift = IsShiftKeyDown and IsShiftKeyDown()
  local ctrl = IsControlKeyDown and IsControlKeyDown()
  local alt = IsAltKeyDown and IsAltKeyDown()
  local prefix = (shift and "SHIFT-" or "") .. (ctrl and "CTRL-" or "") .. (alt and "ALT-" or "")
  local ev = prefix .. (wantUp and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
  if ev == k1 or ev == k2 then
    ExecuteBuyAction("LeftButton")
    return true
  end
  return false
end

f:EnableMouseWheel(true)
f:SetScript("OnMouseWheel", function(_, delta)
  HandleBuyMouseWheel(delta)
end)

if wlScroll then
  wlScroll:HookScript("OnMouseWheel", function(_, delta)
    HandleBuyMouseWheel(delta)
  end)
end

f:HookScript("OnHide", function()
  if ClearOverrideBindings and not (InCombatLockdown and InCombatLockdown()) then
    ClearOverrideBindings(f)
  end
end)

local function ToggleSniperWindow()
  if f:IsShown() then
    f:Hide()
  else
    f:Show()
    UpdateStatus()
    SyncInputsFromSelected()
    RefreshOverrideBindings()
  end
end

function ForeverSniper_OnToggleHotkey()
  ToggleSniperWindow()
end

-- Minimap Toggle Button (Modern Rounded Coin Badge — clean on Minimap & Button Bags)
local MINIMAP_ICON_PATH = "Interface\\AddOns\\ForeverSniper\\minimap_icon.tga"
local mmBtn = CreateFrame("Button", "ForeverSniperMinimapBtn", Minimap)
mmBtn:SetSize(32, 32)
mmBtn:SetFrameStrata("MEDIUM")
mmBtn:SetFrameLevel(8)
mmBtn:RegisterForClicks("LeftButtonUp")
mmBtn:RegisterForDrag("LeftButton", "RightButton")
mmBtn:SetClampedToScreen(true)
mmBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local mmLogo = mmBtn:CreateTexture(nil, "ARTWORK")
mmLogo:SetAllPoints()
mmLogo:SetTexture(MINIMAP_ICON_PATH)
mmBtn.icon = mmLogo

local function UpdateMinimapPos()
  if not Minimap then return end
  local angle = math.rad(ForeverSniperDB.minimapAngle or 215)
  local radius = (Minimap:GetWidth() / 2) + 8
  mmBtn:ClearAllPoints()
  mmBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

mmBtn:SetScript("OnDragStart", function(self)
  self.isDragging = true
  self:LockHighlight()
  self:SetScript("OnUpdate", function()
    if not Minimap then return end
    local mx, my = Minimap:GetCenter()
    if not mx or not my then return end
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale() or 1
    cx, cy = cx / scale, cy / scale
    ForeverSniperDB.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
    UpdateMinimapPos()
  end)
end)

mmBtn:SetScript("OnDragStop", function(self)
  self:SetScript("OnUpdate", nil)
  self:UnlockHighlight()
  self.isDragging = false
end)

mmBtn:SetScript("OnClick", function(self)
  if self.isDragging then return end
  ToggleSniperWindow()
end)

mmBtn:SetScript("OnEnter", function(self)
  mmLogo:SetVertexColor(1.08, 1.08, 1.08)
  if GameTooltip then
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cfff59e0bGoblin Broker|r|cfff8fafc: Forever|r")
    GameTooltip:AddLine("ЛКМ: Открыть / скрыть окно", 0.85, 0.90, 0.95)
    GameTooltip:AddLine("Перетаскивание (ЛКМ или ПКМ): переместить кнопку", 0.58, 0.64, 0.72)
    GameTooltip:Show()
  end
end)

mmBtn:SetScript("OnLeave", function(self)
  mmLogo:SetVertexColor(1, 1, 1)
  if GameTooltip then GameTooltip:Hide() end
end)

local hookedAH = false
local function HookAuctionHouseFrame()
  if hookedAH or not AuctionHouseFrame then return end
  hookedAH = true

  -- Quick toggle button right inside Blizzard's Auction House header
  local ahToggleBtn = CreateFlatButton("ForeverSniperAHToggleBtn", AuctionHouseFrame, 108, 22, "|cfff59e0bGoblin Broker|r")
  ahToggleBtn:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPRIGHT", -34, -4)
  ahToggleBtn:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 10)
  ahToggleBtn:SetColors({ 0.043, 0.067, 0.125, 0.95 }, { 0.09, 0.14, 0.24, 1 }, { 0.92, 0.70, 0.03, 0.85 }, { 1, 0.95, 0.82 })
  ahToggleBtn:SetScript("OnClick", function()
    ToggleSniperWindow()
  end)

  AuctionHouseFrame:HookScript("OnShow", function()
    state.ahOpen = true
    state.throttled = false
    f:Show()
    UpdateStatus()
    SyncInputsFromSelected()
    RefreshOverrideBindings()
  end)
  AuctionHouseFrame:HookScript("OnHide", function()
    state.ahOpen = false
    ForeverSniperDB.autoScan = false
    if f.presetMenu then f.presetMenu:Hide() end
    ClearPendingDeal()
    UpdateStatus()
    RefreshOverrideBindings()
    f:Hide()
  end)
  if AuctionHouseFrame:IsShown() then
    state.ahOpen = true
    f:Show()
    UpdateStatus()
    SyncInputsFromSelected()
    RefreshOverrideBindings()
  end
end

local tierPrices, tierQtys, tierCount = {}, {}, 0
local function ComputeTierCost(wantQty)
  local rem = wantQty
  local sum = 0
  for i = 1, tierCount do
    if rem <= 0 then break end
    local take = math.min(rem, tierQtys[i])
    sum = sum + take * tierPrices[i]
    rem = rem - take
  end
  return sum
end

local function TryInstantNextQuery()
  if not state.ahOpen or not ForeverSniperDB.autoScan or state.pendingDeal then return end
  local now = GetTime()
  if now < (state.pauseScanUntil or 0) then return end
  if now - (state.lastQueryAt or 0) < (state.queryInterval or 0.25) then return end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
  SendTargetQuery()
end

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("UPDATE_BINDINGS")
f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:RegisterEvent("MAIL_INBOX_UPDATE")
f:RegisterEvent("OWNED_AUCTIONS_UPDATED")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
f:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
f:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
f:RegisterEvent("COMMODITY_PURCHASE_FAILED")
pcall(f.RegisterEvent, f, "COMMODITY_PRICE_UPDATED")
pcall(f.RegisterEvent, f, "COMMODITY_PRICE_UNAVAILABLE")
f:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
f:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")

f:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "PLAYER_LOGIN" then
    EnsureBackgroundSoundCVar()
    RefreshBuyHotkeyCache()
    RefreshSoundBtn()
    if f._refreshSkip1Btn then f._refreshSkip1Btn() end
    RefreshTrackBtn()
    ApplyMiniMode()
    if ForeverSniperDB.windowPos then
      ApplyWindowPos(ForeverSniperDB.windowPos)
    end
    UpdateMinimapPos()
    HookAuctionHouseFrame()
    UpdateStatus()
    SyncInputsFromSelected()
    print("|cfff59e0bGoblin Broker:|r загружен! Откройте АХ или нажмите значок на миникарте (|cffffffff/gbroker|r)")
  elseif event == "ADDON_LOADED" and arg1 == "Blizzard_AuctionHouseUI" then
    HookAuctionHouseFrame()
  elseif event == "UPDATE_BINDINGS" then
    RefreshBuyHotkeyCache()
    RefreshBuyButtonText()
    RefreshOverrideBindings()
    if f._baitModal and f._baitModal:IsShown() and f._baitModal.RefreshHotkey then
      f._baitModal.RefreshHotkey()
    end
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if f:IsShown() then RenderWatchlist() end
    if f._baitModal and f._baitModal:IsShown() and f._renderBaitList then f._renderBaitList() end
  elseif event == "BAG_UPDATE_DELAYED" then
    if f._baitModal and f._baitModal:IsShown() and f._renderBaitList then f._renderBaitList() end
  elseif event == "MAIL_INBOX_UPDATE" then
    if f._sales and f._sales.onMailInboxUpdate then f._sales.onMailInboxUpdate() end
  elseif event == "OWNED_AUCTIONS_UPDATED" then
    if f._sales and f._sales.onOwnedAuctionsUpdated then f._sales.onOwnedAuctionsUpdated() end
  elseif event == "CHAT_MSG_SYSTEM" then
    if f._sales and f._sales.onSystemChat then f._sales.onSystemChat(arg1) end
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    state.throttled = true
    state.cleanQueryStreak = 0
    state.queryInterval = math.min(1.0, (state.queryInterval or 0.25) + 0.15)
    if state.pendingDeal and state.pendingDeal.stage == "confirm" then
      -- Reservation packet was dropped by AH throttle; revert to ready so user can re-send cleanly
      state.pendingDeal.stage = "ready"
      RefreshBuyButtonText()
      dealBadge:SetText("|cfff59e0bТРОТТЛИНГ АХ — НАЖМИТЕ КУПИТЬ СНОВА|r")
    end
    UpdateStatus()
  elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    if state.throttled then
      state.throttled = false
      if ForeverSniperDB.autoScan then
        statusText:SetText(DOT_GREEN .. string.format(" |cff10b981Скан: %d|r", state.queryCount))
        statusPill:SetBackdropBorderColor(0.06, 0.73, 0.51, 0.7)
      else
        statusText:SetText(DOT_GRAY .. " |cff94a3b8Пауза|r")
        statusPill:SetBackdropBorderColor(0.18, 0.25, 0.36, 1)
      end
    end
    if state.pendingDeal and state.pendingDeal.stage == "ready" then
      dealBadge:SetText(DOT_GREEN .. " |cff10b981ГОТОВО - ЖМИТЕ КУПИТЬ|r")
    end
    if GetTime() >= (state.pauseScanUntil or 0) then
      state.lastQueryAt = 0 -- Fire next query immediately when throttle bucket frees
      TryInstantNextQuery()
    end
  elseif event == "AUCTION_HOUSE_SHOW" then
    state.ahOpen = true
    state.throttled = false
    HookAuctionHouseFrame()
    f:Show()
    UpdateStatus()
    SyncInputsFromSelected()
    RefreshOverrideBindings()
    if f._baitModal and f._baitModal:IsShown() and f._renderBaitList then f._renderBaitList() end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    state.ahOpen = false
    state.pendingBaitConfirmID = nil
    ForeverSniperDB.autoScan = false
    if f.presetMenu then f.presetMenu:Hide() end
    if f._baitModal and f._baitModal:IsShown() then f._baitModal:Hide() end
    ClearPendingDeal()
    UpdateStatus()
    RefreshOverrideBindings()
    f:Hide()
  elseif event == "COMMODITY_PRICE_UPDATED" then
    if state.pendingDeal and state.pendingDeal.stage == "confirm" then
      local deal = state.pendingDeal
      local unitP = tonumber(arg1)
      local totP = tonumber(arg2)
      local effUnit = (unitP and unitP > 0) and unitP or ((totP and totP > 0 and (deal.qty or 1) > 0) and math.ceil(totP / math.max(1, deal.qty or 1)) or nil)
      if effUnit and deal.maxPrice and effUnit > deal.maxPrice then
        state.sessionBuys.lastOutcome = DOT_RED .. " |cfff43f5eЦена выросла выше лимита — отмена|r"
        RefreshSessionBar()
        ClearPendingDeal(false, false)
        state.lastQueryAt = 0
        return
      end
      local wasReady = deal.quoteReady
      deal.quoteReady = true
      deal.waitBadgeShown = false
      deal.throttleBadgeShown = false
      dealBadge:SetText(DOT_GREEN .. " |cff10b981БРОНЬ ГОТОВА - ЖМИТЕ ПОДТВЕРДИТЬ!|r")
      if not wasReady and IsSoundEnabled() and PlaySound then
        pcall(PlaySound, 8959, "Master")
      end
    end
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
    if state.pendingDeal and state.pendingDeal.stage == "confirm" then
      state.sessionBuys.lastOutcome = DOT_RED .. " |cfff43f5eЛот уже раскупили - перескан...|r"
      RefreshSessionBar()
      ClearPendingDeal()
      state.lastQueryAt = 0
    end
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    local att = state.lastPurchaseAttempt
    if att then
      state.lastPurchaseAttempt = nil
      RecordCompletedPurchase(att)
    end
    state.pauseScanUntil = 0
    state.lastQueryAt = 0
  elseif event == "COMMODITY_PURCHASE_FAILED" then
    if state.lastPurchaseAttempt then
      local missAtt = state.lastPurchaseAttempt
      state.lastPurchaseAttempt = nil
      RecordTelemetryMiss(missAtt.itemID, missAtt.name)
      state.sessionBuys.lastOutcome = DOT_RED .. " |cfff43f5eЛот перехвачен - перескан...|r"
      RefreshSessionBar()
    end
    state.pauseScanUntil = 0
    state.lastQueryAt = 0
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" and arg1 then
    local itemID = tonumber(arg1)
    if not itemID or not IsItemTracked(itemID) then return end
    local maxPrice = ForeverSniperDB.watchlist[itemID]
    if not maxPrice then return end
    if state.pendingDeal and (state.pendingDeal.stage == "confirm" or state.pendingDeal.itemID ~= itemID) then return end

    local num = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
    local totalAvail = 0
    local minUnitPrice = nil
    local lowestSeen = nil
    tierCount = 0
    for i = 1, num do
      local res = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
      if res and res.unitPrice and res.unitPrice > 0 then
        if not lowestSeen or res.unitPrice < lowestSeen then lowestSeen = res.unitPrice end
        if res.unitPrice <= maxPrice then
          if not minUnitPrice or res.unitPrice < minUnitPrice then
            minUnitPrice = res.unitPrice
          end
          local q = res.quantity or 0
          if q > 0 then
            totalAvail = totalAvail + q
            tierCount = tierCount + 1
            tierPrices[tierCount] = res.unitPrice
            tierQtys[tierCount] = q
          end
        else
          -- Results are sorted ascending by price (PRICE_SORTS)
          break
        end
      end
    end
    state.lastSeenByItem = state.lastSeenByItem or {}
    local prevSeen = state.lastSeenByItem[itemID]
    local prevLowest = prevSeen and prevSeen.lowestPrice
    local prevAvail = prevSeen and prevSeen.availBelow or 0
    state.lastSeenByItem[itemID] = prevSeen or {}
    state.lastSeenByItem[itemID].lowestPrice = lowestSeen
    state.lastSeenByItem[itemID].availBelow = totalAvail
    state.lastSeenByItem[itemID].updatedAt = GetTime()
    if lowestSeen and lowestSeen > 0 then
      local _, floorName = GetItemVisuals(itemID)
      RecordTelemetryMarketFloor(itemID, lowestSeen, floorName)
    end

    local minDealQty = ForeverSniperDB.skipSingleBait and 2 or 1
    if minUnitPrice and totalAvail >= minDealQty then
      local _, cachedName = GetItemVisuals(itemID)
      local dealPrices, dealQtys, dealTiers = {}, {}, tierCount
      for ti = 1, tierCount do
        dealPrices[ti] = tierPrices[ti]
        dealQtys[ti] = tierQtys[ti]
      end
      SetPendingDeal({
        itemID = itemID,
        isCommodity = true,
        unitPrice = minUnitPrice,
        qty = totalAvail,
        maxPrice = maxPrice,
        name = cachedName,
        stage = "ready",
        exactCostForQty = function(wantQty)
          local rem, sum = wantQty, 0
          for ti = 1, dealTiers do
            if rem <= 0 then break end
            local take = math.min(rem, dealQtys[ti])
            sum = sum + take * dealPrices[ti]
            rem = rem - take
          end
          return sum
        end,
      })
      RenderWatchlist()
    else
      -- Fast zero-redraw exit only if dealCard already shows this exact item & price
      if not state.pendingDeal and state.lastDisplayedDealItem == itemID and prevSeen and prevLowest == lowestSeen and prevAvail == 0 then
        TryInstantNextQuery()
        return
      end
      ClearPendingDeal(true)
      state.lastDisplayedDealItem = itemID
      RenderWatchlist()
      if lowestSeen then
        local _, overNm = GetItemVisuals(itemID)
        local diff = math.max(0, lowestSeen - maxPrice)
        local overPct = (maxPrice > 0) and math.floor((diff / maxPrice) * 100 + 0.5) or 0
        dealStripe:SetColorTexture(0.96, 0.45, 0.08, 1)
        dealCard:SetBackdropBorderColor(0.96, 0.45, 0.08, 0.65)
        dealBadge:SetText(DOT_AMBER .. " |cfff59e0bЦЕНА ВЫШЕ ЛИМИТА|r  |cff94a3b8·|r  |cfff8fafc" .. overNm .. "|r")
        dealDelta:SetText("|cff94a3b8Ожидание снижения...|r")
        dealTitle:SetText("|cffcbd5e1Мин. АХ:|r " .. FormatCoins(lowestSeen))
        dealQtyRight:SetText(string.format("|cfff43f5e+%s|r", FormatCoinsPlain(diff)))
        dealMeta:SetText("|cff94a3b8Ваш лимит:|r " .. FormatCoins(maxPrice))
        dealTotalRight:SetText(string.format("|cfff59e0b(+%d%%)|r", overPct))
      else
        dealTitle:SetText("|cff94a3b8Лоты по этому предмету не найдены|r")
        dealDelta:SetText("")
        dealMeta:SetText("")
        dealQtyRight:SetText("")
        dealTotalRight:SetText("")
      end
      TryInstantNextQuery()
    end
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and arg1 then
    local itemID = arg1.itemID
    if not itemID or not IsItemTracked(itemID) then return end
    local maxPrice = itemID and ForeverSniperDB.watchlist[itemID]
    if not maxPrice then return end
    if state.pendingDeal and (state.pendingDeal.stage == "confirm" or state.pendingDeal.itemID ~= itemID) then return end

    local num = C_AuctionHouse.GetNumItemSearchResults(arg1) or 0
    local found = false
    local lowestSeen = nil
    local matchCount = 0
    local bestAuction = nil
    for i = 1, num do
      local res = C_AuctionHouse.GetItemSearchResultInfo(arg1, i)
      if res and res.buyoutAmount and res.buyoutAmount > 0 then
        if not lowestSeen or res.buyoutAmount < lowestSeen then lowestSeen = res.buyoutAmount end
        if res.buyoutAmount <= maxPrice then
          matchCount = matchCount + 1
          if not bestAuction or res.buyoutAmount < bestAuction.buyoutAmount then
            bestAuction = res
          end
        else
          -- Results are sorted ascending by price (PRICE_SORTS)
          break
        end
      end
    end
    state.lastSeenByItem = state.lastSeenByItem or {}
    local prevSeen = state.lastSeenByItem[itemID]
    local prevLowest = prevSeen and prevSeen.lowestPrice
    local prevAvail = prevSeen and prevSeen.availBelow or 0
    state.lastSeenByItem[itemID] = prevSeen or {}
    state.lastSeenByItem[itemID].lowestPrice = lowestSeen
    state.lastSeenByItem[itemID].availBelow = matchCount
    state.lastSeenByItem[itemID].updatedAt = GetTime()
    if lowestSeen and lowestSeen > 0 then
      local _, floorName = GetItemVisuals(itemID)
      RecordTelemetryMarketFloor(itemID, lowestSeen, floorName)
    end

    if bestAuction then
      local _, cachedName = GetItemVisuals(itemID)
      SetPendingDeal({
        itemID = itemID,
        isCommodity = false,
        auctionID = bestAuction.auctionID,
        unitPrice = bestAuction.buyoutAmount,
        qty = 1,
        maxPrice = maxPrice,
        name = cachedName,
        stage = "ready",
      })
      RenderWatchlist()
      found = true
    else
      if not state.pendingDeal and state.lastDisplayedDealItem == itemID and prevSeen and prevLowest == lowestSeen and prevAvail == 0 then
        TryInstantNextQuery()
        return
      end
      RenderWatchlist()
    end
    if not found then
      ClearPendingDeal(true)
      state.lastDisplayedDealItem = itemID
      if lowestSeen then
        local _, overNm = GetItemVisuals(itemID)
        local diff = math.max(0, lowestSeen - maxPrice)
        local overPct = (maxPrice > 0) and math.floor((diff / maxPrice) * 100 + 0.5) or 0
        dealStripe:SetColorTexture(0.96, 0.45, 0.08, 1)
        dealCard:SetBackdropBorderColor(0.96, 0.45, 0.08, 0.65)
        dealBadge:SetText(DOT_AMBER .. " |cfff59e0bЦЕНА ВЫШЕ ЛИМИТА|r  |cff94a3b8·|r  |cfff8fafc" .. overNm .. "|r")
        dealDelta:SetText("|cff94a3b8Ожидание снижения...|r")
        dealTitle:SetText("|cffcbd5e1Мин. АХ:|r " .. FormatCoins(lowestSeen))
        dealQtyRight:SetText(string.format("|cfff43f5e+%s|r", FormatCoinsPlain(diff)))
        dealMeta:SetText("|cff94a3b8Ваш лимит:|r " .. FormatCoins(maxPrice))
        dealTotalRight:SetText(string.format("|cfff59e0b(+%d%%)|r", overPct))
      else
        dealTitle:SetText("|cff94a3b8Лоты по этому предмету не найдены|r")
        dealDelta:SetText("")
        dealMeta:SetText("")
        dealQtyRight:SetText("")
        dealTotalRight:SetText("")
      end
      TryInstantNextQuery()
    end
  end
end)

SLASH_FOREVERSNIPER1 = "/fsniper"
SLASH_FOREVERSNIPER2 = "/gbroker"
SlashCmdList["FOREVERSNIPER"] = ToggleSniperWindow
