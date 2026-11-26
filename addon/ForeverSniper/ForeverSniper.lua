local ADDON_NAME = ...

-- Keybinding labels for WoW's Key Bindings UI
BINDING_HEADER_FOREVERSNIPER = "Goblin Broker: Forever"
BINDING_NAME_FOREVERSNIPER_BUY = "Купить / Подтвердить лот"
BINDING_NAME_FOREVERSNIPER_SCAN = "Старт / Пауза скана"
BINDING_NAME_FOREVERSNIPER_TOGGLE = "Показать / Скрыть окно"

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

local function RecordTelemetryBuy(itemID, qty, totalCost, name, savedCopper)
  if not itemID then return end
  local t = EnsureTelemetryDB()
  local dk = TodayKey()
  local sv = math.max(0, tonumber(savedCopper) or 0)
  local d = t.days[dk]
  if not d then d = { buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, dips = 0 }; t.days[dk] = d end
  d.buys = (d.buys or 0) + 1
  d.qty = (d.qty or 0) + (qty or 1)
  d.spent = (d.spent or 0) + (totalCost or 0)
  d.saved = (d.saved or 0) + sv
  local it = t.items[itemID]
  if not it then it = { name = name, buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, dips = 0 }; t.items[itemID] = it end
  it.buys = (it.buys or 0) + 1
  it.qty = (it.qty or 0) + (qty or 1)
  it.spent = (it.spent or 0) + (totalCost or 0)
  it.saved = (it.saved or 0) + sv
  if name and not it.name then it.name = name end
  local hb = TouchHourBucket(t, HourKey())
  hb.buys = (hb.buys or 0) + 1
  hb.qty = (hb.qty or 0) + (qty or 1)
  hb.spent = (hb.spent or 0) + (totalCost or 0)
  hb.saved = (hb.saved or 0) + sv
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

local function GetQtyCap(itemID)
  if not itemID or not ForeverSniperDB.qtyLimits then return 0 end
  return tonumber(ForeverSniperDB.qtyLimits[itemID]) or 0
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
f:SetSize(572, 578)
f:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -30, 100)
f:SetFrameStrata("DIALOG")
f:SetToplevel(true)
f:SetClampedToScreen(true)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:SetBackdrop(FLAT_BACKDROP)
f:SetBackdropColor(0.043, 0.067, 0.125, 1) -- #0B1120 Goblin Broker Navy (opaque)
f:SetBackdropBorderColor(0.22, 0.28, 0.40, 1)
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

-- 1. Primary View Tabs (Unified Single Window)
local railSniperBtn = MakeRailButton(railToggleBtn, -6, "Interface\\AddOns\\ForeverSniper\\eye_monocle.tga", "Снайпер")
railSniperBtn:HookScript("OnEnter", function(self)
  if ForeverSniperDB.railExpanded then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Снайпер и список целей", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Мониторинг АХ, добавление и быстрые правки цен", 0.85, 0.90, 0.96)
  GameTooltip:Show()
end)
railSniperBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

local presetsBtn = MakeRailButton(railSniperBtn, -5, "Interface\\AddOns\\ForeverSniper\\rail_presets.tga", "Пресеты")
presetsBtn:HookScript("OnEnter", function(self)
  if ForeverSniperDB.railExpanded then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Пресеты (шаблоны)", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Стартовые [PRO], сохранение и экспорт", 0.85, 0.90, 0.96)
  GameTooltip:Show()
end)
presetsBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

local logBtn = MakeRailButton(presetsBtn, -5, "Interface\\AddOns\\ForeverSniper\\rail_log.tga", "Аналитика")
logBtn:SetColors({ 0.08, 0.12, 0.20, 1 }, { 0.14, 0.20, 0.32, 1 }, { 0.22, 0.29, 0.42, 1 }, { 0.92, 0.70, 0.03 })

local logBadgeCount = logBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
logBadgeCount:SetPoint("TOPRIGHT", 2, 2)
logBadgeCount:SetText("")
logBadgeCount:Hide()

local importBtn = MakeRailButton(logBtn, -5, "Interface\\AddOns\\ForeverSniper\\rail_import.tga", "Импорт")
importBtn:HookScript("OnEnter", function(self)
  if ForeverSniperDB.railExpanded then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Импорт / Экспорт", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Вставить список itemID=цена[:кол-во]", 0.85, 0.90, 0.96)
  GameTooltip:Show()
end)
importBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

local railDiv = toolRail:CreateTexture(nil, "ARTWORK")
railDiv:SetHeight(1)
railDiv:SetPoint("TOPLEFT", importBtn, "BOTTOMLEFT", 4, -6)
railDiv:SetPoint("TOPRIGHT", importBtn, "BOTTOMRIGHT", -4, -6)
railDiv:SetColorTexture(0.20, 0.28, 0.40, 0.85)

-- 2. Utility Toggles (Mini Mode & Sound Alert)
local miniBtn = MakeRailButton(importBtn, -13, "Interface\\AddOns\\ForeverSniper\\rail_mini.tga", "Мини-режим")
miniBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.85, 0.90, 0.96 })
miniBtn:HookScript("OnEnter", function(self)
  if ForeverSniperDB.railExpanded then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(ForeverSniperDB.miniMode and "Полный режим" or "Мини-режим", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Свернуть/развернуть верхнюю панель", 0.85, 0.90, 0.96)
  GameTooltip:Show()
end)
miniBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

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

-- 5. Keybind / Sniper Hotkey Info (pinned to bottom of rail)
local hotkeyBtn = MakeRailButton(nil, nil, "Interface\\AddOns\\ForeverSniper\\rail_hotkey.tga", "Клавиши", true)
hotkeyBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.22, 0.29, 0.42, 1 }, { 0.98, 0.94, 0.54 })
hotkeyBtn:HookScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Горячие клавиши", 0.96, 0.70, 0.03)
  local bk = GetBindingKey and GetBindingKey("FOREVERSNIPER_BUY")
  local sk = GetBindingKey and GetBindingKey("FOREVERSNIPER_SCAN")
  GameTooltip:AddDoubleLine("Купить / Подтв.:", bk or "не задана", 0.85, 0.90, 0.96, 0.98, 0.94, 0.54)
  GameTooltip:AddDoubleLine("Старт / Пауза:", sk or "не задана", 0.85, 0.90, 0.96, 0.85, 0.90, 0.96)
  GameTooltip:AddLine("Назначить: ESC -> Назначение клавиш -> Goblin Broker", 0.60, 0.72, 0.84, true)
  GameTooltip:Show()
end)
hotkeyBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
hotkeyBtn:SetScript("OnClick", function()
  local bk = GetBindingKey and GetBindingKey("FOREVERSNIPER_BUY")
  print("|cfff59e0bGoblin Broker:|r клавиша покупки: |cfffef08a" .. (bk or "не задана") .. "|r (ESC -> Назначение клавиш -> Goblin Broker: Forever).")
end)

-- ============================================================================
-- Unified Top Pane (500x324) hosting Sniper | Presets | Analytics | Import
-- ============================================================================
local topPane = CreateFrame("Frame", nil, f)
topPane:SetPoint("TOPLEFT", toolRail, "TOPRIGHT", 10, 0)
topPane:SetPoint("TOPRIGHT", -12, -60)
topPane:SetHeight(324)

local sniperView = CreateFrame("Frame", nil, topPane)
sniperView:SetAllPoints(topPane)
f.views = { sniper = sniperView }

local wlBar = CreateFrame("Frame", nil, sniperView)
wlBar:SetPoint("TOPLEFT", 0, 0)
wlBar:SetPoint("TOPRIGHT", 0, 0)
wlBar:SetHeight(30)

local addToggleBtn = CreateFlatButton(nil, wlBar, 92, 22, "+ Добавить")
addToggleBtn:SetPoint("LEFT", 0, 0)
addToggleBtn:SetColors({ 0.08, 0.13, 0.22, 1 }, { 0.13, 0.20, 0.32, 1 }, { 0.92, 0.70, 0.03, 0.65 }, { 0.98, 0.88, 0.55 })

local cfgCard = CreateFrame("Frame", nil, sniperView, "BackdropTemplate")
cfgCard:SetPoint("TOPLEFT", wlBar, "BOTTOMLEFT", 0, -2)
cfgCard:SetPoint("TOPRIGHT", wlBar, "BOTTOMRIGHT", 0, -2)
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

local function SetCfgOpen(open) end

local function PreviewDraggedItem()
  if not GetCursorInfo then return false end
  local kind, itemID = GetCursorInfo()
  if kind == "item" and itemID then
    ClearCursor()
    SetCfgOpen(true)
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
-- Section 2: Watchlist Action Bar & Scroll List (inside sniperView)
-- ============================================================================
local trackBtn = CreateFlatButton(nil, wlBar, 134, 22, DOT_GRAY .. " Выбрано: 0")
trackBtn:SetPoint("RIGHT", 0, 0)

local wlSaveBtn = CreateFlatButton(nil, wlBar, 48, 22, "Сохр.")
wlSaveBtn:SetPoint("RIGHT", trackBtn, "LEFT", -4, 0)
wlSaveBtn:SetColors({ 0.02, 0.42, 0.30, 1 }, { 0.04, 0.56, 0.40, 1 }, { 0.06, 0.73, 0.51, 0.9 }, { 1, 1, 1 })
wlSaveBtn:Hide()

local wlRevertBtn = CreateFlatButton(nil, wlBar, 48, 22, "Сброс")
wlRevertBtn:SetPoint("RIGHT", wlSaveBtn, "LEFT", -4, 0)
wlRevertBtn:SetColors({ 0.22, 0.11, 0.14, 1 }, { 0.36, 0.16, 0.20, 1 }, { 0.65, 0.22, 0.28, 0.8 }, { 0.98, 0.84, 0.86 })
wlRevertBtn:Hide()

local wlHeader = wlBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
wlHeader:SetPoint("LEFT", addToggleBtn, "RIGHT", 8, 0)
wlHeader:SetPoint("RIGHT", wlRevertBtn, "LEFT", -6, 0)
wlHeader:SetJustifyH("LEFT")
wlHeader:SetWordWrap(false)
wlHeader:SetText("|cfff59e0bСПИСОК|r")

local function RefreshTrackBtn()
  local total = state.allItems and #state.allItems or 0
  local active = state.queue and #state.queue or 0
  if total == 0 then
    trackBtn:SetLabel(DOT_GRAY .. " Нет целей")
    trackBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.13, 0.17, 0.25, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.65, 0.72, 0.82 })
  elseif active > 1 then
    trackBtn:SetLabel(DOT_GREEN .. string.format(" По кругу: %d/%d", active, total))
    trackBtn:SetColors({ 0.04, 0.16, 0.14, 1 }, { 0.06, 0.24, 0.20, 1 }, { 0.06, 0.73, 0.51, 0.7 }, { 0.85, 1, 0.94 })
  elseif active == 1 then
    trackBtn:SetLabel(DOT_AMBER .. string.format(" Фокус: 1/%d", total))
    trackBtn:SetColors({ 0.16, 0.13, 0.04, 1 }, { 0.24, 0.19, 0.06, 1 }, { 0.92, 0.70, 0.03, 0.65 }, { 0.99, 0.88, 0.45 })
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
  GameTooltip:AddLine("Режим обхода (по моноклям)", 0.96, 0.70, 0.03)
  GameTooltip:AddLine("Если включено 2+ глаза — сканер автоматически", 0.85, 0.90, 0.96, true)
  GameTooltip:AddLine("идёт по кругу. Если 1 — бьёт в одну цель.", 0.85, 0.90, 0.96, true)
  GameTooltip:AddLine("Клик: включить все глаза / фокус на текущем.", 0.60, 0.72, 0.84, true)
  GameTooltip:Show()
end)
trackBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local wlBox = CreateFrame("Frame", nil, sniperView, "BackdropTemplate")
wlBox:SetPoint("TOPLEFT", wlBar, "BOTTOMLEFT", 0, -2)
wlBox:SetPoint("BOTTOMRIGHT", sniperView, "BOTTOMRIGHT", 0, 0)
wlBox:SetBackdrop(FLAT_BACKDROP)
wlBox:SetBackdropColor(0.028, 0.042, 0.082, 1)
wlBox:SetBackdropBorderColor(0.15, 0.21, 0.32, 1)
wlBox:EnableMouse(true)
wlBox:SetScript("OnReceiveDrag", PreviewDraggedItem)

local isCfgOpen = false
SetCfgOpen = function(open)
  isCfgOpen = not not open
  wlBox:ClearAllPoints()
  if isCfgOpen then
    cfgCard:Show()
    wlBox:SetPoint("TOPLEFT", cfgCard, "BOTTOMLEFT", 0, -6)
    addToggleBtn:SetLabel("- Скрыть")
    addToggleBtn:SetColors({ 0.24, 0.18, 0.04, 1 }, { 0.36, 0.26, 0.06, 1 }, { 0.92, 0.70, 0.03, 0.9 }, { 1, 0.94, 0.75 })
  else
    cfgCard:Hide()
    wlBox:SetPoint("TOPLEFT", wlBar, "BOTTOMLEFT", 0, -2)
    addToggleBtn:SetLabel("+ Добавить")
    addToggleBtn:SetColors({ 0.08, 0.13, 0.22, 1 }, { 0.13, 0.20, 0.32, 1 }, { 0.92, 0.70, 0.03, 0.65 }, { 0.98, 0.88, 0.55 })
  end
  wlBox:SetPoint("BOTTOMRIGHT", sniperView, "BOTTOMRIGHT", 0, 0)
end

addToggleBtn:SetScript("OnClick", function()
  SetCfgOpen(not isCfgOpen)
end)

local wlScroll = CreateFrame("ScrollFrame", "ForeverSniperWLScroll", wlBox, "UIPanelScrollFrameTemplate")
wlScroll:SetPoint("TOPLEFT", 4, -4)
wlScroll:SetPoint("BOTTOMRIGHT", -12, 4)

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

local scanBtn = CreateFlatButton("ForeverSniperScanBtn", execRow, 246, 28, "Старт скан")
scanBtn:SetPoint("LEFT", 0, 0)

local skipBtn = CreateFlatButton(nil, execRow, 246, 28, "Сброс лота")
skipBtn:SetPoint("RIGHT", 0, 0)
skipBtn:SetFlatEnabled(false)

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
-- Analytics & Session Log View (Embedded in topPane: 500x324)
-- ============================================================================
local logFrame = CreateFrame("Frame", "ForeverSniperLogFrame", topPane, "BackdropTemplate")
f.views.analytics = logFrame
local RenderLogFrame
local logTab = "session"
local logClearBtn, logExportBtn
local tabSessionBtn, tabItemsBtn, tabDaysBtn, tabHoursBtn

do
logFrame:SetAllPoints(topPane)
logFrame:SetBackdrop(FLAT_BACKDROP)
logFrame:SetBackdropColor(0.036, 0.055, 0.105, 1)
logFrame:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)
logFrame:Hide()

local logTitle = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
logTitle:SetPoint("TOPLEFT", 12, -10)
logTitle:SetText("|cfff59e0bАналитика и лог покупок|r")

logClearBtn = CreateFlatButton(nil, logFrame, 96, 22, "Очистить")
logClearBtn:SetPoint("TOPRIGHT", -12, -8)
logClearBtn:SetColors({ 0.28, 0.10, 0.13, 1 }, { 0.45, 0.14, 0.18, 1 }, { 0.65, 0.22, 0.28, 0.85 }, { 1, 0.86, 0.88 })

logExportBtn = CreateFlatButton(nil, logFrame, 112, 22, "Экспорт отчёта")
logExportBtn:SetPoint("RIGHT", logClearBtn, "LEFT", -6, 0)
logExportBtn:SetColors({ 0.08, 0.22, 0.36, 1 }, { 0.12, 0.30, 0.48, 1 }, { 0.0, 0.71, 0.85, 0.75 }, { 0.9, 0.97, 1 })

tabSessionBtn = CreateFlatButton(nil, logFrame, 114, 22, "Сессия")
tabSessionBtn:SetPoint("TOPLEFT", 12, -38)
tabItemsBtn = CreateFlatButton(nil, logFrame, 114, 22, "По товарам")
tabItemsBtn:SetPoint("LEFT", tabSessionBtn, "RIGHT", 6, 0)
tabDaysBtn = CreateFlatButton(nil, logFrame, 114, 22, "По дням")
tabDaysBtn:SetPoint("LEFT", tabItemsBtn, "RIGHT", 6, 0)
tabHoursBtn = CreateFlatButton(nil, logFrame, 114, 22, "По часам (24ч)")
tabHoursBtn:SetPoint("LEFT", tabDaysBtn, "RIGHT", 6, 0)

-- 3 KPI Summary Cards (Qty, Total Spent, Weighted Avg / Win-Rate)
local function CreateKpiCard(xOffset, w, labelTxt, accentR, accentG, accentB)
  local c = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
  c:SetSize(w, 42)
  c:SetPoint("TOPLEFT", xOffset, -66)
  c:SetBackdrop(FLAT_BACKDROP)
  c:SetBackdropColor(0.067, 0.094, 0.153, 1)
  c:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)

  local top = c:CreateTexture(nil, "ARTWORK")
  top:SetHeight(2)
  top:SetPoint("TOPLEFT", 1, -1)
  top:SetPoint("TOPRIGHT", -1, -1)
  top:SetColorTexture(accentR, accentG, accentB, 0.85)

  local lbl = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lbl:SetPoint("TOPLEFT", 8, -6)
  lbl:SetWidth(w - 16)
  lbl:SetJustifyH("LEFT")
  lbl:SetWordWrap(false)
  lbl:SetText("|cff94a3b8" .. labelTxt .. "|r")
  c.lbl = lbl

  local val = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  val:SetPoint("BOTTOMLEFT", 8, 5)
  val:SetPoint("BOTTOMRIGHT", -8, 5)
  val:SetJustifyH("LEFT")
  val:SetWordWrap(false)
  val:SetText("—")
  c.val = val
  return c
end

local kpiQtyCard   = CreateKpiCard(12,  154, "КУПЛЕНО (СДЕЛОК)", 0.0,  0.71, 0.85)
local kpiSpentCard = CreateKpiCard(172, 154, "ВСЕГО ПОТРАЧЕНО",  0.92, 0.70, 0.03)
local kpiAvgCard   = CreateKpiCard(332, 154, "СРЕДНЯЯ ЗА ШТУКУ", 0.06, 0.73, 0.51)

-- Grouped Per-Item Summary Section (Session tab)
local sumSectionHdr = logFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sumSectionHdr:SetPoint("TOPLEFT", 12, -115)
sumSectionHdr:SetText("|cfff59e0bСВОДКА ПО ПРЕДМЕТАМ|r")

local sumBox = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
sumBox:SetPoint("TOPLEFT", 12, -130)
sumBox:SetPoint("TOPRIGHT", -12, -130)
sumBox:SetHeight(56)
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
sumContent:SetSize(452, 96)
sumScroll:SetScrollChild(sumContent)
local sumRows = {}

local sumEmpty = sumBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sumEmpty:SetPoint("CENTER")
sumEmpty:SetText("|cff64748bНет покупок за текущую сессию|r")

-- Chronological Deal Log Header (Session tab)
local detSectionHdr = logFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
detSectionHdr:SetPoint("TOPLEFT", 12, -193)
detSectionHdr:SetText("|cff94a3b8ДЕТАЛЬНЫЙ ЛОГ СДЕЛОК|r")

local logColHdr = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
logColHdr:SetPoint("TOPLEFT", 12, -208)
logColHdr:SetPoint("TOPRIGHT", -12, -208)
logColHdr:SetHeight(20)
logColHdr:SetBackdrop(FLAT_BACKDROP)
logColHdr:SetBackdropColor(0.067, 0.094, 0.153, 1)
logColHdr:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)

local chTime = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chTime:SetPoint("LEFT", 8, 0); chTime:SetWidth(46); chTime:SetJustifyH("LEFT"); chTime:SetText("|cff94a3b8Время|r")
local chItem = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chItem:SetPoint("LEFT", chTime, "RIGHT", 6, 0); chItem:SetWidth(164); chItem:SetJustifyH("LEFT"); chItem:SetText("|cff94a3b8Предмет|r")
local chQty = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chQty:SetPoint("LEFT", chItem, "RIGHT", 6, 0); chQty:SetWidth(38); chQty:SetJustifyH("RIGHT"); chQty:SetText("|cff94a3b8Шт|r")
local chUnit = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chUnit:SetPoint("LEFT", chQty, "RIGHT", 6, 0); chUnit:SetWidth(76); chUnit:SetJustifyH("RIGHT"); chUnit:SetText("|cff94a3b8За шт|r")
local chTotal = logColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chTotal:SetPoint("RIGHT", -12, 0); chTotal:SetWidth(78); chTotal:SetJustifyH("RIGHT"); chTotal:SetText("|cff94a3b8Итого|r")

local logBox = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
logBox:SetPoint("TOPLEFT", logColHdr, "BOTTOMLEFT", 0, -2)
logBox:SetPoint("BOTTOMRIGHT", -12, 8)
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
logContent:SetSize(452, 290)
logScroll:SetScrollChild(logContent)
local logRows = {}

local logEmpty = logBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
logEmpty:SetPoint("CENTER")
logEmpty:SetText("|cff64748bСделки появятся здесь автоматически после выкупа лотов|r")

-- Persistent All-Time / Daily Analytics Table (По товарам / По дням / По часам tabs)
local anaColHdr = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
anaColHdr:SetPoint("TOPLEFT", 12, -115)
anaColHdr:SetPoint("TOPRIGHT", -12, -115)
anaColHdr:SetHeight(20)
anaColHdr:SetBackdrop(FLAT_BACKDROP)
anaColHdr:SetBackdropColor(0.067, 0.094, 0.153, 1)
anaColHdr:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)
anaColHdr:Hide()

local ac1 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac1:SetPoint("LEFT", 10, 0); ac1:SetWidth(114); ac1:SetJustifyH("LEFT")
local ac2 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac2:SetPoint("LEFT", ac1, "RIGHT", 4, 0); ac2:SetWidth(68); ac2:SetJustifyH("RIGHT")
local ac3 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac3:SetPoint("LEFT", ac2, "RIGHT", 4, 0); ac3:SetWidth(76); ac3:SetJustifyH("RIGHT")
local ac4 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac4:SetPoint("LEFT", ac3, "RIGHT", 4, 0); ac4:SetWidth(68); ac4:SetJustifyH("RIGHT")
local ac5 = anaColHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ac5:SetPoint("RIGHT", -14, 0); ac5:SetWidth(84); ac5:SetJustifyH("RIGHT")

local anaBox = CreateFrame("Frame", nil, logFrame, "BackdropTemplate")
anaBox:SetPoint("TOPLEFT", anaColHdr, "BOTTOMLEFT", 0, -2)
anaBox:SetPoint("BOTTOMRIGHT", -12, 8)
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
anaContent:SetSize(452, 380)
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
  logClearBtn:SetLabel(logTab == "session" and "Очистить" or "Сбросить базу")
end

local function GetAnaRow(i)
  local row = anaRows[i]
  if not row then
    row = CreateFrame("Frame", nil, anaContent, "BackdropTemplate")
    row:SetSize(448, 24); row:SetBackdrop(FLAT_BACKDROP); row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)
    row.barFill = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    row.barFill:SetPoint("TOPLEFT", 1, -1)
    row.barFill:SetPoint("BOTTOMLEFT", 1, 1)
    row.barFill:SetColorTexture(0.06, 0.73, 0.51, 0.22)
    row.barFill:Hide()
    row.ico = row:CreateTexture(nil, "ARTWORK"); row.ico:SetSize(16, 16); row.ico:SetPoint("LEFT", 6, 0); row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.c1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c1:SetJustifyH("LEFT"); row.c1:SetWordWrap(false)
    row.c2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c2:SetPoint("LEFT", row.c1, "RIGHT", 4, 0); row.c2:SetWidth(68); row.c2:SetJustifyH("RIGHT"); row.c2:SetWordWrap(false)
    row.c3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c3:SetPoint("LEFT", row.c2, "RIGHT", 4, 0); row.c3:SetWidth(76); row.c3:SetJustifyH("RIGHT"); row.c3:SetWordWrap(false)
    row.c4 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c4:SetPoint("LEFT", row.c3, "RIGHT", 4, 0); row.c4:SetWidth(68); row.c4:SetJustifyH("RIGHT"); row.c4:SetWordWrap(false)
    row.c5 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.c5:SetPoint("RIGHT", -6, 0); row.c5:SetWidth(84); row.c5:SetJustifyH("RIGHT"); row.c5:SetWordWrap(false)
    anaRows[i] = row
  end
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
  end

  if not isSession then
    local t = EnsureTelemetryDB()
    local totBuys, totQty, totSpent, totSaved, totMissed, totDips = 0, 0, 0, 0, 0, 0
    for _, d in pairs(t.days or {}) do
      totBuys = totBuys + (d.buys or 0)
      totQty = totQty + (d.qty or 0)
      totSpent = totSpent + (d.spent or 0)
      totSaved = totSaved + (d.saved or 0)
      totMissed = totMissed + (d.missed or 0)
      totDips = totDips + (d.dips or 0)
    end
    kpiQtyCard.lbl:SetText("|cff94a3b8КУПЛЕНО / СРЫВОВ|r")
    kpiQtyCard.val:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d / %d)|r", totQty, totBuys, totMissed))
    kpiSpentCard.lbl:SetText(totSaved > 0 and "|cff10b981ЭКОНОМИЯ ОТ ЛИМИТА|r" or "|cff94a3b8ПОТРАЧЕНО ВСЕГО|r")
    kpiSpentCard.val:SetText(totSaved > 0 and FormatCoins(totSaved) or (totSpent > 0 and FormatCoins(totSpent) or "|cff64748b0|r" .. ICON_COPPER))
    kpiAvgCard.lbl:SetText("|cff94a3b8WIN-RATE / ПРОСАДОК|r")
    kpiAvgCard.val:SetText(string.format("%s |cff64748b(%d)|r", FormatWinRate(totBuys, totMissed), totDips))

    for _, r in ipairs(anaRows) do r:Hide() end
    local y = 0
    if logTab == "items" then
      ac1:SetText("|cff94a3b8Предмет|r"); ac2:SetText("|cff94a3b8Куплено|r"); ac3:SetText("|cff94a3b8Срывы / WR|r")
      ac4:SetText("|cff94a3b8Просадки|r"); ac5:SetText("|cff94a3b8Ср. цена|r")
      local keys = {}
      for id in pairs(t.items or {}) do table.insert(keys, id) end
      table.sort(keys, function(a, b)
        local ia, ib = t.items[a], t.items[b]
        if (ia.spent or 0) ~= (ib.spent or 0) then return (ia.spent or 0) > (ib.spent or 0) end
        return (ia.dips or 0) > (ib.dips or 0)
      end)
      for i, id in ipairs(keys) do
        local it = t.items[id]
        local row = GetAnaRow(i)
        local icon, nm, r, g, b = GetItemVisuals(id)
        local avgU = ((it.qty or 0) > 0) and math.floor((it.spent or 0) / it.qty) or 0
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
        row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
        row.barFill:Hide()
        row.ico:Show(); row.ico:SetTexture(icon)
        row.c1:ClearAllPoints(); row.c1:SetPoint("LEFT", row.ico, "RIGHT", 6, 0); row.c1:SetWidth(124)
        row.c1:SetText(it.name or nm); row.c1:SetTextColor(r, g, b)
        row.c2:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d)|r", it.qty or 0, it.buys or 0))
        row.c3:SetText(string.format("|cff64748b%d /|r %s", it.missed or 0, FormatWinRate(it.buys, it.missed)))
        row.c4:SetText(string.format("|cfff59e0b%d|r", it.dips or 0))
        row.c5:SetText(avgU > 0 and FormatCoins(avgU) or (it.minDip and FormatCoins(it.minDip) or "|cff64748b—|r"))
        row:Show(); y = y + 26
      end
    elseif logTab == "days" then
      ac1:SetText("|cff94a3b8Дата|r"); ac2:SetText("|cff94a3b8Сделок|r"); ac3:SetText("|cff94a3b8Срывы / WR|r")
      ac4:SetText("|cff94a3b8Просадок|r"); ac5:SetText("|cff94a3b8Потрачено|r")
      local days = {}
      for dk in pairs(t.days or {}) do table.insert(days, dk) end
      table.sort(days, function(a, b) return a > b end)
      for i, dk in ipairs(days) do
        local d = t.days[dk]
        local row = GetAnaRow(i)
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
        row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
        row.barFill:Hide()
        row.ico:Hide()
        row.c1:ClearAllPoints(); row.c1:SetPoint("LEFT", 8, 0); row.c1:SetWidth(146)
        row.c1:SetText(dk); row.c1:SetTextColor(0.92, 0.96, 1)
        row.c2:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d)|r", d.qty or 0, d.buys or 0))
        row.c3:SetText(string.format("|cff64748b%d /|r %s", d.missed or 0, FormatWinRate(d.buys, d.missed)))
        row.c4:SetText(string.format("|cfff59e0b%d|r", d.dips or 0))
        row.c5:SetText((d.spent or 0) > 0 and FormatCoins(d.spent) or "|cff64748b—|r")
        row:Show(); y = y + 26
      end
    else
      ac1:SetText("|cff94a3b8Час (24ч)|r"); ac2:SetText("|cff94a3b8Куплено|r"); ac3:SetText("|cff94a3b8Срывы / WR|r")
      ac4:SetText("|cff94a3b8Просадок|r"); ac5:SetText("|cff94a3b8Потрачено|r")
      local maxAct = 1
      for hr = 0, 23 do
        local h = t.hours and t.hours[hr]
        local act = h and ((h.dips or 0) + (h.buys or 0) + (h.missed or 0)) or 0
        if act > maxAct then maxAct = act end
      end
      for hr = 0, 23 do
        local i = hr + 1
        local h = (t.hours and t.hours[hr]) or { buys = 0, qty = 0, spent = 0, missed = 0, dips = 0 }
        local act = (h.dips or 0) + (h.buys or 0) + (h.missed or 0)
        local row = GetAnaRow(i)
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
        row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
        row.ico:Hide()
        if act > 0 then
          row.barFill:SetWidth(math.max(6, math.floor(514 * (act / maxAct))))
          if act == maxAct then
            row.barFill:SetColorTexture(0.92, 0.70, 0.03, 0.24)
          else
            row.barFill:SetColorTexture(0.06, 0.73, 0.51, 0.18)
          end
          row.barFill:Show()
        else
          row.barFill:Hide()
        end
        row.c1:ClearAllPoints(); row.c1:SetPoint("LEFT", 8, 0); row.c1:SetWidth(146)
        row.c1:SetText(string.format("%02d:00 - %02d:59", hr, hr))
        row.c1:SetTextColor(act > 0 and 0.95 or 0.45, act > 0 and 0.98 or 0.52, act > 0 and 1.0 or 0.62)
        row.c2:SetText((h.buys or 0) > 0 and string.format("|cffffffff%d шт|r |cff64748b(%d)|r", h.qty or 0, h.buys or 0) or "|cff4755690|r")
        row.c3:SetText(string.format("|cff64748b%d /|r %s", h.missed or 0, FormatWinRate(h.buys, h.missed)))
        row.c4:SetText((h.dips or 0) > 0 and string.format("|cfff59e0b%d|r", h.dips) or "|cff4755690|r")
        row.c5:SetText((h.spent or 0) > 0 and FormatCoins(h.spent) or "|cff475569—|r")
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
  local overallAvg = (totalQty > 0) and math.floor(totalCopper / totalQty) or 0

  kpiQtyCard.val:SetText(string.format("|cffffffff%d шт|r |cff64748b(%d)|r", totalQty, #hist))
  kpiSpentCard.val:SetText(totalCopper > 0 and FormatCoins(totalCopper) or "|cff64748b0|r" .. ICON_COPPER)
  kpiAvgCard.val:SetText(overallAvg > 0 and FormatCoins(overallAvg) or "|cff64748b—|r")

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
      srow:SetSize(518, 22)
      srow:SetBackdrop(FLAT_BACKDROP)
      srow:SetBackdropColor(0.055, 0.078, 0.135, 1)
      srow:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.35)

      srow.ico = srow:CreateTexture(nil, "ARTWORK")
      srow.ico:SetSize(16, 16); srow.ico:SetPoint("LEFT", 6, 0)
      srow.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

      srow.nm = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      srow.nm:SetPoint("LEFT", srow.ico, "RIGHT", 6, 0); srow.nm:SetWidth(200); srow.nm:SetJustifyH("LEFT"); srow.nm:SetWordWrap(false)

      srow.q = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      srow.q:SetPoint("LEFT", srow.nm, "RIGHT", 6, 0); srow.q:SetWidth(68); srow.q:SetJustifyH("RIGHT")

      srow.avg = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      srow.avg:SetPoint("LEFT", srow.q, "RIGHT", 8, 0); srow.avg:SetWidth(104); srow.avg:SetJustifyH("RIGHT")

      srow.tot = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      srow.tot:SetPoint("RIGHT", -6, 0); srow.tot:SetWidth(90); srow.tot:SetJustifyH("RIGHT")

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
      row:SetSize(518, rowH)
      row:SetBackdrop(FLAT_BACKDROP)
      row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)

      row.t = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.t:SetPoint("LEFT", 6, 0); row.t:SetWidth(52); row.t:SetJustifyH("LEFT")

      row.ico = row:CreateTexture(nil, "ARTWORK")
      row.ico:SetSize(16, 16); row.ico:SetPoint("LEFT", row.t, "RIGHT", 6, 0)
      row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

      row.nm = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.nm:SetPoint("LEFT", row.ico, "RIGHT", 6, 0); row.nm:SetWidth(202); row.nm:SetJustifyH("LEFT"); row.nm:SetWordWrap(false)

      row.q = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.q:SetPoint("LEFT", row.nm, "RIGHT", 6, 0); row.q:SetWidth(44); row.q:SetJustifyH("RIGHT"); row.q:SetWordWrap(false)

      row.u = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.u:SetPoint("LEFT", row.q, "RIGHT", 6, 0); row.u:SetWidth(80); row.u:SetJustifyH("RIGHT"); row.u:SetWordWrap(false)

      row.tot = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.tot:SetPoint("RIGHT", -6, 0); row.tot:SetWidth(82); row.tot:SetJustifyH("RIGHT"); row.tot:SetWordWrap(false)

      logRows[idx] = row
    end

    local icon, nm, r, g, b = GetItemVisuals(h.itemID)
    local qty = math.max(1, tonumber(h.qty) or 1)
    local total = tonumber(h.totalCost) or 0
    local unitAvg = math.floor(total / qty)

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
    y = y + rowH + 2
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
  RecordTelemetryBuy(att.itemID, qty, total, att.name, saved)
  sb.lastOutcome = string.format(DOT_GREEN .. " |cff10b981Куплено:|r x%d по %s/шт (%s)", qty, FormatCoinsPlain(unitAvg), FormatCoinsPlain(total))
  RefreshSessionBar()

  -- Decrement remaining buy quantity quota (e.g. 100 - 10 = 90)
  local oldCap = GetQtyCap(att.itemID)
  if oldCap > 0 then
    local remaining = math.max(0, oldCap - qty)
    if remaining > 0 then
      ForeverSniperDB.qtyLimits[att.itemID] = remaining
      if att.itemID == ForeverSniperDB.selectedID then
        maxQtyLimitInput:SetText(tostring(remaining))
      end
      UpdateStatus()
    else
      -- Keep item in watchlist & selected so user doesn't lose their setup; just pause auto-scan
      ForeverSniperDB.qtyLimits[att.itemID] = nil
      if att.itemID == ForeverSniperDB.selectedID then
        maxQtyLimitInput:SetText("")
      end
      ForeverSniperDB.autoScan = false
      UpdateStatus()
      dealBadge:SetText(DOT_GREEN .. " |cff10b981ЛИМИТ ВЫКУПЛЕН - СКАН НА ПАУЗЕ|r")
      print(string.format("|cff10b981Goblin Broker:|r лимит по %s выкуплен (скан поставлен на паузу).", att.name or ("Item #" .. tostring(att.itemID))))
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

logExportBtn:SetScript("OnClick", function()
  local t = EnsureTelemetryDB()
  local lines = { "# Goblin Broker: Forever Telemetry (" .. TodayKey() .. ")" }
  for dk, d in pairs(t.days or {}) do
    table.insert(lines, string.format("DAY;%s;buys=%d;qty=%d;missed=%d;dips=%d;spent=%d;saved=%d",
      dk, d.buys or 0, d.qty or 0, d.missed or 0, d.dips or 0, d.spent or 0, d.saved or 0))
  end
  for id, it in pairs(t.items or {}) do
    table.insert(lines, string.format("ITEM;%d;%s;buys=%d;qty=%d;missed=%d;dips=%d;spent=%d;minDip=%d",
      id, it.name or "", it.buys or 0, it.qty or 0, it.missed or 0, it.dips or 0, it.spent or 0, it.minDip or 0))
  end
  OpenExportModal("Экспорт аналитики", table.concat(lines, "\n"))
  print("|cff06b6d4Goblin Broker:|r экспорт аналитики готов — скопируйте Ctrl+C.")
end)

logClearBtn:SetScript("OnClick", function()
  if logTab == "session" then
    ClearSessionHistory()
  else
    ForeverSniperDB.telemetry = { days = {}, items = {}, hours = {} }
    RenderLogFrame()
    print("|cff94a3b8Goblin Broker:|r аналитика по дням, часам и товарам сброшена.")
  end
end)
local activeView = "sniper"
local ApplyMiniMode
local function SetActiveView(name)
  activeView = name or "sniper"
  if ForeverSniperDB.miniMode then
    ForeverSniperDB.miniMode = false
    if ApplyMiniMode then ApplyMiniMode() end
  end
  for k, v in pairs(f.views) do
    if k == activeView then v:Show() else v:Hide() end
  end
  local function StyleViewBtn(btn, isOn)
    if isOn then
      btn:SetColors({ 0.04, 0.16, 0.14, 1 }, { 0.06, 0.24, 0.20, 1 }, { 0.06, 0.73, 0.51, 0.9 }, { 0.85, 1, 0.94 })
    else
      btn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.78, 0.84, 0.92 })
    end
  end
  StyleViewBtn(railSniperBtn, activeView == "sniper")
  StyleViewBtn(presetsBtn, activeView == "presets")
  StyleViewBtn(logBtn, activeView == "analytics")
  StyleViewBtn(importBtn, activeView == "import")
  if activeView == "analytics" and RenderLogFrame then RenderLogFrame() end
end

railSniperBtn:SetScript("OnClick", function() SetActiveView("sniper") end)
logBtn:SetScript("OnClick", function()
  if activeView == "analytics" and not ForeverSniperDB.miniMode then
    SetActiveView("sniper")
  else
    SetActiveView("analytics")
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

ApplyMiniMode = function()
  local isMini = not not ForeverSniperDB.miniMode
  ApplyRailState()
  if isMini then
    topPane:Hide()
    dealCard:ClearAllPoints()
    dealCard:SetPoint("TOPLEFT", toolRail, "TOPRIGHT", 10, -18)
    dealCard:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -78)
    f.miniContextText:Show()
    f:SetHeight(262)
    miniBtn:SetColors({ 0.04, 0.16, 0.14, 1 }, { 0.06, 0.24, 0.20, 1 }, { 0.06, 0.73, 0.51, 0.8 }, { 0.85, 1, 0.94 })
    miniBtn.railText:SetText("|cff10b981Полный вид|r")
  else
    topPane:Show()
    for k, v in pairs(f.views) do
      if k == activeView then v:Show() else v:Hide() end
    end
    f.miniContextText:Hide()
    dealCard:ClearAllPoints()
    dealCard:SetPoint("TOPLEFT", topPane, "BOTTOMLEFT", 0, -10)
    dealCard:SetPoint("TOPRIGHT", topPane, "BOTTOMRIGHT", 0, -10)
    f:SetHeight(578)
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
    local cap = GetQtyCap(sel)
    maxQtyLimitInput:SetText(cap > 0 and tostring(cap) or "")
  else
    idInput:SetText("")
    goldInput:SetText("")
    silverInput:SetText("")
    copperInput:SetText("")
    maxQtyLimitInput:SetText("")
  end
end

local ClearPendingDeal
local UpdateStatus

local function RenderWatchlist()
  if ForeverSniperDB.miniMode or not f:IsShown() then return end
  for _, row in ipairs(wlRows) do
    row:Hide()
  end

  local allItems = state.allItems or {}
  if wlBox.emptyPanel then
    if #allItems == 0 then wlBox.emptyPanel:Show() else wlBox.emptyPanel:Hide() end
  end
  local needScroll = (#allItems > 6)
  local rowW = needScroll and 480 or 490
  wlContent:SetWidth(rowW)

  local rowH = 26
  local y = 0
  for i, itemID in ipairs(allItems) do
    local row = wlRows[i]
    if not row then
      row = CreateFrame("Button", nil, wlContent, "BackdropTemplate")
      row:SetSize(rowW, rowH)
      row:SetBackdrop(FLAT_BACKDROP)

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
      row.name:SetWidth(108)
      row.name:SetJustifyH("LEFT")
      row.name:SetWordWrap(false)

      row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.price:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
      row.price:SetWidth(64)
      row.price:SetJustifyH("LEFT")
      row.price:SetWordWrap(false)

      row.pDn = CreateFlatButton(nil, row, 26, 18, "-5%")
      row.pDn:SetPoint("LEFT", row.price, "RIGHT", 2, 0)
      row.pDn:SetColors({ 0.16, 0.09, 0.11, 1 }, { 0.34, 0.14, 0.18, 1 }, { 0.45, 0.18, 0.22, 0.7 }, { 0.95, 0.72, 0.76 })

      row.pUp = CreateFlatButton(nil, row, 26, 18, "+5%")
      row.pUp:SetPoint("LEFT", row.pDn, "RIGHT", 2, 0)
      row.pUp:SetColors({ 0.05, 0.16, 0.13, 1 }, { 0.08, 0.30, 0.22, 1 }, { 0.06, 0.73, 0.51, 0.7 }, { 0.72, 0.96, 0.86 })

      row.live = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.live:SetPoint("LEFT", row.pUp, "RIGHT", 4, 0)
      row.live:SetJustifyH("LEFT")
      row.live:SetWordWrap(false)

      row.cap = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.cap:SetPoint("RIGHT", -28, 0)
      row.cap:SetWidth(44)
      row.cap:SetJustifyH("RIGHT")
      row.cap:SetWordWrap(false)
      row.live:SetPoint("RIGHT", row.cap, "LEFT", -4, 0)

      row.del = CreateFlatButton(nil, row, 20, 20, "x")
      row.del:SetPoint("RIGHT", -4, 0)
      row.del:SetColors({ 0.12, 0.15, 0.22, 1 }, { 0.55, 0.14, 0.18, 1 }, { 0.20, 0.26, 0.36, 1 }, { 0.75, 0.80, 0.88 })

      wlRows[i] = row
    end

    local icon, nm, r, g, b = GetItemVisuals(itemID)
    local isSel = (itemID == ForeverSniperDB.selectedID)
    local isTracked = IsItemTracked(itemID)
    local lim = ForeverSniperDB.watchlist[itemID] or 0
    local cap = GetQtyCap(itemID)

    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetWidth(rowW)
    row.eye.itemID = itemID
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
    row.price:SetText(FormatCoins(lim))
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
    row.cap:SetText(cap > 0 and ("|cfff59e0b<= " .. cap .. "|r") or "|cff64748bвсе|r")

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

    row:SetScript("OnClick", function()
      ForeverSniperDB.selectedID = itemID
      SyncInputsFromSelected()
      ClearPendingDeal()
      UpdateStatus()
    end)

    row.eye:SetScript("OnClick", function()
      ForeverSniperDB.tracked = ForeverSniperDB.tracked or {}
      local nextState = not IsItemTracked(itemID)
      ForeverSniperDB.tracked[itemID] = nextState
      if not nextState and ForeverSniperDB.selectedID == itemID then
        ForeverSniperDB.selectedID = nil
      elseif nextState then
        ForeverSniperDB.selectedID = itemID
      end
      if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
      ClearPendingDeal()
      UpdateStatus()
      SyncInputsFromSelected()
    end)

    row.pDn:SetScript("OnClick", function()
      local cur = ForeverSniperDB.watchlist[itemID] or 0
      if cur <= 0 then return end
      local nxt = math.max(1, math.floor(cur * 0.95 + 0.5))
      if nxt == cur and cur > 1 then nxt = cur - 1 end
      ForeverSniperDB.watchlist[itemID] = nxt
      ForeverSniperDB.selectedID = itemID
      if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
      ClearPendingDeal()
      UpdateStatus()
      SyncInputsFromSelected()
    end)

    row.pUp:SetScript("OnClick", function()
      local cur = ForeverSniperDB.watchlist[itemID] or 0
      if cur <= 0 then return end
      local nxt = math.max(cur + 1, math.floor(cur * 1.05 + 0.5))
      ForeverSniperDB.watchlist[itemID] = nxt
      ForeverSniperDB.selectedID = itemID
      if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
      ClearPendingDeal()
      UpdateStatus()
      SyncInputsFromSelected()
    end)

    row.del:SetScript("OnClick", function()
      ForeverSniperDB.watchlist[itemID] = nil
      if ForeverSniperDB.qtyLimits then ForeverSniperDB.qtyLimits[itemID] = nil end
      if ForeverSniperDB.tracked then ForeverSniperDB.tracked[itemID] = nil end
      if ForeverSniperDB.selectedID == itemID then
        ForeverSniperDB.selectedID = nil
      end
      if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
      ClearPendingDeal()
      UpdateStatus()
      SyncInputsFromSelected()
    end)

    row:Show()
    y = y + rowH + 2
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
    scanBtn:SetColors({ 0.30, 0.16, 0.06, 1 }, { 0.44, 0.22, 0.08, 1 }, { 0.96, 0.62, 0.04, 0.75 }, { 1, 0.94, 0.80 })
  else
    scanBtn:SetLabel("Старт скан")
    scanBtn:SetColors({ 0.08, 0.13, 0.21, 1 }, { 0.12, 0.19, 0.30, 1 }, { 0.06, 0.73, 0.51, 0.55 }, { 0.86, 0.96, 0.92 })
  end

  local sel = ForeverSniperDB.selectedID
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

  if ForeverSniperDB.activePreset and ForeverSniperDB.presets and ForeverSniperDB.presets[ForeverSniperDB.activePreset] then
    local dirtyMark = ForeverSniperDB.presetDirty and " |cfff59e0b*|r" or ""
    wlHeader:SetText(string.format("|cff10b981%s|r%s", ForeverSniperDB.activePreset, dirtyMark))
    if ForeverSniperDB.presetDirty then
      wlSaveBtn:Show()
      wlRevertBtn:Show()
    else
      wlSaveBtn:Hide()
      wlRevertBtn:Hide()
    end
  else
    ForeverSniperDB.presetDirty = false
    wlSaveBtn:Hide()
    wlRevertBtn:Hide()
    wlHeader:SetText("|cfff59e0bСПИСОК|r")
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

ClearPendingDeal = function(keepLowestMsg, skipCancel)
  local prev = state.pendingDeal
  if not skipCancel and prev and prev.isCommodity and prev.stage == "confirm" then
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
  local deal = state.pendingDeal
  if not deal or not state.ahOpen then return end

  if mouseButton == "RightButton" then
    ClearPendingDeal()
    return
  end

  local cap = GetQtyCap(deal.itemID)
  local effectiveMax = (cap > 0) and math.min(deal.qty or 1, cap) or (deal.qty or 1)
  local chosenQty = math.max(1, effectiveMax)

  if not deal.isCommodity then
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
    -- Wait for server COMMODITY_PRICE_UPDATED quote (~50ms), with 0.35s lag fallback
    if not deal.quoteReady and (GetTime() - (deal.confirmAt or 0)) < 0.35 then
      dealBadge:SetText(DOT_AMBER .. " |cfff59e0bЖДЁМ ОТВЕТ СЕРВЕРА...|r")
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
    ClearPendingDeal(false, true)
  end
end

function ForeverSniper_OnBuyHotkey()
  ExecuteBuyAction("LeftButton")
end

buyBtn:SetScript("OnClick", function(_, mouseButton)
  ExecuteBuyAction(mouseButton)
end)

skipBtn:SetScript("OnClick", function()
  ClearPendingDeal()
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
  ForeverSniperDB.selectedID = id
  if SyncActivePresetSnapshot then SyncActivePresetSnapshot() end
  idInput:ClearFocus()
  goldInput:ClearFocus()
  silverInput:ClearFocus()
  copperInput:ClearFocus()
  maxQtyLimitInput:ClearFocus()
  ClearPendingDeal()
  SetCfgOpen(false)
  UpdateStatus()
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
-- Import / Export View (Embedded in topPane: 500x324)
-- ============================================================================
local imp = CreateFrame("Frame", "ForeverSniperImportFrame", topPane, "BackdropTemplate")
f.views.import = imp
imp:SetAllPoints(topPane)
imp:SetBackdrop(FLAT_BACKDROP)
imp:SetBackdropColor(0.036, 0.055, 0.105, 1)
imp:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)
imp:Hide()

local impTitle = imp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
impTitle:SetPoint("TOPLEFT", 12, -10)
impTitle:SetText("|cfff59e0bИмпорт из Goblin Broker: Forever|r")

local impBoxBg = CreateFrame("Frame", nil, imp, "BackdropTemplate")
impBoxBg:SetPoint("TOPLEFT", 12, -34)
impBoxBg:SetPoint("BOTTOMRIGHT", -12, 46)
impBoxBg:SetBackdrop(FLAT_BACKDROP)
impBoxBg:SetBackdropColor(0.025, 0.038, 0.070, 1)
impBoxBg:SetBackdropBorderColor(0.18, 0.24, 0.35, 1)

local scroll = CreateFrame("ScrollFrame", nil, impBoxBg, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 8, -8)
scroll:SetPoint("BOTTOMRIGHT", -28, 8)

local editBox = CreateFrame("EditBox", nil, scroll)
editBox:SetMultiLine(true)
editBox:SetFontObject("GameFontHighlightSmall")
editBox:SetWidth(432)
editBox:SetAutoFocus(true)
editBox:SetScript("OnEscapePressed", function() SetActiveView("sniper") end)
scroll:SetScrollChild(editBox)

local impReplace = CreateFlatButton(nil, imp, 132, 28, "Заменить всё")
impReplace:SetPoint("BOTTOMLEFT", 12, 10)
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
  elseif not ForeverSniperDB.selectedID then
    ForeverSniperDB.selectedID = firstID
  end
  if not replaceAll and SyncActivePresetSnapshot then
    SyncActivePresetSnapshot()
  end
  SetActiveView("sniper")
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
  impCancel:SetLabel("Назад")
  editBox:SetText("")
  SetActiveView("import")
  editBox:SetFocus()
end

local function OpenExportModal(titleText, bodyText)
  impTitle:SetText("|cff06b6d4" .. (titleText or "Экспорт (Ctrl+C)") .. "|r")
  impReplace:Hide()
  impAdd:Hide()
  impCancel:ClearAllPoints()
  impCancel:SetPoint("BOTTOMRIGHT", -12, 10)
  impCancel:SetLabel("Назад")
  editBox:SetText(bodyText or "")
  editBox:HighlightText()
  SetActiveView("import")
  editBox:SetFocus()
end

impCancel:SetScript("OnClick", function() SetActiveView("sniper") end)
impReplace:SetScript("OnClick", function() RunImport(true) end)
impAdd:SetScript("OnClick", function() RunImport(false) end)

importBtn:SetScript("OnClick", function()
  if activeView == "import" and not ForeverSniperDB.miniMode then
    SetActiveView("sniper")
  else
    OpenImportModal()
  end
end)

-- ============================================================================
-- Saved Presets View (Embedded in topPane: 500x324)
-- ============================================================================
local pre = CreateFrame("Frame", "ForeverSniperPresetsFrame", topPane, "BackdropTemplate")
f.views.presets = pre
pre:SetAllPoints(topPane)
pre:SetBackdrop(FLAT_BACKDROP)
pre:SetBackdropColor(0.036, 0.055, 0.105, 1)
pre:SetBackdropBorderColor(0.16, 0.22, 0.34, 1)
pre:Hide()

local preTitle = pre:CreateFontString(nil, "OVERLAY", "GameFontNormal")
preTitle:SetPoint("TOPLEFT", 12, -10)
preTitle:SetText("|cfff59e0bПресеты списков отслеживания|r")

local preExitBtn = CreateFlatButton(nil, pre, 126, 22, "Выйти из шаблона")
preExitBtn:SetPoint("TOPRIGHT", -12, -8)
preExitBtn:SetColors({ 0.14, 0.17, 0.25, 1 }, { 0.24, 0.28, 0.38, 1 }, { 0.28, 0.34, 0.46, 1 }, { 0.85, 0.90, 0.96 })

local preNameInput = CreateFrame("EditBox", nil, pre, "BackdropTemplate")
StyleFlatBox(preNameInput, 196, 26)
preNameInput:SetPoint("TOPLEFT", 12, -38)

local prePlaceholder = preNameInput:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
prePlaceholder:SetPoint("LEFT", 8, 0)
prePlaceholder:SetText("|cff64748bНазвание шаблона...|r")
preNameInput:HookScript("OnTextChanged", function(self)
  if (self:GetText() or "") == "" then prePlaceholder:Show() else prePlaceholder:Hide() end
end)

local preSaveBtn = CreateFlatButton(nil, pre, 134, 26, "Сохранить")
preSaveBtn:SetPoint("LEFT", preNameInput, "RIGHT", 6, 0)
preSaveBtn:SetColors({ 0.02, 0.48, 0.34, 1 }, { 0.04, 0.62, 0.44, 1 }, { 0.06, 0.73, 0.51, 0.9 }, { 1, 1, 1 })

local preNewBtn = CreateFlatButton(nil, pre, 134, 26, "+ Новый")
preNewBtn:SetPoint("LEFT", preSaveBtn, "RIGHT", 6, 0)
preNewBtn:SetColors({ 0.08, 0.22, 0.36, 1 }, { 0.12, 0.30, 0.48, 1 }, { 0.0, 0.71, 0.85, 0.75 }, { 0.9, 0.97, 1 })

local preListBox = CreateFrame("Frame", nil, pre, "BackdropTemplate")
preListBox:SetPoint("TOPLEFT", 12, -72)
preListBox:SetPoint("BOTTOMRIGHT", -12, 40)
preListBox:SetBackdrop(FLAT_BACKDROP)
preListBox:SetBackdropColor(0.028, 0.042, 0.082, 1)
preListBox:SetBackdropBorderColor(0.15, 0.21, 0.32, 1)

local preScroll = CreateFrame("ScrollFrame", "ForeverSniperPreScroll", preListBox, "UIPanelScrollFrameTemplate")
preScroll:SetPoint("TOPLEFT", 4, -4)
preScroll:SetPoint("BOTTOMRIGHT", -14, 4)

local preScrollBar = _G["ForeverSniperPreScrollScrollBar"]
if preScrollBar then
  local up = _G["ForeverSniperPreScrollScrollBarScrollUpButton"]
  local dn = _G["ForeverSniperPreScrollScrollBarScrollDownButton"]
  if up then up:Hide(); up:SetSize(1, 1) end
  if dn then dn:Hide(); dn:SetSize(1, 1) end
  local thumb = preScrollBar:GetThumbTexture()
  if thumb then
    thumb:SetColorTexture(0.24, 0.32, 0.46, 0.85)
    thumb:SetWidth(4)
  end
end

local preContent = CreateFrame("Frame", nil, preScroll)
preContent:SetSize(452, 200)
preScroll:SetScrollChild(preContent)
local preRows = {}

local preStarterBtn = CreateFlatButton(nil, pre, 142, 24, "Стартовые [PRO]")
preStarterBtn:SetPoint("BOTTOMLEFT", 12, 10)
preStarterBtn:SetColors({ 0.16, 0.13, 0.04, 1 }, { 0.28, 0.21, 0.06, 1 }, { 0.92, 0.70, 0.03, 0.85 }, { 0.99, 0.88, 0.45 })

local preHint = pre:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
preHint:SetPoint("LEFT", preStarterBtn, "RIGHT", 10, 0)
preHint:SetText("|cff64748b5 наборов под рынок Forever (без перезаписи своих)|r")

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

local preEmptyText = preListBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
preEmptyText:SetPoint("CENTER")
preEmptyText:SetWidth(330)
preEmptyText:SetJustifyH("CENTER")
preEmptyText:SetText("|cff64748bНет сохранённых шаблонов.\nВведите название выше и нажмите «+ Новый» или «Сохранить».|r")
preEmptyText:Hide()

local function CopyTableShallow(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do out[k] = v end
  return out
end

local function SyncActivePresetSnapshot()
  local ap = ForeverSniperDB.activePreset
  if ap and ForeverSniperDB.presets and ForeverSniperDB.presets[ap] then
    ForeverSniperDB.presetDirty = true
  end
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
    print(string.format("|cff10b981Goblin Broker:|r изменения сохранены в шаблон «%s».", ap))
  end
end)

wlRevertBtn:SetScript("OnClick", function()
  local ap = ForeverSniperDB.activePreset
  local p = ap and ForeverSniperDB.presets and ForeverSniperDB.presets[ap]
  if not p then return end
  ForeverSniperDB.presetDirty = false
  ForeverSniperDB.watchlist = CopyTableShallow(p.watchlist)
  ForeverSniperDB.qtyLimits = CopyTableShallow(p.qtyLimits)
  ForeverSniperDB.tracked = CopyTableShallow(p.tracked)
  ForeverSniperDB.selectedID = nil
  state.lastSeenByItem = {}
  ClearPendingDeal()
  UpdateStatus()
  SyncInputsFromSelected()
  print(string.format("|cfff59e0bGoblin Broker:|r изменения отменены, загружен шаблон «%s».", ap))
end)

local function RenderPresetsList()
  ForeverSniperDB.presets = ForeverSniperDB.presets or {}
  for _, r in ipairs(preRows) do r:Hide() end

  if ForeverSniperDB.activePreset then
    preExitBtn:SetFlatEnabled(true)
  else
    preExitBtn:SetFlatEnabled(false)
  end

  local names = {}
  for nm in pairs(ForeverSniperDB.presets) do table.insert(names, nm) end
  table.sort(names)

  if #names == 0 then
    preEmptyText:Show()
  else
    preEmptyText:Hide()
  end

  local y = 0
  for i, nm in ipairs(names) do
    local p = ForeverSniperDB.presets[nm]
    local row = preRows[i]
    if not row then
      row = CreateFrame("Frame", nil, preContent, "BackdropTemplate")
      row:SetSize(446, 28)
      row:SetBackdrop(FLAT_BACKDROP)
      row:SetBackdropColor(0.055, 0.078, 0.135, 1)
      row:SetBackdropBorderColor(0.16, 0.22, 0.34, 0.85)

      row.nm = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.nm:SetPoint("LEFT", 8, 0); row.nm:SetWidth(202); row.nm:SetJustifyH("LEFT"); row.nm:SetWordWrap(false)

      row.cnt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.cnt:SetPoint("LEFT", row.nm, "RIGHT", 4, 0); row.cnt:SetWidth(48); row.cnt:SetJustifyH("RIGHT")

      row.exp = CreateFlatButton(nil, row, 60, 22, "Экспорт")
      row.exp:SetPoint("RIGHT", -122, 0)
      row.exp:SetColors({ 0.12, 0.16, 0.25, 1 }, { 0.18, 0.24, 0.36, 1 }, { 0.24, 0.32, 0.46, 0.85 }, { 0.78, 0.86, 0.96 })

      row.load = CreateFlatButton(nil, row, 88, 22, "Мониторить")
      row.load:SetPoint("RIGHT", -28, 0)
      row.load:SetColors({ 0.02, 0.48, 0.34, 1 }, { 0.04, 0.62, 0.44, 1 }, { 0.06, 0.73, 0.51, 0.9 }, { 1, 1, 1 })

      row.del = CreateFlatButton(nil, row, 20, 22, "x")
      row.del:SetPoint("RIGHT", -4, 0)
      row.del:SetColors({ 0.12, 0.15, 0.22, 1 }, { 0.55, 0.14, 0.18, 1 }, { 0.20, 0.26, 0.36, 1 }, { 0.75, 0.80, 0.88 })

      preRows[i] = row
    end

    local cnt = 0
    for _ in pairs(p.watchlist or {}) do cnt = cnt + 1 end

    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    if nm == ForeverSniperDB.activePreset then
      row:SetBackdropColor(0.03, 0.16, 0.12, 1)
      row:SetBackdropBorderColor(0.06, 0.73, 0.51, 0.9)
      row.nm:SetText("|cff10b981" .. nm .. "|r")
    else
      row:SetBackdropColor(0.055, 0.078, 0.135, 1)
      row:SetBackdropBorderColor(0.16, 0.22, 0.34, 0.85)
      row.nm:SetText("|cfff8fafc" .. nm .. "|r")
    end
    row.cnt:SetText("|cff94a3b8" .. cnt .. " поз.|r")

    row.load:SetScript("OnClick", function()
      ForeverSniperDB.activePreset = nm
      ForeverSniperDB.presetDirty = false
      ForeverSniperDB.watchlist = CopyTableShallow(p.watchlist)
      ForeverSniperDB.qtyLimits = CopyTableShallow(p.qtyLimits)
      ForeverSniperDB.tracked = CopyTableShallow(p.tracked)
      ForeverSniperDB.selectedID = nil
      state.lastSeenByItem = {}
      SetActiveView("sniper")
      ClearPendingDeal()
      UpdateStatus()
      SyncInputsFromSelected()
      print(string.format("|cff10b981Goblin Broker:|r активен шаблон «%s» (%d поз.).", nm, cnt))
    end)

    row.exp:SetScript("OnClick", function()
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
      OpenExportModal("Экспорт шаблона: " .. nm, table.concat(lines, "\n"))
      print(string.format("|cff06b6d4Goblin Broker:|r экспорт шаблона «%s» (%d поз.) — скопируйте Ctrl+C.", nm, #lines))
    end)

    row.del:SetScript("OnClick", function()
      ForeverSniperDB.presets[nm] = nil
      if ForeverSniperDB.activePreset == nm then
        ForeverSniperDB.activePreset = nil
        UpdateStatus()
      end
      RenderPresetsList()
    end)

    row:Show()
    y = y + 30
  end

  preContent:SetHeight(math.max(200, y))
end

local function SaveCurrentPreset(emptyNew)
  local nm = (preNameInput:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if nm == "" then
    print("|cfff59e0bGoblin Broker:|r введите название шаблона.")
    return
  end
  ForeverSniperDB.presets = ForeverSniperDB.presets or {}
  if emptyNew then
    ForeverSniperDB.presets[nm] = { watchlist = {}, qtyLimits = {}, tracked = {} }
    ForeverSniperDB.activePreset = nm
    ForeverSniperDB.presetDirty = false
    ForeverSniperDB.watchlist = {}
    ForeverSniperDB.qtyLimits = {}
    ForeverSniperDB.tracked = {}
    ForeverSniperDB.selectedID = nil
    state.lastSeenByItem = {}
    ClearPendingDeal()
    UpdateStatus()
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
  preNameInput:SetText("")
  preNameInput:ClearFocus()
  RenderPresetsList()
  print(string.format("|cff10b981Goblin Broker:|r шаблон «%s» сохранён.", nm))
end

preExitBtn:SetScript("OnClick", function()
  ForeverSniperDB.activePreset = nil
  UpdateStatus()
  RenderPresetsList()
end)

preSaveBtn:SetScript("OnClick", function() SaveCurrentPreset(false) end)
preNewBtn:SetScript("OnClick", function() SaveCurrentPreset(true) end)
preStarterBtn:SetScript("OnClick", function()
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
  RenderPresetsList()
  if added > 0 then
    print(string.format("|cff10b981Goblin Broker:|r добавлено %d PRO-шаблонов под рынок Forever.", added))
  else
    print("|cff94a3b8Goblin Broker:|r все 5 PRO-шаблонов уже есть в списке.")
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
    local defName = "[PRO] Топ Рейд-Травы"
    local p = ForeverSniperDB.presets[defName]
    if p then
      ForeverSniperDB.activePreset = defName
      ForeverSniperDB.presetDirty = false
      ForeverSniperDB.watchlist = CopyTableShallow(p.watchlist)
      ForeverSniperDB.qtyLimits = CopyTableShallow(p.qtyLimits)
      ForeverSniperDB.tracked = {}
      ForeverSniperDB.selectedID = nil
      state.lastSeenByItem = {}
      ClearPendingDeal()
      UpdateStatus()
      SyncInputsFromSelected()
    end
    print("|cff10b981Goblin Broker:|r 5 PRO-наборов загружены, активен «[PRO] Топ Рейд-Травы» — жмите Старт скан!")
  end)
end
preNameInput:SetScript("OnEnterPressed", function() SaveCurrentPreset(false) end)
presetsBtn:SetScript("OnClick", function()
  if activeView == "presets" and not ForeverSniperDB.miniMode then
    SetActiveView("sniper")
  else
    RenderPresetsList()
    SetActiveView("presets")
  end
end)

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
local function RefreshOverrideBindings()
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
mmBtn:RegisterForDrag("RightButton")
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
  self:SetScript("OnUpdate", function()
    if not Minimap then return end
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    ForeverSniperDB.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
    UpdateMinimapPos()
  end)
end)

mmBtn:SetScript("OnDragStop", function(self)
  self:SetScript("OnUpdate", nil)
end)

mmBtn:SetScript("OnClick", function()
  ToggleSniperWindow()
end)

mmBtn:SetScript("OnEnter", function(self)
  mmLogo:SetVertexColor(1.08, 1.08, 1.08)
  if GameTooltip then
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cfff59e0bGoblin Broker|r|cfff8fafc: Forever|r")
    GameTooltip:AddLine("ЛКМ: Открыть / скрыть окно", 0.85, 0.90, 0.95)
    GameTooltip:AddLine("ПКМ + перетаскивание: переместить кнопку", 0.58, 0.64, 0.72)
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
    ClearPendingDeal()
    UpdateStatus()
    RefreshOverrideBindings()
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

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_LOGIN" then
    EnsureBackgroundSoundCVar()
    RefreshBuyHotkeyCache()
    RefreshSoundBtn()
    RefreshTrackBtn()
    ApplyMiniMode()
    if not ForeverSniperDB.miniMode then SetActiveView("sniper") end
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
  elseif event == "AUCTION_HOUSE_CLOSED" then
    state.ahOpen = false
    ForeverSniperDB.autoScan = false
    ClearPendingDeal()
    UpdateStatus()
    RefreshOverrideBindings()
  elseif event == "COMMODITY_PRICE_UPDATED" then
    if state.pendingDeal and state.pendingDeal.stage == "confirm" then
      local wasReady = state.pendingDeal.quoteReady
      state.pendingDeal.quoteReady = true
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
    if itemID ~= ForeverSniperDB.selectedID then return end
    local maxPrice = ForeverSniperDB.watchlist[itemID]
    if not maxPrice or (state.pendingDeal and state.pendingDeal.stage == "confirm") then return end

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

    if minUnitPrice and totalAvail > 0 then
      local _, cachedName = GetItemVisuals(itemID)
      SetPendingDeal({
        itemID = itemID,
        isCommodity = true,
        unitPrice = minUnitPrice,
        qty = totalAvail,
        maxPrice = maxPrice,
        name = cachedName,
        stage = "ready",
        exactCostForQty = ComputeTierCost,
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
        local diff = math.max(0, lowestSeen - maxPrice)
        local overPct = (maxPrice > 0) and math.floor((diff / maxPrice) * 100 + 0.5) or 0
        dealStripe:SetColorTexture(0.96, 0.45, 0.08, 1)
        dealCard:SetBackdropBorderColor(0.96, 0.45, 0.08, 0.65)
        dealBadge:SetText(DOT_AMBER .. " |cfff59e0bЦЕНА ВЫШЕ ЛИМИТА|r")
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
    if itemID ~= ForeverSniperDB.selectedID then return end
    local maxPrice = itemID and ForeverSniperDB.watchlist[itemID]
    if not maxPrice or (state.pendingDeal and state.pendingDeal.stage == "confirm") then return end

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
        local diff = math.max(0, lowestSeen - maxPrice)
        local overPct = (maxPrice > 0) and math.floor((diff / maxPrice) * 100 + 0.5) or 0
        dealStripe:SetColorTexture(0.96, 0.45, 0.08, 1)
        dealCard:SetBackdropBorderColor(0.96, 0.45, 0.08, 0.65)
        dealBadge:SetText(DOT_AMBER .. " |cfff59e0bЦЕНА ВЫШЕ ЛИМИТА|r")
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
