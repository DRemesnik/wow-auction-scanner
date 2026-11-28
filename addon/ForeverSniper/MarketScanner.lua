local ADDON_NAME, NS = ...
if not NS or not NS.f then return end

local f = NS.f
local state = NS.state

-- ============================================================================
-- MarketScanner: Liquidity & Order-Book Dynamics (0% Ban Risk, Read-Only)
-- ============================================================================
local TOP_K_TIERS = 12
local MAX_MARKET_ITEMS = 250
local STALE_SECONDS = 180

local function EnsureMarketDB()
  ForeverSniperDB.market = ForeverSniperDB.market or {}
  return ForeverSniperDB.market
end

local function PruneMarketDB()
  local db = EnsureMarketDB()
  local cnt = 0
  local oldestID, oldestTs = nil, nil
  for id, rec in pairs(db) do
    cnt = cnt + 1
    local ts = rec.updatedAt or 0
    if not oldestTs or ts < oldestTs then
      oldestTs = ts
      oldestID = id
    end
  end
  if cnt > MAX_MARKET_ITEMS and oldestID then
    db[oldestID] = nil
  end
end

local function ComputeCLS(vDrainHour, tiers, spreadPct, cri, wallQty)
  -- 1. Confirmed Drain (0-35)
  local drainScore = 35 * math.min(1, math.log(1 + math.max(0, vDrainHour)) / math.log(1 + 60))
  -- 2. Book Depth & Tightness (0-25)
  local tierScore = 15 * math.min(1, (tiers or 0) / 8)
  local tightScore = 10 * math.max(0, math.min(1, 1 - math.max(0, (spreadPct or 0) - 5) / 45))
  -- 3. Organic Stability (0-20): penalize bot churn when drain is low
  local effectiveCri = (vDrainHour >= 10) and ((cri or 0) * 0.5) or (cri or 0)
  local stabScore = 20 * math.max(0, 1 - effectiveCri)
  -- 4. Wall Clearability (0-20)
  local hoursToClear = (vDrainHour > 0.5) and ((wallQty or 0) / vDrainHour) or 99
  local wallScore = 20 * math.max(0, math.min(1, 1 - hoursToClear / 6))
  return math.floor(drainScore + tierScore + tightScore + stabScore + wallScore + 0.5)
end

local function UpdateMarketMetrics(itemID, p1, q1, p2, totalDepth, tiers, wallQty, spreadPct)
  if not itemID or not p1 or p1 <= 0 then return end
  local db = EnsureMarketDB()
  local nowSys = time and time() or 0
  local nowMono = GetTime and GetTime() or 0

  local live = state.marketLive and state.marketLive[itemID]
  if not state.marketLive then state.marketLive = {}; live = nil end
  local rec = db[itemID]
  if not rec then
    rec = {
      p1 = p1, p2 = p2 or p1, emaFloor = p2 or p1,
      totalDepth = totalDepth or 0, tiers = tiers or 1,
      wallQty = wallQty or 0, spreadPct = spreadPct or 0,
      vDrain = 0, cri = 0, cls = 0, scans = 0, updatedAt = nowSys,
    }
    db[itemID] = rec
    PruneMarketDB()
  end

  local anchor = p2 or p1
  if live and live.monoAt and (nowMono - live.monoAt) >= 0.4 and (nowMono - live.monoAt) <= 300 then
    local dt = nowMono - live.monoAt
    local prevAnchor = live.p2 or live.p1 or anchor
    local prevWall = live.wallQty or 0

    -- Drain velocity (pcs/hour): only credit when anchor price holds or rises (filters undercuts)
    local absorbed = 0
    if anchor >= prevAnchor and prevWall > (wallQty or 0) then
      absorbed = prevWall - (wallQty or 0)
    end
    local instDrainHour = (absorbed / dt) * 3600
    local alpha = 1 - math.exp(-dt / 120)
    rec.vDrain = (rec.vDrain or 0) * (1 - alpha) + instDrainHour * alpha

    -- Cancel-Repost / Churn Index (CRI): micro price flips without real depth drain
    local priceDiffPct = (prevAnchor > 0) and math.abs(anchor - prevAnchor) / prevAnchor or 0
    local depthDiffPct = ((live.totalDepth or 0) > 0) and math.abs((totalDepth or 0) - live.totalDepth) / live.totalDepth or 0
    local isChurn = (priceDiffPct > 0 and priceDiffPct <= 0.03 and depthDiffPct < 0.05) and 1 or 0
    rec.cri = (rec.cri or 0) * 0.85 + isChurn * 0.15
  end

  if not live then
    live = {}
    state.marketLive[itemID] = live
  end
  live.p1 = p1
  live.p2 = anchor
  live.totalDepth = totalDepth or 0
  live.wallQty = wallQty or 0
  live.monoAt = nowMono

  rec.p1 = p1
  rec.p2 = anchor
  rec.emaFloor = math.floor(((rec.emaFloor or anchor) * 0.8 + anchor * 0.2) + 0.5)
  rec.totalDepth = totalDepth or 0
  rec.tiers = tiers or 1
  rec.wallQty = wallQty or 0
  rec.spreadPct = math.floor((spreadPct or 0) * 10 + 0.5) / 10
  rec.scans = (rec.scans or 0) + 1
  rec.updatedAt = nowSys
  rec.cls = ComputeCLS(rec.vDrain or 0, rec.tiers, rec.spreadPct, rec.cri or 0, rec.wallQty)
end

-- Called from COMMODITY_SEARCH_RESULTS_UPDATED
NS.OnScannerCommodity = function(itemID)
  if not itemID or not C_AuctionHouse then return end
  local totalDepth = (C_AuctionHouse.GetCommoditySearchResultsQuantity and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID)) or 0
  local numTiers = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  if numTiers == 0 then
    local db = EnsureMarketDB()
    local rec = db[itemID]
    if rec then
      rec.totalDepth = 0
      rec.tiers = 0
      rec.wallQty = 0
      rec.updatedAt = time and time() or 0
    end
    return
  end

  local p1, q1, p2 = nil, 0, nil
  local wallQty = 0
  local readMax = math.min(numTiers, TOP_K_TIERS)
  for i = 1, readMax do
    local res = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if res and res.unitPrice and res.unitPrice > 0 then
      local q = res.quantity or 0
      if not p1 then
        p1 = res.unitPrice
        q1 = q
      elseif not p2 then
        p2 = res.unitPrice
      end
      -- True bait guard: only use tier 2 as anchor when tier 1 is <= 2 pcs AND >12% cheaper than tier 2
      local isBaitTier1 = (q1 <= 2 and p2 and p1 and p2 > (p1 * 1.12))
      local anchor = isBaitTier1 and p2 or p1
      if res.unitPrice <= anchor * 1.05 then
        wallQty = wallQty + q
      end
    end
  end
  local isBaitTier1 = (q1 <= 2 and p2 and p1 and p2 > (p1 * 1.12))
  local realAnchor = isBaitTier1 and p2 or p1
  local spreadPct = (p1 and p1 > 0 and p2) and (((p2 - p1) / p1) * 100) or 0
  UpdateMarketMetrics(itemID, p1, q1, realAnchor, totalDepth, numTiers, wallQty, spreadPct)
end

-- Called from ITEM_SEARCH_RESULTS_UPDATED
NS.OnScannerItem = function(itemKey, itemID)
  if not itemID or not itemKey or not C_AuctionHouse then return end
  local num = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
  if num == 0 then return end
  local p1, p2, wallQty = nil, nil, 0
  local readMax = math.min(num, 8)
  for i = 1, readMax do
    local res = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if res and res.buyoutAmount and res.buyoutAmount > 0 then
      if not p1 then p1 = res.buyoutAmount
      elseif not p2 then p2 = res.buyoutAmount end
      local anchor = p2 or p1
      if res.buyoutAmount <= anchor * 1.05 then
        wallQty = wallQty + 1
      end
    end
  end
  if not p2 then p2 = p1 end
  local spreadPct = (p1 and p1 > 0 and p2) and (((p2 - p1) / p1) * 100) or 0
  UpdateMarketMetrics(itemID, p1, 1, p2, num, num, wallQty, spreadPct)
end

-- Passive sampling during normal Sniper mode (at most once per 15s per item)
NS.OnPassiveSample = function(itemID, isCommodity, itemKey)
  if not itemID then return end
  state.lastPassiveSampleAt = state.lastPassiveSampleAt or {}
  local now = GetTime()
  if (now - (state.lastPassiveSampleAt[itemID] or 0)) < 15 then return end
  state.lastPassiveSampleAt[itemID] = now
  if isCommodity then
    NS.OnScannerCommodity(itemID)
  else
    NS.OnScannerItem(itemKey, itemID)
  end
end

-- Mode Switcher now lives in the Top Header Bar (ForeverSniper.lua: NS.SetScanMode / NS.RefreshModeUI)

-- ============================================================================
-- Embedded Live Liquidity Radar (replaces wlBox inside main window in Scanner mode)
-- Keeps ForeverSniperLogFrame purely for personal financial analytics (5 tabs)
-- ============================================================================
if NS.wlBox and NS.CreateFlatButton and NS.FLAT_BACKDROP then
  local radarBox = CreateFrame("Frame", nil, f, "BackdropTemplate")
  radarBox:SetPoint("TOPLEFT", NS.wlBox, "TOPLEFT", 0, 0)
  radarBox:SetPoint("BOTTOMRIGHT", NS.wlBox, "BOTTOMRIGHT", 0, 0)
  radarBox:SetBackdrop(NS.FLAT_BACKDROP)
  radarBox:SetBackdropColor(0.025, 0.044, 0.088, 1)
  radarBox:SetBackdropBorderColor(0.0, 0.71, 0.85, 0.55)
  radarBox:Hide()
  f._radarBox = radarBox

  local hdr = CreateFrame("Frame", nil, radarBox, "BackdropTemplate")
  hdr:SetPoint("TOPLEFT", 4, -4)
  hdr:SetPoint("TOPRIGHT", -4, -4)
  hdr:SetHeight(20)
  hdr:SetBackdrop(NS.FLAT_BACKDROP)
  hdr:SetBackdropColor(0.045, 0.075, 0.135, 1)
  hdr:SetBackdropBorderColor(0.14, 0.22, 0.34, 0.8)

  local radarSortCol, radarSortAsc = 2, false
  local hdrLabels = {}

  local function MakeHdrCol(colIdx, text, xOff, w, justify)
    local btn = CreateFrame("Button", nil, hdr)
    btn:SetPoint("LEFT", xOff, 0)
    btn:SetSize(w, 18)
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetAllPoints()
    fs:SetJustifyH(justify or "RIGHT")
    fs:SetText("|cff94a3b8" .. text .. "|r")
    hdrLabels[colIdx] = { fs = fs, base = text }
    if colIdx >= 2 then
      btn:SetScript("OnClick", function()
        if radarSortCol == colIdx then
          radarSortAsc = not radarSortAsc
        else
          radarSortCol = colIdx
          radarSortAsc = false
        end
        if NS.RenderInlineRadar then NS.RenderInlineRadar() end
      end)
      btn:SetScript("OnEnter", function(self)
        if GameTooltip then
          GameTooltip:SetOwner(self, "ANCHOR_TOP")
          GameTooltip:AddLine("Клик: сортировать по «" .. text .. "»", 0.0, 0.82, 0.95)
          GameTooltip:Show()
        end
      end)
      btn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
  end

  MakeHdrCol(1, "Товар (ПКМ → Снайп)", 6, 172, "LEFT")
  MakeHdrCol(2, "Score", 182, 48, "RIGHT")
  MakeHdrCol(3, "Пол АХ", 234, 78, "RIGHT")
  MakeHdrCol(4, "Спред", 316, 48, "RIGHT")
  MakeHdrCol(5, "Выкуп/ч", 368, 64, "RIGHT")

  local clearBtn = NS.CreateFlatButton(nil, hdr, 40, 16, "Сброс")
  clearBtn:SetPoint("RIGHT", -3, 0)
  clearBtn:SetColors({ 0.20, 0.08, 0.11, 1 }, { 0.42, 0.12, 0.16, 1 }, { 0.55, 0.18, 0.24, 0.8 }, { 0.95, 0.72, 0.75 })
  clearBtn:SetScript("OnClick", function(self)
    local now = GetTime and GetTime() or 0
    if self._armedAt and (now - self._armedAt) <= 3.0 then
      self._armedAt = nil
      self:SetLabel("Сброс")
      ForeverSniperDB.market = {}
      state.marketLive = {}
      if NS.RenderInlineRadar then NS.RenderInlineRadar() end
      print("|cff06b6d4Goblin Broker:|r данные Сканера ликвидности очищены.")
    else
      self._armedAt = now
      self:SetLabel("Точно?")
    end
  end)

  local rScroll = CreateFrame("ScrollFrame", "ForeverSniperRadarScroll", radarBox, "UIPanelScrollFrameTemplate")
  rScroll:SetPoint("TOPLEFT", 4, -26)
  rScroll:SetPoint("BOTTOMRIGHT", -14, 4)
  local rScrollBar = _G["ForeverSniperRadarScrollScrollBar"]
  if rScrollBar then
    rScrollBar:ClearAllPoints()
    rScrollBar:SetPoint("TOPRIGHT", radarBox, "TOPRIGHT", -3, -26)
    rScrollBar:SetPoint("BOTTOMRIGHT", radarBox, "BOTTOMRIGHT", -3, 4)
    rScrollBar:SetWidth(4)
    local up = _G["ForeverSniperRadarScrollScrollBarScrollUpButton"]
    local dn = _G["ForeverSniperRadarScrollScrollBarScrollDownButton"]
    if up then up:SetAlpha(0); up:EnableMouse(false); up:SetHeight(1) end
    if dn then dn:SetAlpha(0); dn:EnableMouse(false); dn:SetHeight(1) end
    local thumb = rScrollBar:GetThumbTexture()
    if thumb then thumb:SetColorTexture(0.0, 0.71, 0.85, 0.75); thumb:SetWidth(4) end
  end

  local rContent = CreateFrame("Frame", nil, rScroll)
  rContent:SetSize(476, 180)
  rScroll:SetScrollChild(rContent)

  local rEmpty = radarBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  rEmpty:SetPoint("CENTER", 0, -10)
  rEmpty:SetText("|cff64748bНажмите «Старт скан» — здесь вживую появятся Score, Пол АХ и Выкуп/ч|r")

  local radarRows = {}
  local function GetRadarRow(i)
    local row = radarRows[i]
    if not row then
      row = CreateFrame("Button", nil, rContent, "BackdropTemplate")
      row:SetSize(476, 26)
      row:SetBackdrop(NS.FLAT_BACKDROP)
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      row.barFill = row:CreateTexture(nil, "BACKGROUND", nil, 2)
      row.barFill:SetPoint("TOPLEFT", 1, -1)
      row.barFill:SetPoint("BOTTOMLEFT", 1, 1)
      row.barFill:Hide()
      row.ico = row:CreateTexture(nil, "ARTWORK")
      row.ico:SetSize(18, 18); row.ico:SetPoint("LEFT", 5, 0); row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.name:SetPoint("LEFT", row.ico, "RIGHT", 6, 0); row.name:SetWidth(150); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
      row.score = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.score:SetPoint("LEFT", 182, 0); row.score:SetWidth(48); row.score:SetJustifyH("RIGHT"); row.score:SetWordWrap(false)
      row.floor = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.floor:SetPoint("LEFT", 234, 0); row.floor:SetWidth(78); row.floor:SetJustifyH("RIGHT"); row.floor:SetWordWrap(false)
      row.spread = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.spread:SetPoint("LEFT", 316, 0); row.spread:SetWidth(48); row.spread:SetJustifyH("RIGHT"); row.spread:SetWordWrap(false)
      row.drain = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.drain:SetPoint("LEFT", 368, 0); row.drain:SetWidth(64); row.drain:SetJustifyH("RIGHT"); row.drain:SetWordWrap(false)

      row:SetScript("OnEnter", function(self)
        if not GameTooltip or not self.itemID then return end
        local rec = ForeverSniperDB.market and ForeverSniperDB.market[self.itemID]
        if not rec then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Liquidity Score (CLS):", string.format("%d / 100", rec.cls or 0), 0.85, 0.90, 0.96, 0.06, 0.85, 0.55)
        GameTooltip:AddDoubleLine("Пол АХ (якорь):", NS.FormatCoinsPlain(rec.p2 or rec.p1 or 0), 0.85, 0.90, 0.96, 0.98, 0.92, 0.70)
        GameTooltip:AddDoubleLine("Спред 1–2 тир:", string.format("%.1f%%", rec.spreadPct or 0), 0.85, 0.90, 0.96, 0.96, 0.70, 0.03)
        GameTooltip:AddDoubleLine("Стена (+5%) / Объём:", string.format("%d / %d шт", rec.wallQty or 0, rec.totalDepth or 0), 0.85, 0.90, 0.96, 0.85, 0.90, 0.96)
        GameTooltip:AddDoubleLine("Скорость выкупа:", string.format("%.0f шт/ч", rec.vDrain or 0), 0.85, 0.90, 0.96, 0.06, 0.85, 0.55)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("ЛКМ: выбрать  |  ПКМ: добавить в Снайпер (-15%)", 0.0, 0.82, 0.95)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
      row:SetScript("OnClick", function(self, btn)
        local id = self.itemID
        if not id then return end
        if btn == "RightButton" then
          local rec = ForeverSniperDB.market and ForeverSniperDB.market[id]
          local floorP = rec and (rec.p2 or rec.p1) or 0
          if floorP > 0 then
            local targetP = math.max(1, math.floor(floorP * 0.85))
            ForeverSniperDB.watchlist = ForeverSniperDB.watchlist or {}
            ForeverSniperDB.watchlist[id] = targetP
            ForeverSniperDB.tracked = ForeverSniperDB.tracked or {}
            ForeverSniperDB.tracked[id] = true
            ForeverSniperDB.selectedID = id
            if NS.SyncActivePresetSnapshot then NS.SyncActivePresetSnapshot() end
            if NS.SetScanMode then NS.SetScanMode("sniper") end
            if NS.UpdateStatus then NS.UpdateStatus() end
            if NS.SyncInputsFromSelected then NS.SyncInputsFromSelected() end
            local _, nm = NS.GetItemVisuals(id)
            print(string.format("|cff10b981Goblin Broker:|r добавлен в Снайпер: %s <= %s (-15%% от пола %s).", nm or id, NS.FormatCoinsPlain(targetP), NS.FormatCoinsPlain(floorP)))
          end
        else
          ForeverSniperDB.selectedID = id
          if NS.UpdateStatus then NS.UpdateStatus() end
          if NS.SyncInputsFromSelected then NS.SyncInputsFromSelected() end
        end
      end)
      radarRows[i] = row
    end
    return row
  end

  NS.RenderInlineRadar = function()
    if not radarBox:IsShown() then return end
    for idx, info in pairs(hdrLabels) do
      if idx == radarSortCol then
        info.fs:SetText("|cff06b6d4" .. info.base .. (radarSortAsc and " ▲" or " ▼") .. "|r")
      else
        info.fs:SetText("|cff94a3b8" .. info.base .. "|r")
      end
    end

    local db = EnsureMarketDB()
    local keys = {}
    for id in pairs(db) do table.insert(keys, id) end
    table.sort(keys, function(a, b)
      local ra, rb = db[a], db[b]
      local va, vb
      if radarSortCol == 3 then va, vb = ra.p2 or ra.p1 or 0, rb.p2 or rb.p1 or 0
      elseif radarSortCol == 4 then va, vb = ra.spreadPct or 0, rb.spreadPct or 0
      elseif radarSortCol == 5 then va, vb = ra.vDrain or 0, rb.vDrain or 0
      else va, vb = ra.cls or 0, rb.cls or 0 end
      if va ~= vb then return radarSortAsc and (va < vb) or (va > vb) end
      return (ra.vDrain or 0) > (rb.vDrain or 0)
    end)

    for _, r in ipairs(radarRows) do r:Hide() end
    local nowSys = time and time() or 0
    local y = 0
    for i, id in ipairs(keys) do
      local rec = db[id]
      local row = GetRadarRow(i)
      row.itemID = id
      row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
      row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
      row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.45)

      local icon, nm, r, g, b = NS.GetItemVisuals(id)
      row.ico:SetTexture(icon)
      row.name:SetText(nm); row.name:SetTextColor(r, g, b)

      local cls = rec.cls or 0
      if cls > 0 then
        row.barFill:SetWidth(math.max(4, math.floor(474 * (cls / 100))))
        row.barFill:SetColorTexture(cls >= 70 and 0.06 or 0.0, cls >= 70 and 0.73 or 0.71, cls >= 70 and 0.51 or 0.85, 0.14)
        row.barFill:Show()
      else
        row.barFill:Hide()
      end

      local stale = (nowSys > 0 and (nowSys - (rec.updatedAt or 0)) > STALE_SECONDS)
      local scCol = (rec.scans or 0) < 3 and "|cff64748b" or (cls >= 70 and "|cff10b981" or (cls >= 45 and "|cfff59e0b" or "|cfff43f5e"))
      row.score:SetText((rec.scans or 0) < 3 and "|cff64748b...|r" or string.format("%s%d|r%s", scCol, cls, stale and "|cff64748b*|r" or ""))
      row.floor:SetText((rec.p2 or 0) > 0 and NS.FormatCoins(rec.p2) or "|cff475569—|r")
      row.spread:SetText(string.format("|cfff59e0b%.1f%%|r", rec.spreadPct or 0))
      row.drain:SetText((rec.vDrain or 0) > 0.5 and string.format("|cff10b981%.0f/ч|r", rec.vDrain) or "|cff64748b0/ч|r")
      row:Show()
      y = y + 28
    end

    rContent:SetHeight(math.max(180, y))
    if #keys == 0 then rEmpty:Show() else rEmpty:Hide() end
    if rScrollBar then
      if #keys <= 6 then rScrollBar:Hide() else rScrollBar:Show() end
    end
    if NS.dealDelta and state.scanMode == "scanner" then
      NS.dealDelta:SetText(string.format("|cff06b6d4Собрано: %d поз.|r", #keys))
    end
  end

  NS.ExportLiquidityModal = function()
    local db = EnsureMarketDB()
    local keys = {}
    for id in pairs(db) do table.insert(keys, id) end
    table.sort(keys, function(a, b) return (db[a].cls or 0) > (db[b].cls or 0) end)
    local lines = { "LIQ;id;name;score;floor;spreadPct;wallQty;drainPerHour;totalDepth" }
    for _, id in ipairs(keys) do
      local rec = db[id]
      local _, nm = NS.GetItemVisuals(id)
      table.insert(lines, string.format("LIQ;%d;%s;%d;%d;%.1f;%d;%.0f;%d",
        id, (nm or tostring(id)):gsub(";", ","), rec.cls or 0, rec.p2 or rec.p1 or 0,
        rec.spreadPct or 0, rec.wallQty or 0, rec.vDrain or 0, rec.totalDepth or 0))
    end
    if NS.OpenExportModal then
      NS.OpenExportModal("Экспорт Ликвидности АХ (Ctrl+C)", table.concat(lines, "\n"))
    end
  end
end
