local ADDON_NAME, NS = ...
if not NS or not NS.f or not NS.hotkeyBtn then return end

local f = NS.f
local hotkeyBtn = NS.hotkeyBtn
local FLAT_BACKDROP = NS.FLAT_BACKDROP
local AttachDropShadow = NS.AttachDropShadow
local CreateFlatButton = NS.CreateFlatButton

-- ============================================================================
-- 1-Click Inline Keybind Popover (Keyboard + MouseWheel, InCombatLockdown Safe)
-- ============================================================================
local BIND_ROWS = {
  { action = "FOREVERSNIPER_BUY",    label = "Купить / Подтв. лот", accent = { 0.06, 0.73, 0.51 } },
  { action = "FOREVERSNIPER_SCAN",   label = "Старт / Пауза скана", accent = { 0.0, 0.71, 0.85 } },
  { action = "FOREVERSNIPER_BAIT",   label = "Наживка (1 шт)",      accent = { 0.96, 0.70, 0.03 } },
  { action = "FOREVERSNIPER_TOGGLE", label = "Показать / Скрыть",   accent = { 0.65, 0.75, 0.88 } },
}

local pop = CreateFrame("Frame", "ForeverSniperKeybindPopover", UIParent, "BackdropTemplate")
pop:SetSize(336, 206)
pop:SetFrameStrata("FULLSCREEN_DIALOG")
pop:SetClampedToScreen(true)
pop:SetBackdrop(FLAT_BACKDROP)
pop:SetBackdropColor(0.043, 0.067, 0.125, 0.99)
pop:SetBackdropBorderColor(0.92, 0.70, 0.03, 0.85)
AttachDropShadow(pop, 12, 0.75)
pop:Hide()
if UISpecialFrames then
  table.insert(UISpecialFrames, "ForeverSniperKeybindPopover")
end

local popTitle = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
popTitle:SetPoint("TOPLEFT", 12, -10)
popTitle:SetText("|cfff59e0bБыстрые горячие клавиши|r")

local popSub = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
popSub:SetPoint("TOPLEFT", 12, -26)
popSub:SetText("|cff94a3b8ЛКМ: назначить (клавиша / колесо)  ·  ПКМ: очистить|r")

local popClose = CreateFlatButton(nil, pop, 22, 22, "X")
popClose:SetPoint("TOPRIGHT", -10, -8)
popClose:SetColors({ 0.10, 0.13, 0.21, 1 }, { 0.55, 0.14, 0.18, 1 }, { 0.22, 0.28, 0.40, 1 }, { 0.85, 0.89, 0.95 })
popClose:SetScript("OnClick", function() pop:Hide() end)

local capturingAction = nil
local rowBtns = {}

local function RefreshHotkeyIndicator()
  local hasBuy = GetBindingKey and (GetBindingKey("FOREVERSNIPER_BUY") ~= nil)
  if hasBuy then
    hotkeyBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.22, 0.29, 0.42, 1 }, { 0.98, 0.94, 0.54 })
  else
    hotkeyBtn:SetColors({ 0.20, 0.14, 0.03, 1 }, { 0.30, 0.21, 0.05, 1 }, { 0.96, 0.62, 0.04, 0.95 }, { 1, 0.94, 0.65 })
  end
end

local function RefreshPopoverRows()
  for i, def in ipairs(BIND_ROWS) do
    local b = rowBtns[i]
    if b then
      if capturingAction == def.action then
        b:SetLabel("|cfffef08aНажмите клавишу / колесо...|r")
        b:SetColors({ 0.30, 0.20, 0.02, 1 }, { 0.40, 0.27, 0.03, 1 }, { 0.96, 0.70, 0.03, 1 }, { 1, 1, 1 })
      else
        local k1 = GetBindingKey and GetBindingKey(def.action)
        if k1 and k1 ~= "" then
          b:SetLabel("|cfff8fafc" .. k1 .. "|r")
          b:SetColors({ 0.07, 0.12, 0.20, 1 }, { 0.12, 0.19, 0.30, 1 }, { def.accent[1], def.accent[2], def.accent[3], 0.75 }, { 1, 1, 1 })
        else
          b:SetLabel("|cff64748bНе назначена|r")
          b:SetColors({ 0.07, 0.09, 0.15, 1 }, { 0.12, 0.16, 0.24, 1 }, { 0.20, 0.26, 0.36, 0.8 }, { 0.65, 0.72, 0.82 })
        end
      end
    end
  end
  RefreshHotkeyIndicator()
end

local function StopCapture()
  capturingAction = nil
  pop:EnableKeyboard(false)
  pop:EnableMouseWheel(false)
  RefreshPopoverRows()
end

local function ApplyBinding(action, combo)
  if InCombatLockdown and InCombatLockdown() then
    print("|cfff59e0bGoblin Broker:|r нельзя менять бинды в бою.")
    StopCapture()
    return
  end
  if GetBindingKey and SetBinding then
    local k1, k2 = GetBindingKey(action)
    if k1 then SetBinding(k1) end
    if k2 then SetBinding(k2) end
    if combo and combo ~= "" then
      SetBinding(combo, action)
    end
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
  ApplyBinding(capturingAction, prefix .. key)
end)

pop:SetScript("OnMouseWheel", function(_, delta)
  if not capturingAction then return end
  local prefix = (IsShiftKeyDown() and "SHIFT-" or "") .. (IsControlKeyDown() and "CTRL-" or "") .. (IsAltKeyDown() and "ALT-" or "")
  ApplyBinding(capturingAction, prefix .. (delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN"))
end)

pop:SetScript("OnHide", StopCapture)

for i, def in ipairs(BIND_ROWS) do
  local y = -48 - (i - 1) * 36
  local lbl = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lbl:SetPoint("TOPLEFT", 14, y - 6)
  lbl:SetWidth(142)
  lbl:SetJustifyH("LEFT")
  lbl:SetText(def.label)

  local btn = CreateFlatButton(nil, pop, 162, 26, "Не назначена")
  btn:SetPoint("TOPRIGHT", -12, y)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:SetScript("OnClick", function(_, mouseBtn)
    if mouseBtn == "RightButton" then
      ApplyBinding(def.action, nil)
      return
    end
    if capturingAction == def.action then
      StopCapture()
    else
      capturingAction = def.action
      pop:EnableKeyboard(true)
      pop:EnableMouseWheel(true)
      RefreshPopoverRows()
    end
  end)
  rowBtns[i] = btn
end

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
