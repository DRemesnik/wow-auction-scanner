local ADDON_NAME, NS = ...
if not NS or not NS.f or not NS.hotkeyBtn then return end

local f = NS.f
local hotkeyBtn = NS.hotkeyBtn
local FLAT_BACKDROP = NS.FLAT_BACKDROP
local CreateFlatButton = NS.CreateFlatButton

-- ============================================================================
-- Modern Obsidian Keybind Popover (Primary + Secondary Slots, Keyboard + Wheel)
-- ============================================================================
local BIND_ROWS = {
  { action = "FOREVERSNIPER_BUY",    label = "Купить / Подтв. лот", accent = { 0.06, 0.73, 0.51 } },
  { action = "FOREVERSNIPER_SCAN",   label = "Старт / Пауза скана", accent = { 0.02, 0.71, 0.83 } },
  { action = "FOREVERSNIPER_BAIT",   label = "Наживка (1 шт)",      accent = { 0.95, 0.65, 0.05 } },
  { action = "FOREVERSNIPER_TOGGLE", label = "Показать / Скрыть",   accent = { 0.65, 0.75, 0.88 } },
}

local pop = CreateFrame("Frame", "ForeverSniperKeybindPopover", UIParent, "BackdropTemplate")
pop:SetSize(512, 240)
pop:SetFrameStrata("FULLSCREEN_DIALOG")
pop:SetClampedToScreen(true)
pop:SetBackdrop(FLAT_BACKDROP)
if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(pop, "panel") end
pop:SetBackdropColor(0.055, 0.062, 0.086, 0.98)
pop:SetBackdropBorderColor(1, 1, 1, 0.09)
pop:Hide()
if UISpecialFrames then
  table.insert(UISpecialFrames, "ForeverSniperKeybindPopover")
end

local popAccent = pop:CreateTexture(nil, "ARTWORK")
popAccent:SetHeight(2)
popAccent:SetPoint("TOPLEFT", 12, -1)
popAccent:SetPoint("TOPRIGHT", -12, -1)
popAccent:SetColorTexture(1, 1, 1, 1)
popAccent:SetGradient("HORIZONTAL", CreateColor(0.95, 0.65, 0.05, 0.9), CreateColor(0.06, 0.73, 0.51, 0.85))

local popTitle = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
popTitle:SetPoint("TOPLEFT", 16, -14)
popTitle:SetText("|cfff59e0bБыстрые горячие клавиши|r")

local popSub = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
popSub:SetPoint("TOPLEFT", 16, -32)
popSub:SetText("|cff94a3b8ЛКМ: назначить (клавиша / колесо)  ·  ПКМ: очистить слот|r")

local popClose = CreateFlatButton(nil, pop, 24, 24, "X")
popClose:SetPoint("TOPRIGHT", -12, -12)
popClose:SetColors({ 0.10, 0.115, 0.155, 0.75 }, { 0.55, 0.16, 0.20, 0.95 }, { 1, 1, 1, 0.06 }, { 0.78, 0.82, 0.90 })
popClose:SetScript("OnClick", function() pop:Hide() end)

-- Column headers (Primary + Secondary like native WoW Keybindings)
local colH1 = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
colH1:SetPoint("TOPLEFT", 16, -54)
colH1:SetText("|cff64748bДЕЙСТВИЕ|r")

local colH2 = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
colH2:SetPoint("TOPLEFT", 174, -54)
colH2:SetWidth(154)
colH2:SetJustifyH("CENTER")
colH2:SetText("|cff64748bОСНОВНАЯ|r")

local colH3 = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
colH3:SetPoint("TOPLEFT", 338, -54)
colH3:SetWidth(154)
colH3:SetJustifyH("CENTER")
colH3:SetText("|cff64748bВТОРИЧНАЯ|r")

local hdrLine = pop:CreateTexture(nil, "ARTWORK")
hdrLine:SetHeight(1)
hdrLine:SetPoint("TOPLEFT", 16, -70)
hdrLine:SetPoint("TOPRIGHT", -16, -70)
hdrLine:SetColorTexture(1, 1, 1, 0.06)

local capturingAction = nil
local capturingSlot = nil
local rowBtns = {}

local function RefreshHotkeyIndicator()
  local hasBuy = GetBindingKey and (GetBindingKey("FOREVERSNIPER_BUY") ~= nil)
  if hasBuy then
    hotkeyBtn:SetColors({ 0, 0, 0, 0 }, { 0.13, 0.15, 0.21, 0.85 }, { 0, 0, 0, 0 }, { 0.88, 0.92, 0.98 })
    if hotkeyBtn.activeBar then hotkeyBtn.activeBar:Hide() end
  else
    hotkeyBtn:SetColors({ 0.20, 0.14, 0.04, 0.75 }, { 0.28, 0.19, 0.05, 0.90 }, { 0, 0, 0, 0 }, { 1, 0.94, 0.65 })
    if hotkeyBtn.activeBar then hotkeyBtn.activeBar:SetColorTexture(0.95, 0.65, 0.05, 1); hotkeyBtn.activeBar:Show() end
  end
end

local function StyleSlotButton(b, def, slot, keyVal)
  if capturingAction == def.action and capturingSlot == slot then
    b:SetLabel("|cfffef08aНажмите клавишу...|r")
    b:SetColors({ 0.28, 0.19, 0.03, 1 }, { 0.36, 0.25, 0.04, 1 }, { 0.95, 0.65, 0.05, 0.95 }, { 1, 1, 1 })
  elseif keyVal and keyVal ~= "" then
    b:SetLabel("|cfff8fafc" .. keyVal .. "|r")
    b:SetColors({ 0.085, 0.10, 0.145, 1 }, { 0.13, 0.155, 0.22, 1 }, { def.accent[1], def.accent[2], def.accent[3], 0.55 }, { 1, 1, 1 })
  else
    b:SetLabel("|cff64748b—|r")
    b:SetColors({ 0.072, 0.082, 0.114, 1 }, { 0.115, 0.13, 0.18, 1 }, { 1, 1, 1, 0.06 }, { 0.55, 0.62, 0.72 })
  end
end

local function RefreshPopoverRows()
  for i, def in ipairs(BIND_ROWS) do
    local pair = rowBtns[i]
    if pair then
      local k1, k2 = nil, nil
      if GetBindingKey then
        k1, k2 = GetBindingKey(def.action)
      end
      StyleSlotButton(pair[1], def, 1, k1)
      StyleSlotButton(pair[2], def, 2, k2)
    end
  end
  RefreshHotkeyIndicator()
end

local function StopCapture()
  capturingAction = nil
  capturingSlot = nil
  pop:EnableKeyboard(false)
  pop:EnableMouseWheel(false)
  RefreshPopoverRows()
end

local function ApplyBinding(action, slot, combo)
  if InCombatLockdown and InCombatLockdown() then
    print("|cfff59e0bGoblin Broker:|r нельзя менять бинды в бою.")
    StopCapture()
    return
  end
  if GetBindingKey and SetBinding then
    local k1, k2 = GetBindingKey(action)
    if k1 then SetBinding(k1) end
    if k2 then SetBinding(k2) end

    if slot == 1 then
      k1 = (combo and combo ~= "") and combo or nil
      if k1 and k2 == k1 then k2 = nil end
    else
      k2 = (combo and combo ~= "") and combo or nil
      if k2 and k1 == k2 then k1 = nil end
    end

    if k1 then SetBinding(k1, action) end
    if k2 then SetBinding(k2, action) end
    if SaveBindings and GetCurrentBindingSet then
      pcall(SaveBindings, GetCurrentBindingSet())
    end
  end
  StopCapture()
  if NS.RefreshBuyHotkeyCache then NS.RefreshBuyHotkeyCache() end
  if NS.RefreshBuyButtonText then NS.RefreshBuyButtonText() end
  if NS.RefreshOverrideBindings then NS.RefreshOverrideBindings() end
  if f._baitModal and f._baitModal.RefreshHotkey then f._baitModal.RefreshHotkey() end
end

local MOD_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true }

pop:SetScript("OnKeyDown", function(_, key)
  if not capturingAction then return end
  if key == "ESCAPE" then
    StopCapture()
    return
  end
  if MOD_KEYS[key] then return end
  local prefix = (IsShiftKeyDown() and "SHIFT-" or "") .. (IsControlKeyDown() and "CTRL-" or "") .. (IsAltKeyDown() and "ALT-" or "")
  ApplyBinding(capturingAction, capturingSlot or 1, prefix .. key)
end)

pop:SetScript("OnMouseWheel", function(_, delta)
  if not capturingAction then return end
  local prefix = (IsShiftKeyDown() and "SHIFT-" or "") .. (IsControlKeyDown() and "CTRL-" or "") .. (IsAltKeyDown() and "ALT-" or "")
  ApplyBinding(capturingAction, capturingSlot or 1, prefix .. (delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN"))
end)

pop:SetScript("OnHide", StopCapture)

for i, def in ipairs(BIND_ROWS) do
  local y = -80 - (i - 1) * 38
  local lbl = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lbl:SetPoint("TOPLEFT", 16, y - 6)
  lbl:SetWidth(150)
  lbl:SetJustifyH("LEFT")
  lbl:SetText("|cffe2e8f0" .. def.label .. "|r")

  local function MakeSlotBtn(slot, xOff)
    local btn = CreateFlatButton(nil, pop, 154, 28, "—")
    btn:SetPoint("TOPLEFT", xOff, y)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouseBtn)
      if mouseBtn == "RightButton" then
        ApplyBinding(def.action, slot, nil)
        return
      end
      if capturingAction == def.action and capturingSlot == slot then
        StopCapture()
      else
        capturingAction = def.action
        capturingSlot = slot
        pop:EnableKeyboard(true)
        pop:EnableMouseWheel(true)
        RefreshPopoverRows()
      end
    end)
    return btn
  end

  rowBtns[i] = { MakeSlotBtn(1, 174), MakeSlotBtn(2, 338) }
end

if NS.ApplyModernFonts then NS.ApplyModernFonts(pop) end

hotkeyBtn:SetScript("OnClick", function(self)
  if pop:IsShown() then
    pop:Hide()
  else
    if f._closePopovers then f._closePopovers(pop) end
    pop:ClearAllPoints()
    pop:SetPoint("BOTTOMLEFT", self, "BOTTOMRIGHT", 8, 0)
    RefreshPopoverRows()
    pop:Show()
  end
end)

f._keybindPopover = pop
f._refreshHotkeyIndicator = RefreshHotkeyIndicator
RefreshHotkeyIndicator()
