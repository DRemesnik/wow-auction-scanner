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
    UpdateMarketMetrics(itemID, nil, 0, nil, 0, 0, 0, 0)
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
        -- Bait guard: if 1st tier is <= 2 pcs and >12% cheaper, p2 is real anchor
        p2 = res.unitPrice
      end
      local anchor = p2 or p1
      if res.unitPrice <= anchor * 1.05 then
        wallQty = wallQty + q
      end
    end
  end
  if not p2 then p2 = p1 end
  local spreadPct = (p1 and p1 > 0 and p2) and (((p2 - p1) / p1) * 100) or 0
  UpdateMarketMetrics(itemID, p1, q1, p2, totalDepth, numTiers, wallQty, spreadPct)
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

-- ============================================================================
-- Mode Switcher in ToolRail ("Снайпер" <-> "Сканер рынка")
-- ============================================================================
if NS.toolRail and NS.miniBtn and NS.CreateFlatButton then
  local modeBtn = NS.CreateFlatButton(nil, NS.toolRail, 28, 26, "")
  modeBtn:SetPoint("TOPLEFT", NS.miniBtn, "BOTTOMLEFT", 0, -5)
  modeBtn:SetPoint("TOPRIGHT", NS.miniBtn, "BOTTOMRIGHT", 0, -5)
  local ico = modeBtn:CreateTexture(nil, "ARTWORK")
  ico:SetSize(18, 18)
  ico:SetPoint("LEFT", 5, 0)
  ico:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_20")
  ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  modeBtn.ico = ico

  local txt = modeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  txt:SetPoint("LEFT", 28, 0)
  txt:SetPoint("RIGHT", -4, 0)
  txt:SetJustifyH("LEFT")
  txt:SetWordWrap(false)
  txt:SetText("Режим: Снайп")
  txt:Hide()
  modeBtn.railText = txt
  if NS.railButtons then table.insert(NS.railButtons, modeBtn) end

  -- Re-anchor soundBtn below modeBtn
  if NS.soundBtn then
    NS.soundBtn:ClearAllPoints()
    NS.soundBtn:SetPoint("TOPLEFT", modeBtn, "BOTTOMLEFT", 0, -5)
    NS.soundBtn:SetPoint("TOPRIGHT", modeBtn, "BOTTOMRIGHT", 0, -5)
  end

  local function RefreshModeUI()
    local isScanner = (state.scanMode == "scanner")
    if isScanner then
      modeBtn:SetColors({ 0.04, 0.22, 0.30, 1 }, { 0.06, 0.30, 0.40, 1 }, { 0.0, 0.71, 0.85, 0.9 }, { 0.85, 0.98, 1 })
      modeBtn.railText:SetText("|cff06b6d4Сканер рынка|r")
      if NS.dealStripe then NS.dealStripe:SetColorTexture(0.0, 0.71, 0.85, 1) end
      if NS.dealCard then NS.dealCard:SetBackdropBorderColor(0.0, 0.71, 0.85, 0.75) end
      if NS.dealBadge then NS.dealBadge:SetText("|cff06b6d4РЕЖИМ СКАНЕРА — СБОР ЛИКВИДНОСТИ (БЕЗ ВЫКУПА)|r") end
      if NS.dealTitle then NS.dealTitle:SetText("|cffcbd5e1Нажмите «Старт скан» для сбора статистики по списку|r") end
      if NS.dealDelta then NS.dealDelta:SetText("|cff64748bДанные сохраняются в ForeverSniperDB.market при /reload или выходе|r") end
    else
      modeBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.18, 0.24, 0.34, 1 }, { 0.85, 0.90, 0.96 })
      modeBtn.railText:SetText("|cff94a3b8Режим: Снайп|r")
    end
  end

  modeBtn:SetScript("OnClick", function()
    if state.scanMode == "scanner" then
      state.scanMode = "sniper"
      print("|cff10b981Goblin Broker:|r переключён в боевой режим |cffffffffСнайпер|r.")
    else
      state.scanMode = "scanner"
      if NS.ClearPendingDeal then NS.ClearPendingDeal(false, true) end
      print("|cff06b6d4Goblin Broker:|r переключён в режим |cffffffffСканер ликвидности|r (покупки отключены).")
    end
    RefreshModeUI()
    if NS.UpdateStatus then NS.UpdateStatus() end
  end)

  modeBtn:HookScript("OnEnter", function(self)
    if ForeverSniperDB.railExpanded then return end
    if GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(state.scanMode == "scanner" and "Режим: Сканер ликвидности" or "Режим: Снайпер", 0.0, 0.82, 0.95)
      GameTooltip:AddLine("Клик: переключить между боевым снайпером и сбором аналитики ликвидности по всему списку.", 0.85, 0.90, 0.96, true)
      GameTooltip:Show()
    end
  end)
  modeBtn:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  NS.RefreshModeUI = RefreshModeUI
end

-- ============================================================================
-- 6th Analytics Tab: "Ликвидность" inside logFrame
-- ============================================================================
if NS.logFrame and NS.tabSalesBtn and NS.CreateFlatButton then
  local tabLiqBtn = NS.CreateFlatButton(nil, NS.logFrame, 112, 22, "Ликвидность")
  tabLiqBtn:SetPoint("LEFT", NS.tabSalesBtn, "RIGHT", 8, 0)
  NS.tabLiqBtn = tabLiqBtn
  tabLiqBtn:SetScript("OnClick", function()
    NS.SetLogTab("liquidity")
  end)
end

NS.RenderLiquidityTab = function(kpiQtyCard, kpiSpentCard, kpiAvgCard, ac1, ac2, ac3, ac4, ac5, ac6, ac7, GetAnaRow, anaContent, anaEmpty, anaScrollBar)
  local db = EnsureMarketDB()
  local keys = {}
  local topScoreID, topScore = nil, -1
  local topDrainID, topDrain = nil, -1
  local topSpreadID, topSpread = nil, -1

  for id, rec in pairs(db) do
    table.insert(keys, id)
    if (rec.cls or 0) > topScore then topScore = rec.cls or 0; topScoreID = id end
    if (rec.vDrain or 0) > topDrain then topDrain = rec.vDrain or 0; topDrainID = id end
    if (rec.spreadPct or 0) > topSpread then topSpread = rec.spreadPct or 0; topSpreadID = id end
  end

  table.sort(keys, function(a, b)
    local ca, cb = db[a].cls or 0, db[b].cls or 0
    if ca ~= cb then return ca > cb end
    return (db[a].vDrain or 0) > (db[b].vDrain or 0)
  end)

  kpiQtyCard.lbl:SetText("|cff06b6d4ГОРЯЧИЙ ЛОТ (SCORE)|r")
  kpiQtyCard.val:SetFontObject("GameFontNormal")
  if topScoreID then
    local _, nm = NS.GetItemVisuals(topScoreID)
    kpiQtyCard.val:SetText(string.format("|cff10b981%d/100|r · %s", topScore, nm))
  else
    kpiQtyCard.val:SetText("|cff64748bНет данных|r")
  end

  kpiSpentCard.lbl:SetText("|cff94a3b8БЫСТРЫЙ ВЫКУП (DRAIN/Ч)|r")
  if topDrainID and topDrain > 0 then
    local _, nm = NS.GetItemVisuals(topDrainID)
    kpiSpentCard.val:SetText(string.format("|cffffffff%.0f шт/ч|r · %s", topDrain, nm))
  else
    kpiSpentCard.val:SetText("|cff64748b—|r")
  end

  kpiAvgCard.lbl:SetText("|cff94a3b8МАКС. СПРЕД|r")
  if topSpreadID and topSpread > 0 then
    local _, nm = NS.GetItemVisuals(topSpreadID)
    kpiAvgCard.val:SetText(string.format("|cfff59e0b%.1f%%|r · %s", topSpread, nm))
  else
    kpiAvgCard.val:SetText("|cff64748b—|r")
  end

  ac1:SetText("|cff94a3b8Предмет|r"); ac2:SetText("|cff94a3b8Score|r"); ac3:SetText("|cff94a3b8Пол АХ|r")
  ac4:SetText("|cff94a3b8Спред %|r"); ac5:SetText("|cff94a3b8Стена +5%|r")
  ac6:SetText("|cff94a3b8Выкуп/ч|r"); ac6:Show()
  ac7:SetText("|cff94a3b8Объём АХ|r"); ac7:Show()

  local nowSys = time and time() or 0
  local y = 0
  for i, id in ipairs(keys) do
    local rec = db[id]
    local row = GetAnaRow(i)
    row.liqItemID = id
    row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
    row:SetBackdropColor(i % 2 == 1 and 0.055 or 0.040, i % 2 == 1 and 0.078 or 0.058, i % 2 == 1 and 0.135 or 0.105, 1)
    row:SetBackdropBorderColor(0.14, 0.20, 0.30, 0.35)

    local icon, nm, r, g, b = NS.GetItemVisuals(id)
    row.ico:SetTexture(icon); row.ico:Show()
    row.c1:ClearAllPoints(); row.c1:SetPoint("LEFT", row.ico, "RIGHT", 6, 0); row.c1:SetWidth(126)
    row.c1:SetText(nm); row.c1:SetTextColor(r, g, b)

    local cls = rec.cls or 0
    if cls > 0 then
      row.barFill:SetWidth(math.max(6, math.floor(680 * (cls / 100))))
      row.barFill:SetColorTexture(cls >= 70 and 0.06 or 0.0, cls >= 70 and 0.73 or 0.71, cls >= 70 and 0.51 or 0.85, 0.14)
      row.barFill:Show()
    else
      row.barFill:Hide()
    end

    local stale = (nowSys > 0 and (nowSys - (rec.updatedAt or 0)) > STALE_SECONDS)
    local scCol = (rec.scans or 0) < 3 and "|cff64748b" or (cls >= 70 and "|cff10b981" or (cls >= 45 and "|cfff59e0b" or "|cfff43f5e"))
    row.c2:SetText((rec.scans or 0) < 3 and "|cff64748bПРОГРЕВ|r" or string.format("%s%d|r%s", scCol, cls, stale and "|cff64748b*|r" or ""))
    row.c3:SetText((rec.p2 or 0) > 0 and NS.FormatCoins(rec.p2) or "|cff475569—|r")
    row.c4:SetText(string.format("|cfff59e0b%.1f%%|r", rec.spreadPct or 0))
    row.c5:SetText(string.format("%d шт", rec.wallQty or 0))
    row.c6:Show()
    row.c6:SetText((rec.vDrain or 0) > 0.5 and string.format("|cff10b981%.0f/ч|r", rec.vDrain) or "|cff64748b0/ч|r")
    row.c7:Show()
    row.c7:SetText(string.format("|cffffffff%d шт|r", rec.totalDepth or 0))
    row:Show(); y = y + 26
  end

  anaContent:SetHeight(math.max(380, y))
  anaEmpty:SetText("|cff64748bВключите режим «Сканер рынка» и нажмите «Старт скан»|r")
  if y == 0 then anaEmpty:Show() else anaEmpty:Hide() end
  if anaScrollBar then
    if y <= 380 then anaScrollBar:Hide() else anaScrollBar:Show() end
  end
end
