local ADDON_NAME, NS = ...
if not NS or not NS.f or not NS.state then return end

local f = NS.f
local state = NS.state
local FLAT_BACKDROP = NS.FLAT_BACKDROP
local AttachDropShadow = NS.AttachDropShadow
local CreateFlatButton = NS.CreateFlatButton
local StyleFlatBox = NS.StyleFlatBox
local GetCachedItemKey = NS.GetCachedItemKey
local GetItemVisuals = NS.GetItemVisuals
local FormatCoins = NS.FormatCoins
local FormatCoinsPlain = NS.FormatCoinsPlain
local ICON_GOLD = NS.ICON_GOLD
local ICON_SILVER = NS.ICON_SILVER
local ICON_COPPER = NS.ICON_COPPER

-- ============================================================================
-- Bait Posting ("?? ?????"): Post 1 unit at minimum duration (2h/12h)
-- ============================================================================
local function EnsureBaitsDB()
  ForeverSniperDB.baits = ForeverSniperDB.baits or {}
  return ForeverSniperDB.baits
end
local baitModal, RenderBaitList
local BAIT_QTY = 1
local BAIT_DURATION = 1 -- Shortest AH duration tier (1 = min tier: 2h/12h)

local function FindBagItemLocation(itemID, firstOnly)
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
      -- Fast zero-allocation ID precheck before allocating C_Container item table
      local fastID = getItemID and getItemID(bag, slot) or nil
      if (not getItemID) or (fastID == itemID) then
        local slotItemID, count, isBound = fastID, 1, false
        if getInfo then
          local info = getInfo(bag, slot)
          if info then
            slotItemID = info.itemID
            count = info.stackCount or 1
            isBound = not not info.isBound
          end
        elseif slotItemID and GetContainerItemInfo then
          local _, c = GetContainerItemInfo(bag, slot)
          if c then count = c end
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
              if firstOnly then return firstLoc, totalCount end
            end
          end
        end
      end
    end
  end
  return firstLoc, totalCount
end

local function IsBaitCommodity(itemID)
  state.isCommodityCache = state.isCommodityCache or {}
  local cached = state.isCommodityCache[itemID]
  if cached ~= nil then return cached end
  if C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
    local key = GetCachedItemKey(itemID)
    local info = key and C_AuctionHouse.GetItemKeyInfo(key) or nil
    if info and info.isCommodity ~= nil then
      state.isCommodityCache[itemID] = info.isCommodity
      return info.isCommodity
    end
  end
  if GetItemInfo then
    local _, _, _, _, _, _, _, maxStack = GetItemInfo(itemID)
    if maxStack then
      local res = maxStack > 1
      state.isCommodityCache[itemID] = res
      return res
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
baitModal:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  if f._saveModalPos then f._saveModalPos(self, "bait") end
end)
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
baitGUnit:SetText(ICON_GOLD)

local baitSilverInput = CreateFrame("EditBox", nil, baitEditCard, "BackdropTemplate")
StyleFlatBox(baitSilverInput, 36, 22)
baitSilverInput:SetPoint("LEFT", baitGUnit, "RIGHT", 6, 0)
baitSilverInput:SetNumeric(true)
baitSilverInput:SetMaxLetters(2)
baitSilverInput:SetJustifyH("RIGHT")

local baitSUnit = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitSUnit:SetPoint("LEFT", baitSilverInput, "RIGHT", 3, 0)
baitSUnit:SetText(ICON_SILVER)

local baitCopperInput = CreateFrame("EditBox", nil, baitEditCard, "BackdropTemplate")
StyleFlatBox(baitCopperInput, 36, 22)
baitCopperInput:SetPoint("LEFT", baitSUnit, "RIGHT", 6, 0)
baitCopperInput:SetNumeric(true)
baitCopperInput:SetMaxLetters(2)
baitCopperInput:SetJustifyH("RIGHT")

local baitCUnit = baitEditCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
baitCUnit:SetPoint("LEFT", baitCopperInput, "RIGHT", 3, 0)
baitCUnit:SetText(ICON_COPPER)

local baitSaveBtn = CreateFlatButton(nil, baitEditCard, 92, 22, "Сохранить")
baitSaveBtn:SetPoint("RIGHT", baitEditCard, "RIGHT", -10, 0)
baitSaveBtn:SetPoint("TOP", baitIdInput, "TOP", 0, 0)
baitSaveBtn:SetColors({ 0.45, 0.32, 0.02, 1 }, { 0.62, 0.44, 0.03, 1 }, { 0.92, 0.70, 0.03, 0.9 }, { 1, 0.96, 0.85 })

local baitFromSniperBtn = CreateFlatButton(nil, baitEditCard, 92, 20, "Из снайпера")
baitFromSniperBtn:SetPoint("TOPRIGHT", baitEditCard, "TOPRIGHT", -10, -8)
baitFromSniperBtn:SetColors({ 0.08, 0.14, 0.24, 1 }, { 0.12, 0.22, 0.36, 1 }, { 0.0, 0.71, 0.85, 0.75 }, { 0.85, 0.96, 1 })

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
baitScroll:SetPoint("BOTTOMRIGHT", -14, 6)
do
  local sb = _G["ForeverSniperBaitScrollScrollBar"]
  if sb then
    sb:ClearAllPoints()
    sb:SetPoint("TOPRIGHT", baitListBox, "TOPRIGHT", -3, -6)
    sb:SetPoint("BOTTOMRIGHT", baitListBox, "BOTTOMRIGHT", -3, 6)
    sb:SetWidth(4)
    local up = _G["ForeverSniperBaitScrollScrollBarScrollUpButton"]
    local dn = _G["ForeverSniperBaitScrollScrollBarScrollDownButton"]
    if up then up:SetAlpha(0); up:EnableMouse(false); up:SetHeight(1) end
    if dn then dn:SetAlpha(0); dn:EnableMouse(false); dn:SetHeight(1) end
    local thumb = sb:GetThumbTexture()
    if thumb then
      thumb:SetColorTexture(0.32, 0.44, 0.62, 0.75)
      thumb:SetWidth(4)
    end
  end
end

local baitContent = CreateFrame("Frame", nil, baitScroll)
baitContent:SetSize(510, 200)
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
  if not priceCopper or priceCopper <= 0 then
    print("|cfff59e0bGoblin Broker [На живца]:|r укажите цену больше 0.")
    return
  end
  local itemLoc, bagCount = FindBagItemLocation(itemID, true)
  if not itemLoc or bagCount < BAIT_QTY then
    print("|cfff59e0bGoblin Broker [На живца]:|r предмета нет в сумках (нужна минимум 1 шт).")
    if baitModal and baitModal:IsShown() and RenderBaitList then RenderBaitList() end
    return
  end
  state.pauseScanUntil = math.max(state.pauseScanUntil or 0, GetTime() + 0.06)
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
    state.lastBaitByItem = state.lastBaitByItem or {}
    state.lastBaitByItem[itemID] = priceCopper
    if f._logEvent then f._logEvent("BAIT", itemID, BAIT_QTY, priceCopper) end
    print(string.format("|cfff59e0bGoblin Broker [На живца]:|r выставлен 1x %s за %s (мин. срок).", itemName or itemID, FormatCoinsPlain(priceCopper)))
  else
    print("|cfff59e0bGoblin Broker [На живца]:|r не удалось выставить лот (проверьте АХ и предмет).")
  end
  if baitModal and baitModal:IsShown() and RenderBaitList then RenderBaitList() end
end

do
  local COL_DEL_BG = { 0.18, 0.08, 0.10, 1 }
  local COL_DEL_HV = { 0.32, 0.10, 0.14, 1 }
  local COL_DEL_BD = { 0.45, 0.15, 0.20, 0.8 }
  local COL_DEL_TX = { 0.95, 0.65, 0.70 }
  local COL_OFF_BG = { 0.10, 0.13, 0.20, 1 }
  local COL_OFF_HV = { 0.14, 0.18, 0.26, 1 }
  local COL_OFF_BD = { 0.20, 0.26, 0.36, 0.6 }
  local COL_OFF_TX = { 0.50, 0.58, 0.70 }
  local COL_CNF_BG = { 0.52, 0.14, 0.14, 1 }
  local COL_CNF_HV = { 0.68, 0.18, 0.18, 1 }
  local COL_CNF_BD = { 0.96, 0.35, 0.35, 0.95 }
  local COL_CNF_TX = { 1, 0.95, 0.95 }
  local COL_PST_BG = { 0.45, 0.32, 0.02, 1 }
  local COL_PST_HV = { 0.62, 0.44, 0.03, 1 }
  local COL_PST_BD = { 0.92, 0.70, 0.03, 0.95 }
  local COL_PST_TX = { 1, 0.96, 0.85 }
  local baitBagCounts = {}

  local function ScanBaitBagCounts(baits)
    for k in pairs(baitBagCounts) do baitBagCounts[k] = nil end
    local getNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local getItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    local getInfo = C_Container and C_Container.GetContainerItemInfo
    if not getNumSlots then return baitBagCounts end
    local maxBag = (NUM_BAG_SLOTS or 4) + 2
    for bag = 0, maxBag do
      local slots = getNumSlots(bag) or 0
      for slot = 1, slots do
        local sid = getItemID and getItemID(bag, slot) or nil
        if sid and baits[sid] then
          local cnt, isBound = 1, false
          if getInfo then
            local info = getInfo(bag, slot)
            if info then
              cnt = info.stackCount or 1
              isBound = not not info.isBound
            end
          elseif GetContainerItemInfo then
            local _, c = GetContainerItemInfo(bag, slot)
            if c then cnt = c end
          end
          if not isBound then
            baitBagCounts[sid] = (baitBagCounts[sid] or 0) + cnt
          end
        end
      end
    end
    return baitBagCounts
  end

  local function OnBaitRowClick(self)
    ForeverSniperDB.activeBaitID = self.itemID
    ApplyBaitPreviewItemID(self.itemID, self.priceCopper)
    RenderBaitList()
  end

  local function OnBaitRowEnter(self)
    self:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.75)
    if GameTooltip and self.itemID then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.itemID)
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Клик по строке: выбрать для хоткея (★) и ред. цены", 0.65, 0.75, 0.85)
      GameTooltip:Show()
    end
  end

  local function OnBaitRowLeave(self)
    if self.isActiveBait then
      self:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.9)
    else
      self:SetBackdropBorderColor(0.15, 0.22, 0.34, 1)
    end
    if GameTooltip then GameTooltip:Hide() end
  end

  local function OnBaitPostClick(self)
    local p = self:GetParent()
    if not p or not p.itemID then return end
    ForeverSniperDB.activeBaitID = p.itemID
    ExecuteBaitPost(p.itemID, p.priceCopper)
  end

  local function OnBaitDelClick(self)
    local p = self:GetParent()
    local id = p and p.itemID
    if not id then return end
    EnsureBaitsDB()[id] = nil
    if ForeverSniperDB.activeBaitID == id then
      ForeverSniperDB.activeBaitID = nil
    end
    if state.pendingBaitConfirmID == id then
      state.pendingBaitConfirmID = nil
    end
    RenderBaitList()
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

    local counts = (#list > 0) and ScanBaitBagCounts(baits) or baitBagCounts
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
        row.delBtn:SetColors(COL_DEL_BG, COL_DEL_HV, COL_DEL_BD, COL_DEL_TX)
        row.delBtn:SetScript("OnClick", OnBaitDelClick)

        row.postBtn = CreateFlatButton(nil, row, 108, 24, "Выставить 1 шт")
        row.postBtn:SetPoint("RIGHT", row.delBtn, "LEFT", -6, 0)
        row.postBtn:SetScript("OnClick", OnBaitPostClick)

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

        row:SetScript("OnClick", OnBaitRowClick)
        row:SetScript("OnEnter", OnBaitRowEnter)
        row:SetScript("OnLeave", OnBaitRowLeave)
        baitRows[i] = row
      end

      local icon, nm, r, g, b = GetItemVisuals(entry.id)
      local bagCount = counts[entry.id] or 0
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
        row.postBtn:SetColors(COL_OFF_BG, COL_OFF_HV, COL_OFF_BD, COL_OFF_TX)
      elseif bagCount < 1 then
        row.postBtn:SetLabel("Нет в сумке")
        row.postBtn:SetColors(COL_OFF_BG, COL_OFF_HV, COL_OFF_BD, COL_OFF_TX)
      elseif needsConfirm then
        row.postBtn:SetLabel("Подтв. цену!")
        row.postBtn:SetColors(COL_CNF_BG, COL_CNF_HV, COL_CNF_BD, COL_CNF_TX)
      else
        row.postBtn:SetLabel("Выставить 1 шт")
        row.postBtn:SetColors(COL_PST_BG, COL_PST_HV, COL_PST_BD, COL_PST_TX)
      end
      row:Show()
    end

    for i = #list + 1, #baitRows do
      baitRows[i]:Hide()
    end
    baitContent:SetHeight(math.max(180, #list * 44))
  end
end

local function SaveBaitFromInputs()
  local id = tonumber(baitIdInput:GetText())
  local g = tonumber(baitGoldInput:GetText()) or 0
  local s = tonumber(baitSilverInput:GetText()) or 0
  local c = tonumber(baitCopperInput:GetText()) or 0
  local copper = (g * 10000) + (s * 100) + c
  if not id or id <= 0 or copper <= 0 then
    print("|cfff59e0bGoblin Broker [На живца]:|r укажите корректный ID предмета и цену.")
    return
  end
  EnsureBaitsDB()[id] = copper
  ForeverSniperDB.activeBaitID = id
  state.pendingBaitConfirmID = nil
  ApplyBaitPreviewItemID(id, copper)
  RenderBaitList()
  if f._refreshLiveStrip then f._refreshLiveStrip() end
end

baitSaveBtn:SetScript("OnClick", SaveBaitFromInputs)

baitFromSniperBtn:SetScript("OnClick", function()
  local sel = ForeverSniperDB and ForeverSniperDB.selectedID
  if not sel then
    print("|cfff59e0bGoblin Broker [На живца]:|r в снайпере не выбран активный предмет.")
    return
  end
  local seen = state.lastSeenByItem and state.lastSeenByItem[sel]
  local lim = ForeverSniperDB.watchlist and ForeverSniperDB.watchlist[sel]
  local prePrice = (lim and lim > 0) and lim or (seen and seen.lowestPrice)
  ApplyBaitPreviewItemID(sel, prePrice)
end)

local baitInputOrder = { baitIdInput, baitGoldInput, baitSilverInput, baitCopperInput }
for idx, box in ipairs(baitInputOrder) do
  box:SetScript("OnTabPressed", function()
    local nxt = baitInputOrder[(idx % #baitInputOrder) + 1]
    nxt:SetFocus()
    if nxt.HighlightText then nxt:HighlightText() end
  end)
  if idx > 1 then
    box:SetScript("OnEnterPressed", function()
      SaveBaitFromInputs()
    end)
  end
end

baitIdInput:SetScript("OnEnterPressed", function(self)
  local id = tonumber(self:GetText())
  if id and id > 0 then
    ApplyBaitPreviewItemID(id)
  else
    self:ClearFocus()
  end
end)

if UISpecialFrames then
  table.insert(UISpecialFrames, "ForeverSniperBaitFrame")
end

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
    if f._closePopovers then f._closePopovers() end
    if f._restoreModalPos then f._restoreModalPos(baitModal, "bait") end
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
