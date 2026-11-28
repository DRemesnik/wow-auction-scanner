local ADDON_NAME, NS = ...
if not NS or not NS.f then return end

local f = NS.f
local state = NS.state

-- ============================================================================
-- MarketScanner: Robust Order-Book Analytics, Anti-Churn Drain & Confidence
-- (0% Ban Risk, 100% Read-Only)
-- ============================================================================
local TOP_K_TIERS = 20
local MAX_MARKET_ITEMS = 250
local FRESH_LIVE_SEC = 120    -- < 2m: LIVE
local FRESH_OK_SEC   = 900    -- < 15m: Fresh
local STALE_SECONDS  = 3600   -- >= 1h: Stale
local DRAIN_MIN_DT   = 8.0    -- minimum seconds between drain baseline snapshots

local function EnsureMarketDB()
  ForeverSniperDB.market = ForeverSniperDB.market or {}
  return ForeverSniperDB.market
end

-- Staleness-First Smart Scheduler: picks the oldest/unscanned item in pool first
-- so large lists (up to 100+ items) reach 100% fresh coverage as fast as possible
NS.PickNextScannerItem = function(pool)
  if not pool or #pool == 0 then return nil, 0 end
  local db = EnsureMarketDB()
  local lastID = state.scanningItemID
  local bestIdx, bestID, bestTs = nil, nil, nil

  for i, id in ipairs(pool) do
    if #pool == 1 or id ~= lastID then
      local rec = db[id]
      local ts = (rec and rec.updatedAt) or 0
      -- Give slight priority boost to completely unscanned items (scans == 0)
      if not rec or (rec.scans or 0) == 0 then ts = -1 end
      if not bestTs or ts < bestTs then
        bestTs = ts
        bestIdx = i
        bestID = id
      end
    end
  end

  if not bestID then
    bestIdx = 1
    bestID = pool[1]
  end
  return bestID, bestIdx
end

local function ComputeConfidence(rec, nowSys)
  local scans = rec.scans or 0
  local scanPts = math.min(40, scans * 8)
  local spanSec = (rec.firstSeenAt and rec.firstSeenAt > 0 and nowSys and nowSys > rec.firstSeenAt)
    and (nowSys - rec.firstSeenAt) or 0
  local spanPts = math.min(30, math.floor((spanSec / 60) * 5))
  local ageSec = (rec.updatedAt and rec.updatedAt > 0 and nowSys and nowSys > 0)
    and math.max(0, nowSys - rec.updatedAt) or 999999
  local freshPts = 0
  if ageSec < 300 then freshPts = 30
  elseif ageSec < 900 then freshPts = 22
  elseif ageSec < 3600 then freshPts = 12
  else freshPts = 0 end
  return math.min(100, scanPts + spanPts + freshPts)
end

local function FormatAgeBadge(updatedAt, nowSys)
  if not updatedAt or updatedAt <= 0 or not nowSys or nowSys <= 0 then
    return "|cff64748bнет данных|r", "Нет данных", 999999
  end
  local age = math.max(0, nowSys - updatedAt)
  if age < FRESH_LIVE_SEC then
    return string.format("|cff10b981%dс назад (LIVE)|r", age), string.format("%dс", age), age
  elseif age < FRESH_OK_SEC then
    local m = math.floor(age / 60)
    return string.format("|cff38bdf8%dм назад (Свежие)|r", m), string.format("%dм", m), age
  elseif age < STALE_SECONDS then
    local m = math.floor(age / 60)
    return string.format("|cfff59e0b%dм назад (Устаревают)|r", m), string.format("%dм", m), age
  else
    local h = math.floor(age / 3600)
    if h >= 24 then
      local d = math.floor(h / 24)
      return string.format("|cfff43f5e%dд назад (Старые)|r", d), string.format("%dд", d), age
    end
    return string.format("|cfff43f5e%dч назад (Старые)|r", h), string.format("%dч", h), age
  end
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

local function ComputeSniperScore(rec)
  local dips = rec.dipCount or 0
  local depth = rec.dipDepthAvg or 0
  local dur = rec.dipDurAvg or 0
  local reb = rec.reboundRatio or 0.95
  local cls = rec.cls or 0
  local floorP = rec.emaFloor or rec.p2 or rec.p1 or 0
  -- 1. Dip Frequency (0-30)
  local freqScore = 30 * math.min(1, dips / 6)
  -- 2. Expected Copper Profit per Dip (0-25; 1g+ = full marks)
  local expProfit = floorP * (math.max(0, depth) / 100)
  local profitScore = 25 * math.min(1, expProfit / 10000)
  -- 3. Reaction Window / Anti-Bot Score (0-20)
  local winScore = 10
  if dur > 0 then
    if dur < 0.8 then winScore = 2
    elseif dur < 2.0 then winScore = 10
    elseif dur <= 45.0 then winScore = 20
    else winScore = 14 end
  end
  -- 4. Rebound Safety (0-15; avoids falling knives)
  local rebScore = 15 * math.max(0, math.min(1, (reb - 0.80) / 0.18))
  -- 5. Base Liquidity CLS (0-10)
  local clsScore = 0.10 * cls
  return math.floor(freqScore + profitScore + winScore + rebScore + clsScore + 0.5)
end

local function UpdateMarketMetrics(itemID, p1, q1, p2, totalDepth, tiers, wallQty, spreadPct, wall10Qty, wall15Qty, resetCost15)
  if not itemID or not p1 or p1 <= 0 then return end
  local db = EnsureMarketDB()
  local nowSys = time and time() or 0
  local nowMono = GetTime and GetTime() or 0

  local live = state.marketLive and state.marketLive[itemID]
  if not state.marketLive then state.marketLive = {}; live = nil end
  local rec = db[itemID]
  if not rec then
    rec = {
      p1 = p1, q1 = q1 or 0, p2 = p2 or p1, emaFloor = p2 or p1,
      totalDepth = totalDepth or 0, tiers = tiers or 1,
      wallQty = wallQty or 0, wall10Qty = wall10Qty or 0, wall15Qty = wall15Qty or 0,
      resetCost15 = resetCost15 or 0,
      spreadPct = spreadPct or 0,
      vDrain = 0, cri = 0, cls = 0, sniperScore = 0,
      dipCount = 0, dipDepthAvg = 0, dipDurAvg = 0, reboundRatio = 0.96,
      scans = 0, firstSeenAt = nowSys, updatedAt = nowSys,
    }
    db[itemID] = rec
    PruneMarketDB()
  end

  local anchor = p2 or p1
  local prevEma = rec.emaFloor or anchor
  if not live then
    live = {}
    state.marketLive[itemID] = live
  end

  -- Robust Drain & Churn Estimator:
  -- Requires dt >= DRAIN_MIN_DT (8s) so micro-ticks don't explode vDrain,
  -- and cross-checks BOTH wallQty AND totalDepth drop to filter cancel-repost noise!
  if live.drainMonoAt and (nowMono - live.drainMonoAt) >= DRAIN_MIN_DT and (nowMono - live.drainMonoAt) <= 600 then
    local dt = nowMono - live.drainMonoAt
    local prevAnchor = live.drainAnchor or anchor
    local prevWall = live.drainWallQty or 0
    local prevTotal = live.drainTotalDepth or 0

    local wallDrop = math.max(0, prevWall - (wallQty or 0))
    local totalDrop = math.max(0, prevTotal - (totalDepth or 0))
    -- Real sale reduces BOTH wall and total market depth; pure repost keeps totalDepth flat
    local absorbed = 0
    if anchor >= (prevAnchor * 0.99) and wallDrop > 0 then
      absorbed = (totalDrop > 0) and math.min(wallDrop, totalDrop) or math.floor(wallDrop * 0.25)
    end
    local rawDrainHour = (absorbed / dt) * 3600
    -- Winsorize single-tick spikes (e.g., giant stack cancellation) to keep vDrain trustworthy
    local prevDrain = rec.vDrain or 0
    local maxReasonable = math.max(120, prevDrain * 4 + 45)
    local instDrainHour = math.min(rawDrainHour, maxReasonable)
    local tau = (absorbed > 0) and 150 or 300
    local alpha = 1 - math.exp(-dt / tau)
    rec.vDrain = math.floor((prevDrain * (1 - alpha) + instDrainHour * alpha) * 10 + 0.5) / 10

    -- Cancel-Repost / Churn Index (CRI): micro price flips without real depth drain
    local priceDiffPct = (prevAnchor > 0) and math.abs(anchor - prevAnchor) / prevAnchor or 0
    local depthDiffPct = (prevTotal > 0) and math.abs((totalDepth or 0) - prevTotal) / prevTotal or 0
    local isChurn = (priceDiffPct > 0 and priceDiffPct <= 0.03 and depthDiffPct < 0.05) and 1 or 0
    rec.cri = math.floor(((rec.cri or 0) * 0.85 + isChurn * 0.15) * 100 + 0.5) / 100

    live.drainMonoAt = nowMono
    live.drainAnchor = anchor
    live.drainWallQty = wallQty or 0
    live.drainTotalDepth = totalDepth or 0
  elseif not live.drainMonoAt or (nowMono - live.drainMonoAt) > 600 then
    live.drainMonoAt = nowMono
    live.drainAnchor = anchor
    live.drainWallQty = wallQty or 0
    live.drainTotalDepth = totalDepth or 0
  end

  -- Snipe Telemetry: track dip frequency, depth %, lifetime (sec), hour heatmap & rebound ratio
  if (rec.scans or 0) >= 2 and prevEma and prevEma > 0 then
    if p1 <= prevEma * 0.88 then
      local depthPct = ((prevEma - p1) / prevEma) * 100
      if not live.dipActiveAt then
        live.dipActiveAt = nowMono
        live.dipRefFloor = prevEma
        rec.dipCount = (rec.dipCount or 0) + 1
        rec.dipDepthAvg = ((rec.dipDepthAvg or 0) > 0)
          and (rec.dipDepthAvg * 0.7 + depthPct * 0.3)
          or depthPct
        rec.dipDepthAvg = math.floor(rec.dipDepthAvg * 10 + 0.5) / 10
        local hr = (date and date("%H")) or "00"
        rec.dipsByHour = rec.dipsByHour or {}
        rec.dipsByHour[hr] = (rec.dipsByHour[hr] or 0) + 1
      end
    elseif live.dipActiveAt and p1 > (live.dipRefFloor or prevEma) * 0.92 then
      local dur = math.max(0.5, math.min(600, nowMono - live.dipActiveAt))
      rec.dipDurAvg = ((rec.dipDurAvg or 0) > 0)
        and (rec.dipDurAvg * 0.7 + dur * 0.3)
        or dur
      rec.dipDurAvg = math.floor(rec.dipDurAvg * 10 + 0.5) / 10
      local refF = live.dipRefFloor or prevEma
      local reb = math.max(0.5, math.min(1.5, p1 / refF))
      rec.reboundRatio = math.floor((((rec.reboundRatio or 0.96) * 0.75 + reb * 0.25) * 100) + 0.5) / 100
      live.dipActiveAt = nil
      live.dipRefFloor = nil
    end
  end

  live.p1 = p1
  live.p2 = anchor
  live.totalDepth = totalDepth or 0
  live.wallQty = wallQty or 0
  live.monoAt = nowMono

  rec.p1 = p1
  rec.q1 = q1 or 0
  rec.p2 = anchor
  -- Clamp single-tick EMA jump to +/-25% so temporary AH glitches never corrupt baseline floor
  local clampedAnchor = anchor
  if prevEma and prevEma > 0 and (rec.scans or 0) >= 2 then
    clampedAnchor = math.max(math.floor(prevEma * 0.75), math.min(math.ceil(prevEma * 1.25), anchor))
  end
  rec.emaFloor = math.floor(((rec.emaFloor or clampedAnchor) * 0.8 + clampedAnchor * 0.2) + 0.5)
  rec.totalDepth = totalDepth or 0
  rec.tiers = tiers or 1
  rec.wallQty = wallQty or 0
  rec.wall10Qty = wall10Qty or 0
  rec.wall15Qty = wall15Qty or 0
  rec.resetCost15 = resetCost15 or 0
  rec.spreadPct = math.floor((spreadPct or 0) * 10 + 0.5) / 10
  rec.scans = (rec.scans or 0) + 1
  if not rec.firstSeenAt or rec.firstSeenAt == 0 then rec.firstSeenAt = nowSys end
  rec.updatedAt = nowSys
  rec.cls = ComputeCLS(rec.vDrain or 0, rec.tiers, rec.spreadPct, rec.cri or 0, rec.wallQty)
  rec.sniperScore = ComputeSniperScore(rec)
  rec.confidence = ComputeConfidence(rec, nowSys)
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
      rec.wall10Qty = 0
      rec.wall15Qty = 0
      rec.resetCost15 = 0
      rec.updatedAt = time and time() or 0
    end
    return
  end

  -- Pass 1: collect valid tiers & compute Cumulative-Qty Robust Floor (immune to 1-3 pc bait stacks)
  local readMax = math.min(numTiers, TOP_K_TIERS)
  local tiersData = {}
  local p1, q1, p2Raw = nil, 0, nil
  for i = 1, readMax do
    local res = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if res and res.unitPrice and res.unitPrice > 0 and (res.quantity or 0) > 0 then
      local up, q = res.unitPrice, res.quantity
      if not p1 then p1 = up; q1 = q
      elseif not p2Raw then p2Raw = up end
      table.insert(tiersData, { p = up, q = q })
    end
  end
  -- Incomplete Snapshot Guard: skip corrupted/unloaded AH ticks
  if #tiersData == 0 or not p1 or p1 <= 0 then return end

  local minAnchorQty = (totalDepth <= 5) and 1 or math.min(10, math.max(3, math.floor(totalDepth * 0.03)))
  local cumQ = 0
  local robustFloor = p2Raw or p1
  for _, t in ipairs(tiersData) do
    cumQ = cumQ + t.q
    if cumQ >= minAnchorQty then
      robustFloor = t.p
      break
    end
  end

  -- Pass 2: compute clean walls (+5% / +10% / +15%) & reset cost relative to robustFloor
  local wallQty, wall10Qty, wall15Qty, resetCost15 = 0, 0, 0, 0
  for _, t in ipairs(tiersData) do
    if t.p <= robustFloor * 1.05 then wallQty = wallQty + t.q end
    if t.p <= robustFloor * 1.10 then wall10Qty = wall10Qty + t.q end
    if t.p <= robustFloor * 1.15 then
      wall15Qty = wall15Qty + t.q
      resetCost15 = resetCost15 + (t.p * t.q)
    end
  end
  local spreadPct = (p1 > 0 and robustFloor > p1) and (((robustFloor - p1) / p1) * 100) or 0
  UpdateMarketMetrics(itemID, p1, q1, robustFloor, totalDepth, numTiers, wallQty, spreadPct, wall10Qty, wall15Qty, resetCost15)
end

-- Called from ITEM_SEARCH_RESULTS_UPDATED
NS.OnScannerItem = function(itemKey, itemID)
  if not itemID or not itemKey or not C_AuctionHouse then return end
  local num = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
  if num == 0 then
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
  local p1, p2 = nil, nil
  local wallQty, wall10Qty, wall15Qty, resetCost15 = 0, 0, 0, 0
  local readMax = math.min(num, 12)
  for i = 1, readMax do
    local res = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if res and res.buyoutAmount and res.buyoutAmount > 0 then
      if not p1 then p1 = res.buyoutAmount
      elseif not p2 then p2 = res.buyoutAmount end
      local anchor = p2 or p1
      if res.buyoutAmount <= anchor * 1.05 then
        wallQty = wallQty + 1
      end
      if res.buyoutAmount <= anchor * 1.10 then
        wall10Qty = wall10Qty + 1
      end
      if res.buyoutAmount <= anchor * 1.15 then
        wall15Qty = wall15Qty + 1
        resetCost15 = resetCost15 + res.buyoutAmount
      end
    end
  end
  if not p2 then p2 = p1 end
  local spreadPct = (p1 and p1 > 0 and p2) and (((p2 - p1) / p1) * 100) or 0
  UpdateMarketMetrics(itemID, p1, 1, p2, num, num, wallQty, spreadPct, wall10Qty, wall15Qty, resetCost15)
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
-- Dedicated Full-Height Scanner Workspace (v2.6.0)
-- Designed specifically for bulk market reconnaissance (up to 100+ items):
--   Filter Bar (Active List default!) -> Full-Height Table with Live Row Highlight
--   -> Live "Currently Scanning" Card + Progress Bar
--   -> Hero CTA [Radar Icon + СКАНИРОВАТЬ ВЕСЬ СПИСОК] + [Экспорт]
-- ============================================================================
if NS.presetBar and NS.CreateFlatButton and NS.FLAT_BACKDROP then
  local RADAR_ICON_PATH = "Interface\\AddOns\\ForeverSniper\\radar_scan.tga"

  local scannerView = CreateFrame("Frame", nil, f)
  scannerView:SetPoint("TOPLEFT", NS.presetBar, "BOTTOMLEFT", 0, -6)
  scannerView:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
  scannerView:Hide()
  f._scannerView = scannerView

  -- Table Card (Modern Obsidian rounded surface)
  local radarBox = CreateFrame("Frame", nil, scannerView, "BackdropTemplate")
  radarBox:SetPoint("TOPLEFT", 0, 0)
  radarBox:SetPoint("BOTTOMRIGHT", 0, 114)
  radarBox:SetBackdrop(NS.FLAT_BACKDROP)
  if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(radarBox, "panel") end
  radarBox:SetBackdropColor(0.072, 0.082, 0.114, 1)
  radarBox:SetBackdropBorderColor(1, 1, 1, 0.06)
  f._radarBox = radarBox

  -- Quick Filter Bar: Default = "list" (active scan pool so user ALWAYS sees what they scan!)
  local filterBar = CreateFrame("Frame", nil, radarBox)
  filterBar:SetPoint("TOPLEFT", 4, -4)
  filterBar:SetPoint("TOPRIGHT", -4, -4)
  filterBar:SetHeight(22)

  local activeFilter = "list"
  local filterBtns = {}
  local FILTER_DEFS = {
    { key = "list",   label = "Список",     w = 82 },
    { key = "all",    label = "Вся база",   w = 88 },
    { key = "ready",  label = "Готовые",    w = 68 },
    { key = "needed", label = "Нужен скан", w = 84 },
  }

  local function RefreshFilterButtons()
    for _, def in ipairs(FILTER_DEFS) do
      local b = filterBtns[def.key]
      if b then
        if activeFilter == def.key then
          b:SetColors({ 0.04, 0.24, 0.34, 1 }, { 0.06, 0.32, 0.44, 1 }, { 0.02, 0.71, 0.83, 0.95 }, { 0.90, 0.98, 1 })
        else
          b:SetColors({ 0.05, 0.08, 0.14, 1 }, { 0.09, 0.14, 0.22, 1 }, { 0.16, 0.23, 0.34, 0.85 }, { 0.65, 0.74, 0.85 })
        end
      end
    end
  end

  local fx = 0
  for _, def in ipairs(FILTER_DEFS) do
    local b = NS.CreateFlatButton(nil, filterBar, def.w, 18, def.label)
    b:SetPoint("LEFT", fx, 0)
    b:SetScript("OnClick", function()
      activeFilter = def.key
      RefreshFilterButtons()
      if NS.RenderInlineRadar then NS.RenderInlineRadar() end
    end)
    filterBtns[def.key] = b
    fx = fx + def.w + 4
  end
  RefreshFilterButtons()

  local clearBtn = NS.CreateFlatButton(nil, filterBar, 46, 18, "Сброс")
  clearBtn:SetPoint("RIGHT", 0, 0)
  clearBtn:SetColors({ 0.20, 0.08, 0.11, 1 }, { 0.42, 0.12, 0.16, 1 }, { 0.55, 0.18, 0.24, 0.8 }, { 0.95, 0.72, 0.75 })
  clearBtn:SetScript("OnClick", function(self)
    local now = GetTime and GetTime() or 0
    if self._armedAt and (now - self._armedAt) <= 3.0 then
      self._armedAt = nil
      self:SetLabel("Сброс")
      ForeverSniperDB.market = {}
      state.marketLive = {}
      if NS.RenderInlineRadar then NS.RenderInlineRadar() end
      if NS.RefreshScannerFooter then NS.RefreshScannerFooter() end
      print("|cff38bdf8Goblin Broker:|r данные Сканера ликвидности очищены.")
    else
      self._armedAt = now
      self:SetLabel("Точно?")
    end
  end)

  local hdr = CreateFrame("Frame", nil, radarBox)
  hdr:SetPoint("TOPLEFT", 6, -28)
  hdr:SetPoint("TOPRIGHT", -6, -28)
  hdr:SetHeight(20)
  local hdrLine = hdr:CreateTexture(nil, "ARTWORK")
  hdrLine:SetHeight(1)
  hdrLine:SetPoint("BOTTOMLEFT", 0, 0)
  hdrLine:SetPoint("BOTTOMRIGHT", 0, 0)
  hdrLine:SetColorTexture(1, 1, 1, 0.06)

  local radarSortCol, radarSortAsc = 2, false
  local hdrLabels = {}

  local function MakeHdrCol(colIdx, text, xOff, w, justify, tipTitle, tipBody)
    local btn = CreateFrame("Button", nil, hdr)
    btn:SetPoint("LEFT", xOff, 0)
    btn:SetSize(w, 18)
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetAllPoints()
    fs:SetJustifyH(justify or "RIGHT")
    fs:SetText("|cff94a3b8" .. text .. "|r")
    hdrLabels[colIdx] = { fs = fs, base = text }
    if colIdx >= 2 and colIdx <= 4 then
      btn:SetScript("OnClick", function()
        if radarSortCol == colIdx then
          radarSortAsc = not radarSortAsc
        else
          radarSortCol = colIdx
          radarSortAsc = false
        end
        if NS.RenderInlineRadar then NS.RenderInlineRadar() end
      end)
    end
    btn:SetScript("OnEnter", function(self)
      if colIdx ~= radarSortCol then fs:SetText("|cffe2e8f0" .. text .. "|r") end
      if GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(tipTitle or text, 0.22, 0.74, 0.97)
        if tipBody then GameTooltip:AddLine(tipBody, 0.85, 0.90, 0.96, true) end
        if colIdx >= 2 and colIdx <= 4 then
          GameTooltip:AddLine("Клик: сортировать по этому столбцу", 0.58, 0.66, 0.76)
        end
        GameTooltip:Show()
      end
    end)
    btn:SetScript("OnLeave", function()
      if colIdx ~= radarSortCol then fs:SetText("|cff94a3b8" .. text .. "|r") end
      if GameTooltip then GameTooltip:Hide() end
    end)
  end

  MakeHdrCol(1, "Товар",      6,   178, "LEFT",   "Товар из списка разведки", "ЛКМ: открыть «Детали рынка» · ПКМ: добавить в Снайпер (-12%) и переключиться.")
  MakeHdrCol(2, "Готовность", 188, 86,  "CENTER", "Достоверность статистической модели", "Сбор X/5 — мало замеров. Готово (≥70%) — собрано 5+ свежих замеров, данным можно доверять. Устарело — старше 15 мин.")
  MakeHdrCol(3, "Пол (p1)",   278, 76,  "RIGHT",  "Устойчивый рыночный пол", "Минимальная реальная цена на АХ с защитой от 1–3 шт наживок.")
  MakeHdrCol(4, "Свежесть",   358, 60,  "RIGHT",  "Возраст последнего замера", "Зелёный <2м (LIVE), циан <15м (свежие), янтарь <1ч, красный ≥1ч.")
  MakeHdrCol(5, "Снайпер",    426, 80,  "CENTER", "Быстрый перенос в Снайпер", "1 клик добавляет товар в список Снайпера с авто-лимитом -12% от живого пола, не выходя из Сканера.")

  local rScroll = CreateFrame("ScrollFrame", "ForeverSniperRadarScroll", radarBox, "UIPanelScrollFrameTemplate")
  rScroll:SetPoint("TOPLEFT", 4, -50)
  rScroll:SetPoint("BOTTOMRIGHT", -14, 4)
  local rScrollBar = _G["ForeverSniperRadarScrollScrollBar"]
  if rScrollBar then
    rScrollBar:ClearAllPoints()
    rScrollBar:SetPoint("TOPRIGHT", radarBox, "TOPRIGHT", -3, -50)
    rScrollBar:SetPoint("BOTTOMRIGHT", radarBox, "BOTTOMRIGHT", -3, 4)
    rScrollBar:SetWidth(4)
    local up = _G["ForeverSniperRadarScrollScrollBarScrollUpButton"]
    local dn = _G["ForeverSniperRadarScrollScrollBarScrollDownButton"]
    if up then up:SetAlpha(0); up:EnableMouse(false); up:SetHeight(1) end
    if dn then dn:SetAlpha(0); dn:EnableMouse(false); dn:SetHeight(1) end
    local thumb = rScrollBar:GetThumbTexture()
    if thumb then thumb:SetColorTexture(0.02, 0.71, 0.83, 0.75); thumb:SetWidth(4) end
  end

  local rContent = CreateFrame("Frame", nil, rScroll)
  rContent:SetSize(516, 240)
  rScroll:SetScrollChild(rContent)

  local rEmptyWrap = CreateFrame("Frame", nil, radarBox)
  rEmptyWrap:SetPoint("TOPLEFT", 16, -64)
  rEmptyWrap:SetPoint("BOTTOMRIGHT", -16, 12)
  rEmptyWrap:Hide()
  local rEmptyTitle = rEmptyWrap:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rEmptyTitle:SetPoint("CENTER", 0, 12)
  rEmptyTitle:SetText("|cff38bdf8Список для сканирования пуст|r")
  local rEmpty = rEmptyWrap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  rEmpty:SetPoint("TOP", rEmptyTitle, "BOTTOM", 0, -6)
  rEmpty:SetWidth(420)
  rEmpty:SetJustifyH("CENTER")
  rEmpty:SetText("|cff94a3b8Выберите шаблон сверху или загрузите список через Импорт на левой панели|r")

  -- Live "Currently Scanning" Feedback Card + Progress Bar (54px)
  local progBox = CreateFrame("Frame", nil, scannerView, "BackdropTemplate")
  progBox:SetPoint("TOPLEFT", radarBox, "BOTTOMLEFT", 0, -8)
  progBox:SetPoint("TOPRIGHT", radarBox, "BOTTOMRIGHT", 0, -8)
  progBox:SetHeight(54)
  progBox:SetBackdrop(NS.FLAT_BACKDROP)
  if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(progBox, "panel") end
  progBox:SetBackdropColor(0.078, 0.088, 0.122, 1)
  progBox:SetBackdropBorderColor(1, 1, 1, 0.07)

  local scanIcoBox = CreateFrame("Frame", nil, progBox, "BackdropTemplate")
  scanIcoBox:SetSize(30, 30)
  scanIcoBox:SetPoint("TOPLEFT", 8, -7)
  scanIcoBox:SetBackdrop(NS.FLAT_BACKDROP)
  if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(scanIcoBox, "pill") end
  scanIcoBox:SetBackdropColor(0.043, 0.050, 0.072, 1)
  scanIcoBox:SetBackdropBorderColor(1, 1, 1, 0.08)

  local scanItemIco = scanIcoBox:CreateTexture(nil, "ARTWORK")
  scanItemIco:SetSize(24, 24)
  scanItemIco:SetPoint("CENTER")
  scanItemIco:SetTexture(RADAR_ICON_PATH)

  local progTitle = progBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  progTitle:SetPoint("TOPLEFT", scanIcoBox, "TOPRIGHT", 8, -1)
  progTitle:SetPoint("RIGHT", progBox, "RIGHT", -96, 0)
  progTitle:SetJustifyH("LEFT")
  progTitle:SetWordWrap(false)
  progTitle:SetText("|cfff8fafcГотов к разведке рынка|r")

  local progRight = progBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  progRight:SetPoint("TOPRIGHT", -10, -9)
  progRight:SetJustifyH("RIGHT")
  progRight:SetText("|cff38bdf8В базе: 0 поз.|r")

  local scannerToast = progBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  scannerToast:SetPoint("TOPLEFT", progTitle, "BOTTOMLEFT", 0, -2)
  scannerToast:SetPoint("RIGHT", progBox, "RIGHT", -10, 0)
  scannerToast:SetJustifyH("LEFT")
  scannerToast:SetWordWrap(false)
  scannerToast:SetText("|cff64748bПокупки отключены · Клик [+ Снайп] добавляет с лимитом -12%|r")
  local lastToastAt = 0

  local progBarBg = CreateFrame("Frame", nil, progBox, "BackdropTemplate")
  progBarBg:SetPoint("BOTTOMLEFT", 8, 6)
  progBarBg:SetPoint("BOTTOMRIGHT", -8, 6)
  progBarBg:SetHeight(5)
  progBarBg:SetBackdrop(NS.FLAT_BACKDROP)
  progBarBg:SetBackdropColor(0.02, 0.035, 0.07, 1)
  progBarBg:SetBackdropBorderColor(0.12, 0.18, 0.28, 0.9)

  local progFill = progBarBg:CreateTexture(nil, "ARTWORK")
  progFill:SetPoint("TOPLEFT", 1, -1)
  progFill:SetPoint("BOTTOMLEFT", 1, 1)
  progFill:SetWidth(1)
  progFill:SetColorTexture(0.02, 0.71, 0.83, 0.95)
  progFill:Hide()

  -- Stage milestone markers on progress bar: 33% (Mandatory Scan) & 80% (Statistical Model)
  local progTick1 = progBarBg:CreateTexture(nil, "OVERLAY")
  progTick1:SetSize(1, 5)
  progTick1:SetColorTexture(1, 1, 1, 0.28)
  local progTick2 = progBarBg:CreateTexture(nil, "OVERLAY")
  progTick2:SetSize(1, 5)
  progTick2:SetColorTexture(1, 1, 1, 0.28)

  local function FormatEta(sec)
    sec = math.max(0, math.floor((sec or 0) + 0.5))
    if sec < 5 then return "<5с"
    elseif sec < 60 then return string.format("~%dс", sec)
    else
      local m = math.floor(sec / 60)
      local s = sec % 60
      if s >= 10 then return string.format("~%dм %dс", m, s) end
      return string.format("~%dм", m)
    end
  end

  -- Bottom Hero Action Row: [HERO: Radar Icon + СКАНИРОВАТЬ ВЕСЬ СПИСОК] + [Экспорт]
  local footerRow = CreateFrame("Frame", nil, scannerView)
  footerRow:SetPoint("TOPLEFT", progBox, "BOTTOMLEFT", 0, -8)
  footerRow:SetPoint("TOPRIGHT", progBox, "BOTTOMRIGHT", 0, -8)
  footerRow:SetHeight(44)

  local scannerStartBtn = NS.CreateFlatButton(nil, footerRow, 396, 44, "СКАНИРОВАТЬ ВЕСЬ СПИСОК")
  scannerStartBtn:SetPoint("LEFT", 0, 0)
  scannerStartBtn.label:SetFontObject("GameFontNormalLarge")
  scannerStartBtn.label:ClearAllPoints()
  scannerStartBtn.label:SetPoint("CENTER", 14, 0)

  local heroRadarIco = scannerStartBtn:CreateTexture(nil, "OVERLAY")
  heroRadarIco:SetSize(24, 24)
  heroRadarIco:SetPoint("RIGHT", scannerStartBtn.label, "LEFT", -8, 0)
  heroRadarIco:SetTexture(RADAR_ICON_PATH)

  -- Subtle radar icon rotation while actively scanning (zero cost when idle)
  local rotAngle = 0
  scannerView:SetScript("OnUpdate", function(_, elapsed)
    if ForeverSniperDB.autoScan and state.scanMode == "scanner" then
      rotAngle = (rotAngle - elapsed * 2.4) % (math.pi * 2)
      if heroRadarIco.SetRotation then heroRadarIco:SetRotation(rotAngle) end
    elseif rotAngle ~= 0 then
      rotAngle = 0
      if heroRadarIco.SetRotation then heroRadarIco:SetRotation(0) end
    end
  end)

  scannerStartBtn:SetScript("OnClick", function()
    if NS.ToggleScan then NS.ToggleScan() end
  end)

  local scannerDetailsBtn = NS.CreateFlatButton(nil, footerRow, 136, 44, "Детали рынка")
  scannerDetailsBtn:SetPoint("RIGHT", 0, 0)
  scannerDetailsBtn:SetColors({ 0.10, 0.115, 0.16, 1 }, { 0.15, 0.175, 0.24, 1 }, { 1, 1, 1, 0.10 }, { 0.90, 0.94, 0.98 })

  NS.SetScannerMiniMode = function(isMini)
    if isMini then
      radarBox:Hide()
      progBox:ClearAllPoints()
      progBox:SetPoint("TOPLEFT", scannerView, "TOPLEFT", 0, 0)
      progBox:SetPoint("TOPRIGHT", scannerView, "TOPRIGHT", 0, 0)
    else
      radarBox:Show()
      progBox:ClearAllPoints()
      progBox:SetPoint("TOPLEFT", radarBox, "BOTTOMLEFT", 0, -8)
      progBox:SetPoint("TOPRIGHT", radarBox, "BOTTOMRIGHT", 0, -8)
    end
  end
  scannerDetailsBtn:SetScript("OnClick", function()
    if NS.ToggleMarketDetailsFrame then NS.ToggleMarketDetailsFrame() end
  end)
  scannerDetailsBtn:HookScript("OnEnter", function(self)
    if GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Детальный просмотр рынка", 0.96, 0.70, 0.03)
      GameTooltip:AddLine("Открывает широкую таблицу со всеми метриками: CLS, Sniper Score, стены +5/+10/+15%, цена ресета, выкуп/ч, просадки и экспорт.", 0.85, 0.90, 0.96, true)
      GameTooltip:Show()
    end
  end)
  scannerDetailsBtn:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  NS.RefreshScannerFooter = function()
    if not scannerView then return end
    local pool = state.allItems or {}
    local poolN = #pool
    local db = EnsureMarketDB()
    local nowSys = time and time() or 0
    local collected = 0
    for _, r in pairs(db) do if type(r) == "table" then collected = collected + 1 end end

    if filterBtns.list then
      filterBtns.list:SetLabel("Список (" .. poolN .. ")")
    end
    if filterBtns.all then
      filterBtns.all:SetLabel("Вся база (" .. collected .. ")")
    end

    -- 3-Stage Statistical Model Progress & Time-to-Completion (ETA)
    -- Stage 1 (0..33%):  ОБЯЗАТЕЛЬНЫЙ СКАН — fresh price/wall pass over every item in pool
    -- Stage 2 (33..80%): СТАТ. МОДЕЛЬ — 5+ scans & >=5m span so vDrain/CLS/deviations converge (conf >= 70%)
    -- Stage 3 (80..100%): ПОЛИРОВКА ДЕТАЛЕЙ — model confirmed, longer run deepens dip/hour accuracy
    local secPerQuery = math.max(0.45, ((state.avgRttMs or 220) / 1000) + 0.35)
    local freshCnt, readyCnt, remBaseCnt, remModelScans, maxRemSpan = 0, 0, 0, 0, 0
    local confSum = 0
    for _, pid in ipairs(pool) do
      local pr = db[pid]
      local age = (pr and pr.updatedAt and nowSys > 0) and math.max(0, nowSys - pr.updatedAt) or 999999
      local isFresh = (age < FRESH_OK_SEC)
      local scans = (pr and pr.scans) or 0
      local conf = pr and ComputeConfidence(pr, nowSys) or 0
      confSum = confSum + conf
      if isFresh and scans >= 1 then
        freshCnt = freshCnt + 1
      else
        remBaseCnt = remBaseCnt + 1
      end
      if isFresh and conf >= 70 and scans >= 5 then
        readyCnt = readyCnt + 1
      else
        remModelScans = remModelScans + math.max(1, 5 - scans)
        local spanSec = (pr and pr.firstSeenAt and pr.firstSeenAt > 0 and nowSys > pr.firstSeenAt) and (nowSys - pr.firstSeenAt) or 0
        local remSpan = math.max(0, 300 - spanSec)
        if remSpan > maxRemSpan then maxRemSpan = remSpan end
      end
    end

    local etaStage1 = remBaseCnt * secPerQuery
    local etaStage2 = (readyCnt >= poolN) and 0 or math.max(remModelScans * secPerQuery, maxRemSpan)
    local fullStage1Est = poolN * secPerQuery
    local fullStage2Est = math.max(poolN * 5 * secPerQuery, 300)

    local stageNum = 1
    local modelFrac = 0
    if poolN > 0 then
      if freshCnt < poolN then
        stageNum = 1
        modelFrac = 0.33 * (freshCnt / poolN)
      elseif readyCnt < poolN then
        stageNum = 2
        local avgConf = (confSum / poolN) / 100
        modelFrac = 0.33 + 0.47 * math.max(readyCnt / poolN, math.min(1, avgConf))
      else
        stageNum = 3
        local avgConf = (confSum / poolN) / 100
        modelFrac = 0.80 + 0.20 * math.max(0.15, math.min(1, (avgConf - 0.70) / 0.30))
      end
    end

    local barW = math.max(120, (progBarBg:GetWidth() or 516) - 2)
    progTick1:ClearAllPoints(); progTick1:SetPoint("LEFT", progBarBg, "LEFT", math.floor(barW * 0.33), 0)
    progTick2:ClearAllPoints(); progTick2:SetPoint("LEFT", progBarBg, "LEFT", math.floor(barW * 0.80), 0)

    if poolN > 0 then
      progBarBg:Show()
      progFill:SetWidth(math.max(4, math.floor(barW * math.min(1, modelFrac))))
      if stageNum == 1 then
        progFill:SetColorTexture(0.02, 0.71, 0.83, 0.95)
      elseif stageNum == 2 then
        progFill:SetColorTexture(0.06, 0.78, 0.72, 0.95)
      else
        progFill:SetColorTexture(0.06, 0.73, 0.51, 0.95)
      end
      progFill:Show()
    else
      progBarBg:Hide()
      progFill:Hide()
    end

    local isScanning = ForeverSniperDB.autoScan and state.scanMode == "scanner"
    local now = GetTime and GetTime() or 0
    local showToast = (lastToastAt > 0 and (now - lastToastAt) <= 6)
    local modelPct = math.floor(modelFrac * 100 + 0.5)

    if isScanning then
      local curID = state.scanningItemID
      local icon, nm
      if curID then icon, nm = NS.GetItemVisuals(curID) end
      scanItemIco:SetTexture(icon or RADAR_ICON_PATH)
      scanItemIco:SetTexCoord(icon and 0.08 or 0, icon and 0.92 or 1, icon and 0.08 or 0, icon and 0.92 or 1)
      scanIcoBox:SetBackdropBorderColor(0.02, 0.78, 0.92, 0.85)
      progBox:SetBackdropBorderColor(0.02, 0.71, 0.83, 0.55)

      progTitle:SetText(string.format("|cff38bdf8Сканирую:|r |cfff8fafc%s|r", nm or "..."))
      if not showToast then
        if stageNum == 1 then
          scannerToast:SetText(string.format("|cff94a3b8Обязательный скан (%d/%d, %s) → далее Стат. модель (%s)|r", freshCnt, poolN, FormatEta(etaStage1), FormatEta(etaStage2)))
        elseif stageNum == 2 then
          scannerToast:SetText(string.format("|cff94a3b8Статистическая модель (%d/%d готово, ост. %s) → Полировка|r", readyCnt, poolN, FormatEta(etaStage2)))
        else
          scannerToast:SetText("|cff10b981Модель подтверждена · Полировка деталей (синхр. при выходе / смене альта)|r")
        end
      end

      scannerStartBtn:SetFlatEnabled(true)
      scannerStartBtn:SetLabel(string.format("СТОП · Этап %d/3 (%d%%)", stageNum, modelPct))
      scannerStartBtn:SetColors({ 0.24, 0.16, 0.04, 1 }, { 0.34, 0.22, 0.06, 1 }, { 0.95, 0.65, 0.05, 0.85 }, { 1, 0.93, 0.65 })
      heroRadarIco:SetDesaturated(false)
      heroRadarIco:SetAlpha(1)
    else
      scanItemIco:SetTexture(RADAR_ICON_PATH)
      scanItemIco:SetTexCoord(0, 1, 0, 1)
      scanIcoBox:SetBackdropBorderColor(0.18, 0.28, 0.42, 0.9)
      progBox:SetBackdropBorderColor(1, 1, 1, 0.07)

      local presetName = ForeverSniperDB.activePreset or "Текущий список"
      if not state.ahOpen then
        progTitle:SetText("|cff94a3b8Откройте окно аукциона для сканирования|r")
        scannerStartBtn:SetFlatEnabled(false)
        scannerStartBtn:SetLabel("ОТКРОЙТЕ ОКНО АУКЦИОНА")
        scannerStartBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.08, 0.11, 0.17, 1 }, { 1, 1, 1, 0.06 }, { 0.45, 0.52, 0.62 })
        heroRadarIco:SetDesaturated(true)
        heroRadarIco:SetAlpha(0.45)
      elseif poolN > 0 then
        progTitle:SetText(string.format("|cfff8fafc%s|r |cff38bdf8(%d поз.)|r", presetName, poolN))
        scannerStartBtn:SetFlatEnabled(true)
        scannerStartBtn:SetLabel(string.format("СКАНИРОВАТЬ СПИСОК (%d)", poolN))
        scannerStartBtn:SetColors({ 0.04, 0.15, 0.22, 1 }, { 0.06, 0.22, 0.32, 1 }, { 0.06, 0.74, 0.92, 0.88 }, { 0.88, 0.97, 1 })
        heroRadarIco:SetDesaturated(false)
        heroRadarIco:SetAlpha(1)
      else
        progTitle:SetText("|cfff59e0bСписок пуст — выберите шаблон сверху|r")
        scannerStartBtn:SetFlatEnabled(false)
        scannerStartBtn:SetLabel("ВЫБЕРИТЕ ШАБЛОН СВЕРХУ")
        scannerStartBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.08, 0.11, 0.17, 1 }, { 1, 1, 1, 0.06 }, { 0.45, 0.52, 0.62 })
        heroRadarIco:SetDesaturated(true)
        heroRadarIco:SetAlpha(0.45)
      end
      if not showToast then
        if poolN > 0 and stageNum == 3 then
          scannerToast:SetText("|cff10b981Модель готова — /reload сохранит для сайта (дольше скан = точнее детали)|r")
        elseif poolN > 0 then
          scannerToast:SetText(string.format("|cff64748bОбязательный: %s · Стат. модель: %s · Полировка: чем дольше, тем точнее|r", FormatEta(fullStage1Est), FormatEta(fullStage2Est)))
        else
          scannerToast:SetText("|cff64748bПокупки отключены · Выберите список для расчёта времени сканирования|r")
        end
      end
    end

    if poolN == 0 then
      progRight:SetText("|cff64748bНет списка|r")
    elseif stageNum == 1 then
      progRight:SetText(string.format("|cff38bdf8Этап 1/3 · Обязат. (%s)|r", FormatEta(etaStage1)))
    elseif stageNum == 2 then
      progRight:SetText(string.format("|cff2dd4bfЭтап 2/3 · Модель (%s)|r", FormatEta(etaStage2)))
    else
      progRight:SetText(string.format("|cff10b981Этап 3/3 · Полировка (%d/%d)|r", readyCnt, poolN))
    end
  end

  local function AddToSniperFromScanner(id, switchToSniper)
    local rec = ForeverSniperDB.market and ForeverSniperDB.market[id]
    local floorP = rec and (rec.p2 or rec.p1) or 0
    if floorP <= 0 then
      lastToastAt = GetTime and GetTime() or 1
      scannerToast:SetText("|cfff59e0bСначала просканируйте товар, чтобы узнать живую цену пола|r")
      return
    end
    local targetP = math.max(1, math.floor(floorP * 0.88))
    ForeverSniperDB.watchlist = ForeverSniperDB.watchlist or {}
    ForeverSniperDB.watchlist[id] = targetP
    ForeverSniperDB.tracked = ForeverSniperDB.tracked or {}
    ForeverSniperDB.tracked[id] = true
    ForeverSniperDB.selectedID = id
    if NS.SyncActivePresetSnapshot then NS.SyncActivePresetSnapshot() end
    local _, nm = NS.GetItemVisuals(id)
    lastToastAt = GetTime and GetTime() or 1
    scannerToast:SetText(string.format("|cff10b981Добавлено в Снайпер:|r %s |cff94a3b8(лимит %s, -12%%)|r", nm or tostring(id), NS.FormatCoinsPlain(targetP)))
    print(string.format("|cff10b981Goblin Broker:|r добавлено в Снайпер: %s <= %s (-12%% от пола %s).", nm or id, NS.FormatCoinsPlain(targetP), NS.FormatCoinsPlain(floorP)))
    if switchToSniper and NS.SetScanMode then
      NS.SetScanMode("sniper")
    end
    if NS.UpdateStatus then NS.UpdateStatus() end
    if NS.SyncInputsFromSelected then NS.SyncInputsFromSelected() end
    if NS.RenderInlineRadar then NS.RenderInlineRadar() end
  end

  local radarRows = {}
  local function GetRadarRow(i)
    local row = radarRows[i]
    if not row then
      row = CreateFrame("Button", nil, rContent, "BackdropTemplate")
      row:SetSize(516, 26)
      row:SetBackdrop(NS.FLAT_BACKDROP)
      if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(row, "pill") end
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      row.barFill = row:CreateTexture(nil, "BACKGROUND", nil, 2)
      row.barFill:SetPoint("TOPLEFT", 1, -1)
      row.barFill:SetPoint("BOTTOMLEFT", 1, 1)
      row.barFill:Hide()
      row.activeStripe = row:CreateTexture(nil, "ARTWORK")
      row.activeStripe:SetWidth(3)
      row.activeStripe:SetPoint("TOPLEFT", 2, -5)
      row.activeStripe:SetPoint("BOTTOMLEFT", 2, 5)
      row.activeStripe:SetColorTexture(0.02, 0.82, 0.96, 1)
      row.activeStripe:Hide()
      row.ico = row:CreateTexture(nil, "ARTWORK")
      row.ico:SetSize(18, 18); row.ico:SetPoint("LEFT", 6, 0); row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.name:SetPoint("LEFT", row.ico, "RIGHT", 6, 0); row.name:SetWidth(154); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
      row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.status:SetPoint("LEFT", 188, 0); row.status:SetWidth(86); row.status:SetJustifyH("CENTER"); row.status:SetWordWrap(false)
      row.floor = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.floor:SetPoint("LEFT", 278, 0); row.floor:SetWidth(76); row.floor:SetJustifyH("RIGHT"); row.floor:SetWordWrap(false)
      row.fresh = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.fresh:SetPoint("LEFT", 358, 0); row.fresh:SetWidth(60); row.fresh:SetJustifyH("RIGHT"); row.fresh:SetWordWrap(false)

      local addBtn = NS.CreateFlatButton(nil, row, 76, 20, "+ Снайп")
      addBtn:SetPoint("RIGHT", -6, 0)
      addBtn:SetScript("OnClick", function()
        if row.itemID then AddToSniperFromScanner(row.itemID, false) end
      end)
      addBtn:HookScript("OnEnter", function(self)
        if GameTooltip and row.itemID then
          local rec = ForeverSniperDB.market and ForeverSniperDB.market[row.itemID]
          local floorP = rec and (rec.p2 or rec.p1) or 0
          local targetP = floorP > 0 and math.max(1, math.floor(floorP * 0.88)) or 0
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine("Добавить в Снайпер (1 клик)", 0.06, 0.85, 0.55)
          if targetP > 0 then
            GameTooltip:AddLine("Авто-лимит: " .. NS.FormatCoinsPlain(targetP) .. " (-12% от пола)", 0.85, 0.90, 0.96)
          else
            GameTooltip:AddLine("Сначала просканируйте товар для расчёта цены.", 0.95, 0.72, 0.25)
          end
          GameTooltip:AddLine("Остаётся в Сканере — можно накликать сразу несколько товаров.", 0.60, 0.68, 0.78, true)
          GameTooltip:Show()
        end
      end)
      addBtn:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
      row.addBtn = addBtn

      row:SetScript("OnEnter", function(self)
        if self._baseBg then
          self:SetBackdropColor(self._baseBg[1] + 0.035, self._baseBg[2] + 0.038, self._baseBg[3] + 0.048, math.min(1, (self._baseBg[4] or 1) + 0.25))
        end
        if not GameTooltip or not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
        local rec = ForeverSniperDB.market and ForeverSniperDB.market[self.itemID]
        if rec then
          local nowS = time and time() or 0
          local ageRich = FormatAgeBadge(rec.updatedAt, nowS)
          local conf = ComputeConfidence(rec, nowS)
          local confTxt = conf >= 75 and string.format("|cff10b981%d%% (Высокая)|r", conf)
            or (conf >= 45 and string.format("|cfff59e0b%d%% (Средняя)|r", conf) or string.format("|cff94a3b8%d%% (Мало данных)|r", conf))
          GameTooltip:AddLine(" ")
          GameTooltip:AddDoubleLine("Свежесть / Надёжность:", ageRich .. "  ·  " .. confTxt, 0.85, 0.90, 0.96, 1, 1, 1)
          GameTooltip:AddDoubleLine("Liquidity (CLS) / Sniper:", string.format("%d  /  %d", rec.cls or 0, rec.sniperScore or 0), 0.85, 0.90, 0.96, 0.06, 0.85, 0.55)
          GameTooltip:AddDoubleLine("Пол АХ (якорь) / 1-й тир:", string.format("%s (%d шт)", NS.FormatCoinsPlain(rec.p2 or rec.p1 or 0), rec.q1 or 0), 0.85, 0.90, 0.96, 0.98, 0.92, 0.70)
          GameTooltip:AddDoubleLine("Стены +5% / +10% / +15%:", string.format("%d / %d / %d шт", rec.wallQty or 0, rec.wall10Qty or 0, rec.wall15Qty or 0), 0.85, 0.90, 0.96, 0.85, 0.90, 0.96)
          if (rec.resetCost15 or 0) > 0 then
            GameTooltip:AddDoubleLine("Цена ресета (+15%):", NS.FormatCoinsPlain(rec.resetCost15), 0.85, 0.90, 0.96, 0.96, 0.70, 0.03)
          end
          GameTooltip:AddDoubleLine("Скорость выкупа / Объём:", string.format("%.0f шт/ч  ·  %d шт", rec.vDrain or 0, rec.totalDepth or 0), 0.85, 0.90, 0.96, 0.06, 0.85, 0.55)
          if (rec.dipCount or 0) > 0 then
            GameTooltip:AddDoubleLine("Просадки (снайп):", string.format("%d шт · -%.0f%% · окно %.1fс · отск. %.0f%%", rec.dipCount, rec.dipDepthAvg or 0, rec.dipDurAvg or 0, (rec.reboundRatio or 0.96) * 100), 0.85, 0.90, 0.96, 0.22, 0.74, 0.97)
          end
          GameTooltip:AddLine(" ")
          GameTooltip:AddLine("Кнопка [+ Снайп]: добавить (-12%)  |  ПКМ: добавить и открыть Снайпер", 0.22, 0.74, 0.97)
        else
          GameTooltip:AddLine(" ")
          GameTooltip:AddLine("Ожидает сканирования — нажмите «СКАНИРОВАТЬ СПИСОК»", 0.22, 0.74, 0.97)
        end
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function(self)
        if self._baseBg then self:SetBackdropColor(unpack(self._baseBg)) end
        if GameTooltip then GameTooltip:Hide() end
      end)
      row:SetScript("OnClick", function(self, btn)
        local id = self.itemID
        if not id then return end
        if btn == "RightButton" then
          AddToSniperFromScanner(id, true)
        else
          ForeverSniperDB.selectedID = id
          if NS.SyncInputsFromSelected then NS.SyncInputsFromSelected() end
          if NS.OpenMarketDetailsFrame then NS.OpenMarketDetailsFrame() end
        end
      end)
      radarRows[i] = row
      if NS.ApplyModernFonts then NS.ApplyModernFonts(row) end
    end
    return row
  end

  NS.RenderInlineRadar = function()
    if not scannerView:IsShown() then return end
    for idx, info in pairs(hdrLabels) do
      if idx == radarSortCol then
        info.fs:SetText("|cff38bdf8" .. info.base .. (radarSortAsc and " ▲" or " ▼") .. "|r")
      else
        info.fs:SetText("|cff94a3b8" .. info.base .. "|r")
      end
    end

    local db = EnsureMarketDB()
    local pool = state.allItems or {}
    local nowSys = time and time() or 0
    local totalDbCount = 0
    for _, rec in pairs(db) do if type(rec) == "table" then totalDbCount = totalDbCount + 1 end end

    local keys = {}
    if activeFilter == "list" then
      for _, id in ipairs(pool) do
        table.insert(keys, id)
      end
    elseif activeFilter == "needed" then
      for _, id in ipairs(pool) do
        local rec = db[id]
        local age = (rec and rec.updatedAt and nowSys > 0) and math.max(0, nowSys - rec.updatedAt) or 999999
        local conf = rec and ComputeConfidence(rec, nowSys) or 0
        if not rec or age >= FRESH_OK_SEC or conf < 70 or (rec.scans or 0) < 5 then
          table.insert(keys, id)
        end
      end
    else
      for id, rec in pairs(db) do
        if type(rec) == "table" then
          local keep = true
          if activeFilter == "ready" then
            local age = (rec.updatedAt and nowSys > 0) and math.max(0, nowSys - rec.updatedAt) or 999999
            keep = (age < FRESH_OK_SEC and ComputeConfidence(rec, nowSys) >= 70 and (rec.scans or 0) >= 5)
          end
          if keep then table.insert(keys, id) end
        end
      end
    end

    table.sort(keys, function(a, b)
      local ra, rb = db[a], db[b]
      local va, vb = 0, 0
      if radarSortCol == 3 then
        va = ra and (ra.p2 or ra.p1) or 0
        vb = rb and (rb.p2 or rb.p1) or 0
      elseif radarSortCol == 4 then
        va = ra and (ra.updatedAt or 0) or 0
        vb = rb and (rb.updatedAt or 0) or 0
      else
        va = ra and ComputeConfidence(ra, nowSys) or -1
        vb = rb and ComputeConfidence(rb, nowSys) or -1
      end
      if va ~= vb then return radarSortAsc and (va < vb) or (va > vb) end
      return a < b
    end)

    for _, r in ipairs(radarRows) do r:Hide() end
    local wl = ForeverSniperDB.watchlist or {}
    local isScanning = ForeverSniperDB.autoScan and state.scanMode == "scanner"
    local activeScanID = isScanning and state.scanningItemID or nil
    local y = 0

    local rowW = (#keys <= 9) and 526 or 516
    rContent:SetWidth(rowW)
    for i, id in ipairs(keys) do
      local rec = db[id]
      local row = GetRadarRow(i)
      row.itemID = id
      row:SetWidth(rowW)
      row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)

      local isActiveRow = (activeScanID == id)
      if isActiveRow then
        row._baseBg = { 0.04, 0.16, 0.24, 1 }
        row:SetBackdropColor(unpack(row._baseBg))
        row:SetBackdropBorderColor(0.02, 0.78, 0.92, 0.95)
        row.activeStripe:Show()
      else
        row._baseBg = { i % 2 == 1 and 0.092 or 0.075, i % 2 == 1 and 0.104 or 0.084, i % 2 == 1 and 0.142 or 0.118, i % 2 == 1 and 0.55 or 0.35 }
        row:SetBackdropColor(unpack(row._baseBg))
        row:SetBackdropBorderColor(0, 0, 0, 0)
        row.activeStripe:Hide()
      end

      local icon, nm, r, g, b = NS.GetItemVisuals(id)
      row.ico:SetTexture(icon or 134400)
      local displayName = nm or ("Item #" .. tostring(id))
      row.name:SetText(isActiveRow and ("|cff38bdf8>|r " .. displayName) or displayName)
      row.name:SetTextColor(r or 0.9, g or 0.9, b or 0.9)

      if rec then
        local conf = ComputeConfidence(rec, nowSys)
        local scans = rec.scans or 0
        local _, ageShort, ageSec = FormatAgeBadge(rec.updatedAt, nowSys)
        local isStale = (ageSec >= FRESH_OK_SEC)
        local isReliable = (not isStale and conf >= 70 and scans >= 5)

        if conf > 0 then
          row.barFill:ClearAllPoints()
          row.barFill:SetPoint("TOPLEFT", 2, -2)
          row.barFill:SetPoint("BOTTOMLEFT", 2, 2)
          row.barFill:SetWidth(math.max(4, math.floor((rowW - 4) * (conf / 100))))
          if isReliable then
            row.barFill:SetColorTexture(0.06, 0.73, 0.51, 0.12)
          elseif isStale then
            row.barFill:SetColorTexture(0.96, 0.62, 0.04, 0.09)
          else
            row.barFill:SetColorTexture(0.02, 0.71, 0.83, 0.10)
          end
          row.barFill:Show()
        else
          row.barFill:Hide()
        end

        if isActiveRow then
          row.status:SetText("|cff38bdf8СКАН...|r")
        elseif isStale then
          row.status:SetText("|cfff59e0bУстарело|r")
        elseif isReliable then
          row.status:SetText(string.format("|cff10b981Готово · %d%%|r", conf))
        else
          row.status:SetText(string.format("|cff38bdf8Сбор %d/5|r", math.min(5, scans)))
        end

        local floorP = rec.p2 or rec.p1 or 0
        row.floor:SetText(floorP > 0 and NS.FormatCoins(floorP) or "|cff475569—|r")

        local ageCol = ageSec < FRESH_LIVE_SEC and "|cff10b981" or (ageSec < FRESH_OK_SEC and "|cff38bdf8" or (ageSec < STALE_SECONDS and "|cfff59e0b" or "|cfff43f5e"))
        row.fresh:SetText(ageCol .. ageShort .. "|r")
      else
        row.barFill:Hide()
        row.status:SetText(isActiveRow and "|cff38bdf8СКАН...|r" or "|cff475569Нет данных|r")
        row.floor:SetText("|cff475569—|r")
        row.fresh:SetText("|cff475569—|r")
      end

      if wl[id] then
        row.addBtn:SetLabel("В снайпере")
        row.addBtn:SetColors({ 0.095, 0.108, 0.145, 0.85 }, { 0.14, 0.16, 0.22, 0.95 }, { 1, 1, 1, 0.07 }, { 0.58, 0.66, 0.76 })
      else
        row.addBtn:SetLabel("+ Снайп")
        row.addBtn:SetColors({ 0.04, 0.22, 0.32, 1 }, { 0.06, 0.32, 0.44, 1 }, { 0.02, 0.71, 0.83, 0.70 }, { 0.90, 0.98, 1 })
      end

      row:Show()
      y = y + 28
    end

    rContent:SetHeight(math.max(240, y))
    if #keys == 0 then
      if activeFilter == "list" then
        rEmptyTitle:SetText("|cff38bdf8Список для сканирования пуст|r")
        rEmpty:SetText("|cff94a3b8Выберите шаблон сверху или загрузите список через Импорт на левой панели|r")
      elseif activeFilter == "needed" then
        rEmptyTitle:SetText("|cff10b981Все товары в списке достоверно собраны!|r")
        rEmpty:SetText("|cff94a3b8Откройте «Детали рынка» внизу, чтобы увидеть все метрики и экспортировать|r")
      elseif totalDbCount > 0 then
        rEmptyTitle:SetText("|cff38bdf8Нет совпадений по фильтру|r")
        rEmpty:SetText("|cff94a3b8Переключите фильтр на «Вся база» или «Список» выше|r")
      else
        rEmptyTitle:SetText("|cff38bdf8База разведки пока пуста|r")
        rEmpty:SetText("|cff94a3b8Нажмите «СКАНИРОВАТЬ СПИСОК» внизу, чтобы собрать живые цены и ликвидность|r")
      end
      rEmptyWrap:Show()
    else
      rEmptyWrap:Hide()
    end
    if rScrollBar then
      if #keys <= 9 then rScrollBar:Hide() else rScrollBar:Show() end
    end
    if NS.RefreshScannerFooter then NS.RefreshScannerFooter() end
    if NS.RenderMarketDetailsFrame then NS.RenderMarketDetailsFrame() end
  end

  -- ==========================================================================
  -- Detailed Market Analytics Modal (Airy 920px Wide View with Compact Numbers)
  -- ==========================================================================
  local function FormatCoinsCompact(copper)
    if not copper or copper <= 0 then return "|cff475569—|r" end
    local g = copper / 10000
    if g >= 100 then
      return string.format("|cffffffff%d|r%s", math.floor(g + 0.5), NS.ICON_GOLD or "g")
    elseif g >= 10 then
      return string.format("|cffffffff%.1f|r%s", g, NS.ICON_GOLD or "g")
    elseif g >= 1 then
      local gi = math.floor(copper / 10000)
      local si = math.floor((copper % 10000) / 100)
      return string.format("|cffffffff%d|r%s |cffffffff%d|r%s", gi, NS.ICON_GOLD or "g", si, NS.ICON_SILVER or "s")
    end
    return NS.FormatCoins(copper)
  end

  local function FormatQtyCompact(n)
    n = n or 0
    if n >= 10000 then return string.format("%.0fk", n / 1000)
    elseif n >= 1000 then return string.format("%.1fk", n / 1000)
    else return tostring(n) end
  end

  local detFrame = CreateFrame("Frame", "ForeverSniperMarketDetailsFrame", UIParent, "BackdropTemplate")
  detFrame:SetSize(920, 520)
  detFrame:SetPoint("CENTER", 20, 10)
  detFrame:SetBackdrop(NS.FLAT_BACKDROP)
  if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(detFrame, "panel") end
  detFrame:SetBackdropColor(0.055, 0.062, 0.086, 0.98)
  detFrame:SetBackdropBorderColor(1, 1, 1, 0.08)
  detFrame:SetFrameStrata("DIALOG")
  detFrame:EnableMouse(true)
  detFrame:SetMovable(true)
  detFrame:RegisterForDrag("LeftButton")
  detFrame:SetScript("OnDragStart", detFrame.StartMoving)
  detFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  if NS.AttachDropShadow then NS.AttachDropShadow(detFrame, 10, 0.45) end
  detFrame:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, "ForeverSniperMarketDetailsFrame") end

  local detAccent = detFrame:CreateTexture(nil, "ARTWORK")
  detAccent:SetHeight(2)
  detAccent:SetPoint("TOPLEFT", 12, -1)
  detAccent:SetPoint("TOPRIGHT", -12, -1)
  detAccent:SetColorTexture(1, 1, 1, 1)
  detAccent:SetGradient("HORIZONTAL", CreateColor(0.95, 0.65, 0.05, 0.9), CreateColor(0.06, 0.73, 0.51, 0.85))

  local detTitle = detFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  detTitle:SetPoint("TOPLEFT", 20, -14)
  detTitle:SetText("|cfff59e0bGoblin Broker:|r |cfff8fafcДетальный просмотр рынка|r")

  local detSub = detFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detSub:SetPoint("LEFT", detTitle, "RIGHT", 12, -1)
  detSub:SetText("|cff38bdf8Полная таблица метрик Сканера|r")

  local detCloseX = NS.CreateFlatButton(nil, detFrame, 26, 26, "X")
  detCloseX:SetPoint("TOPRIGHT", -14, -12)
  detCloseX:SetColors({ 0.10, 0.115, 0.155, 0.75 }, { 0.55, 0.16, 0.20, 0.95 }, { 1, 1, 1, 0.06 }, { 0.78, 0.82, 0.90 })
  detCloseX:SetScript("OnClick", function() detFrame:Hide() end)

  -- 3 Airy KPI Summary Cards
  local function MakeDetKpi(xOff, w, label, accentR, accentG, accentB)
    local card = CreateFrame("Frame", nil, detFrame, "BackdropTemplate")
    card:SetSize(w, 52)
    card:SetPoint("TOPLEFT", xOff, -48)
    card:SetBackdrop(NS.FLAT_BACKDROP)
    if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(card, "panel") end
    card:SetBackdropColor(0.078, 0.088, 0.122, 1)
    card:SetBackdropBorderColor(accentR, accentG, accentB, 0.28)
    local lbl = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 14, -9)
    lbl:SetText("|cff94a3b8" .. label .. "|r")
    local val = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    val:SetPoint("BOTTOMLEFT", 14, 9)
    val:SetPoint("BOTTOMRIGHT", -12, 9)
    val:SetJustifyH("LEFT")
    val:SetWordWrap(false)
    val:SetText("—")
    card.val = val
    return card
  end

  local kpiReady = MakeDetKpi(20,  286, "ДОСТОВЕРНОСТЬ СПИСКА", 0.06, 0.73, 0.51)
  local kpiSnipe = MakeDetKpi(316, 288, "ЛУЧШАЯ ЦЕЛЬ СНАЙПА", 0.02, 0.71, 0.83)
  local kpiLiq   = MakeDetKpi(614, 286, "ТОП ЛИКВИДНОСТИ / РЕСЕТА", 0.95, 0.65, 0.05)

  -- Filter Bar inside Details Modal
  local detFilter = "list"
  local detSortCol, detSortAsc = 4, false
  local detFilterBtns = {}
  local DET_FILTERS = {
    { key = "list",  label = "Текущий список", w = 118 },
    { key = "all",   label = "Вся база",       w = 88 },
    { key = "ready", label = "Достоверные",    w = 102 },
    { key = "snipe", label = "Sniper 50+",     w = 90 },
    { key = "thin",  label = "Тонкий ресет",   w = 102 },
  }
  local function RefreshDetFilterBtns()
    for _, def in ipairs(DET_FILTERS) do
      local b = detFilterBtns[def.key]
      if b then
        if detFilter == def.key then
          b:SetColors({ 0.04, 0.28, 0.38, 1 }, { 0.06, 0.36, 0.48, 1 }, { 0.02, 0.71, 0.83, 0.70 }, { 0.94, 0.99, 1 })
        else
          b:SetColors({ 0.085, 0.098, 0.135, 1 }, { 0.13, 0.15, 0.21, 1 }, { 1, 1, 1, 0.06 }, { 0.68, 0.74, 0.84 })
        end
      end
    end
  end
  local dfx = 20
  for _, def in ipairs(DET_FILTERS) do
    local b = NS.CreateFlatButton(nil, detFrame, def.w, 24, def.label)
    b:SetPoint("TOPLEFT", dfx, -110)
    b:SetScript("OnClick", function()
      detFilter = def.key
      RefreshDetFilterBtns()
      if NS.RenderMarketDetailsFrame then NS.RenderMarketDetailsFrame() end
    end)
    detFilterBtns[def.key] = b
    dfx = dfx + def.w + 8
  end
  RefreshDetFilterBtns()

  -- Quick Search Box inside Market Details
  local detSearchQuery = ""
  local detSearch = CreateFrame("EditBox", nil, detFrame, "BackdropTemplate")
  if NS.StyleFlatBox then NS.StyleFlatBox(detSearch, 190, 24) end
  detSearch:SetPoint("TOPRIGHT", -20, -110)
  local detSearchPH = detSearch:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detSearchPH:SetPoint("LEFT", 10, 0)
  detSearchPH:SetText("|cff64748bПоиск по названию...|r")
  detSearch:SetScript("OnTextChanged", function(self)
    local t = self:GetText() or ""
    detSearchQuery = t:lower()
    if t == "" then detSearchPH:Show() else detSearchPH:Hide() end
    if NS.RenderMarketDetailsFrame then NS.RenderMarketDetailsFrame() end
  end)

  -- Wide Table Container (clean borderless header + generous column gutters)
  local detBox = CreateFrame("Frame", nil, detFrame, "BackdropTemplate")
  detBox:SetPoint("TOPLEFT", 20, -144)
  detBox:SetPoint("BOTTOMRIGHT", -20, 54)
  detBox:SetBackdrop(NS.FLAT_BACKDROP)
  if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(detBox, "panel") end
  detBox:SetBackdropColor(0.072, 0.082, 0.114, 1)
  detBox:SetBackdropBorderColor(1, 1, 1, 0.06)

  local detHdr = CreateFrame("Frame", nil, detBox)
  detHdr:SetPoint("TOPLEFT", 8, -6)
  detHdr:SetPoint("TOPRIGHT", -8, -6)
  detHdr:SetHeight(24)

  local detHdrLine = detHdr:CreateTexture(nil, "ARTWORK")
  detHdrLine:SetHeight(1)
  detHdrLine:SetPoint("BOTTOMLEFT", 0, 0)
  detHdrLine:SetPoint("BOTTOMRIGHT", 0, 0)
  detHdrLine:SetColorTexture(1, 1, 1, 0.06)

  local detHdrLabels = {}
  local function MakeDetCol(idx, text, xOff, w, just, tipTitle, tipBody)
    local b = CreateFrame("Button", nil, detHdr)
    b:SetPoint("LEFT", xOff, 1)
    b:SetSize(w, 20)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetAllPoints()
    fs:SetJustifyH(just or "RIGHT")
    fs:SetText("|cff94a3b8" .. text .. "|r")
    detHdrLabels[idx] = { fs = fs, base = text }
    if idx >= 2 then
      b:SetScript("OnClick", function()
        if detSortCol == idx then detSortAsc = not detSortAsc
        else detSortCol = idx; detSortAsc = false end
        if NS.RenderMarketDetailsFrame then NS.RenderMarketDetailsFrame() end
      end)
    end
    b:SetScript("OnEnter", function(self)
      if idx ~= detSortCol then fs:SetText("|cffe2e8f0" .. text .. "|r") end
      if GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(tipTitle or text, 0.22, 0.74, 0.97)
        if tipBody then GameTooltip:AddLine(tipBody, 0.85, 0.90, 0.96, true) end
        if idx >= 2 then GameTooltip:AddLine("Клик: сортировать", 0.58, 0.66, 0.76) end
        GameTooltip:Show()
      end
    end)
    b:SetScript("OnLeave", function()
      if idx ~= detSortCol then fs:SetText("|cff94a3b8" .. text .. "|r") end
      if GameTooltip then GameTooltip:Hide() end
    end)
  end

  -- Spacious 860px column layout with generous breathing room & rich hover tooltips
  MakeDetCol(1,  "Товар",         6,   168, "LEFT",  "Товар", "Название предмета. ПКМ по строке добавляет в Снайпер (-12%).")
  MakeDetCol(2,  "Надёжн.",       184, 62,  "RIGHT", "Индекс достоверности (0–100%)", "Учитывает число замеров (40%), длительность наблюдения (30%) и свежесть данных (30%). ≥70% = надёжно.")
  MakeDetCol(3,  "Свеж.",         256, 48,  "RIGHT", "Свежесть замера", "Сколько времени прошло с последнего обновления стакана этого товара.")
  MakeDetCol(4,  "CLS",           314, 44,  "RIGHT", "Composite Liquidity Score (0–100)", "Комплексная ликвидность: скорость выкупа, глубина стакана, узкий спред, отсутствие бот-перевыставлений и проходимость стен.")
  MakeDetCol(5,  "Sniper",        368, 50,  "RIGHT", "Sniper Opportunity Score (0–100)", "Рейтинг цели для снайпинга: частота просадок, ожидаемый профит, окно жизни лота (анти-бот) и скорость отскока.")
  MakeDetCol(6,  "Пол (p1)",      430, 82,  "RIGHT", "Устойчивый рыночный пол", "Базовая цена стакана с защитой от 1–3 шт наживок.")
  MakeDetCol(7,  "Стены 5/10/15", 524, 106, "RIGHT", "Объём стен (+5% / +10% / +15%)", "Сколько штук лежит на АХ в пределах +5%, +10% и +15% от пола. Тонкие стены легко выкупать и ресетить.")
  MakeDetCol(8,  "Ресет +15%",    642, 74,  "RIGHT", "Цена ресета рынка (+15%)", "Сколько золота нужно, чтобы скупить все лоты до +15% от текущего пола.")
  MakeDetCol(9,  "Выкуп/ч",       726, 56,  "RIGHT", "Реальная скорость выкупа (шт/ч)", "Подтверждённый выкуп со стакана (с фильтрацией отмен и перевыставлений).")
  MakeDetCol(10, "Просадки",      790, 68,  "RIGHT", "Зафиксированные просадки (≤ -12%)", "Количество резких падений цены ниже -12% от базового пола за время наблюдения.")

  local detScroll = CreateFrame("ScrollFrame", "ForeverSniperMarketDetScroll", detBox, "UIPanelScrollFrameTemplate")
  detScroll:SetPoint("TOPLEFT", 8, -34)
  detScroll:SetPoint("BOTTOMRIGHT", -16, 8)
  local detSB = _G["ForeverSniperMarketDetScrollScrollBar"]
  if detSB then
    detSB:ClearAllPoints()
    detSB:SetPoint("TOPRIGHT", detBox, "TOPRIGHT", -5, -34)
    detSB:SetPoint("BOTTOMRIGHT", detBox, "BOTTOMRIGHT", -5, 8)
    detSB:SetWidth(4)
    local up = _G["ForeverSniperMarketDetScrollScrollBarScrollUpButton"]
    local dn = _G["ForeverSniperMarketDetScrollScrollBarScrollDownButton"]
    if up then up:SetAlpha(0); up:EnableMouse(false); up:SetHeight(1) end
    if dn then dn:SetAlpha(0); dn:EnableMouse(false); dn:SetHeight(1) end
    local th = detSB:GetThumbTexture()
    if th then th:SetColorTexture(0.02, 0.71, 0.83, 0.70); th:SetWidth(4) end
  end

  local detContent = CreateFrame("Frame", nil, detScroll)
  detContent:SetSize(860, 270)
  detScroll:SetScrollChild(detContent)

  local detEmpty = detBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detEmpty:SetPoint("CENTER", 0, -10)
  detEmpty:SetText("|cff64748bНет данных для отображения|r")
  detEmpty:Hide()

  local detRows = {}
  local function GetDetRow(i)
    local row = detRows[i]
    if not row then
      row = CreateFrame("Button", nil, detContent, "BackdropTemplate")
      row:SetSize(860, 28)
      row:SetBackdrop(NS.FLAT_BACKDROP)
      if NS.ApplyRoundedSurface then NS.ApplyRoundedSurface(row, "pill") end
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      row.ico = row:CreateTexture(nil, "ARTWORK")
      row.ico:SetSize(18, 18); row.ico:SetPoint("LEFT", 6, 0); row.ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      local function MkCell(xOff, w, just)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", xOff, 0); fs:SetWidth(w); fs:SetJustifyH(just or "RIGHT"); fs:SetWordWrap(false)
        return fs
      end
      row.name   = MkCell(30,  146, "LEFT")
      row.conf   = MkCell(184, 62,  "RIGHT")
      row.fresh  = MkCell(256, 48,  "RIGHT")
      row.cls    = MkCell(314, 44,  "RIGHT")
      row.sniper = MkCell(368, 50,  "RIGHT")
      row.floor  = MkCell(430, 82,  "RIGHT")
      row.walls  = MkCell(524, 106, "RIGHT")
      row.reset  = MkCell(642, 74,  "RIGHT")
      row.drain  = MkCell(726, 56,  "RIGHT")
      row.dips   = MkCell(790, 68,  "RIGHT")

      row:SetScript("OnClick", function(self, btn)
        if btn == "RightButton" and self.itemID then
          AddToSniperFromScanner(self.itemID, false)
        end
      end)
      row:SetScript("OnEnter", function(self)
        if self._baseBg then
          self:SetBackdropColor(self._baseBg[1] + 0.035, self._baseBg[2] + 0.038, self._baseBg[3] + 0.048, math.min(1, (self._baseBg[4] or 1) + 0.25))
        end
        if not GameTooltip or not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("ПКМ: добавить в Снайпер (-12% от пола)", 0.06, 0.85, 0.55)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function(self)
        if self._baseBg then self:SetBackdropColor(unpack(self._baseBg)) end
        if GameTooltip then GameTooltip:Hide() end
      end)
      detRows[i] = row
      if NS.ApplyModernFonts then NS.ApplyModernFonts(row) end
    end
    return row
  end

  local detHint = detFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detHint:SetPoint("BOTTOMLEFT", 16, 17)
  detHint:SetText("|cff64748bКлик по заголовку — сортировка · ПКМ по строке — добавить в Снайпер (-12%)|r")

  local detCloseBtn = NS.CreateFlatButton(nil, detFrame, 96, 26, "Закрыть")
  detCloseBtn:SetPoint("BOTTOMRIGHT", -16, 12)
  detCloseBtn:SetColors({ 0.08, 0.11, 0.17, 1 }, { 0.14, 0.19, 0.29, 1 }, { 0.20, 0.27, 0.38, 1 }, { 0.85, 0.90, 0.96 })
  detCloseBtn:SetScript("OnClick", function() detFrame:Hide() end)

  local detExportBtn = NS.CreateFlatButton(nil, detFrame, 146, 26, "Экспорт (Ctrl+C)")
  detExportBtn:SetPoint("RIGHT", detCloseBtn, "LEFT", -8, 0)
  detExportBtn:SetColors({ 0.04, 0.24, 0.34, 1 }, { 0.06, 0.34, 0.46, 1 }, { 0.02, 0.71, 0.83, 0.9 }, { 0.92, 0.99, 1 })
  detExportBtn:SetScript("OnClick", function()
    if NS.ExportLiquidityModal then NS.ExportLiquidityModal() end
  end)

  NS.RenderMarketDetailsFrame = function()
    if not detFrame:IsShown() then return end
    for idx, info in pairs(detHdrLabels) do
      if idx == detSortCol then
        info.fs:SetText("|cff38bdf8" .. info.base .. (detSortAsc and " ▲" or " ▼") .. "|r")
      else
        info.fs:SetText("|cff94a3b8" .. info.base .. "|r")
      end
    end

    local db = EnsureMarketDB()
    local pool = state.allItems or {}
    local nowSys = time and time() or 0

    -- Compute KPI cards over active pool / db
    local readyN, ageSum, ageCnt = 0, 0, 0
    local bestSnipeID, bestSnipeVal = nil, -1
    local bestLiqID, bestLiqVal = nil, -1
    for _, pid in ipairs(pool) do
      local pr = db[pid]
      if pr and type(pr) == "table" then
        local age = (pr.updatedAt and nowSys > 0) and math.max(0, nowSys - pr.updatedAt) or 999999
        if age < FRESH_OK_SEC then
          ageSum = ageSum + age
          ageCnt = ageCnt + 1
          if ComputeConfidence(pr, nowSys) >= 70 and (pr.scans or 0) >= 5 then readyN = readyN + 1 end
        end
      end
    end
    for id, r in pairs(db) do
      if type(r) == "table" then
        if (r.sniperScore or 0) > bestSnipeVal then bestSnipeVal = r.sniperScore or 0; bestSnipeID = id end
        if (r.cls or 0) > bestLiqVal then bestLiqVal = r.cls or 0; bestLiqID = id end
      end
    end
    local avgAgeTxt = ageCnt > 0 and (ageSum / ageCnt < 120 and string.format("%dс", math.floor(ageSum / ageCnt)) or string.format("%dм", math.floor(ageSum / ageCnt / 60))) or "—"
    kpiReady.val:SetText(string.format("|cff10b981%d/%d готово|r |cff64748b· ср. %s|r", readyN, #pool, avgAgeTxt))
    if bestSnipeID and bestSnipeVal > 0 then
      local _, snm = NS.GetItemVisuals(bestSnipeID)
      kpiSnipe.val:SetText(string.format("|cff38bdf8%d|r · %s", bestSnipeVal, snm or bestSnipeID))
    else
      kpiSnipe.val:SetText("|cff64748bСоберите данные...|r")
    end
    if bestLiqID and bestLiqVal > 0 then
      local _, lnm = NS.GetItemVisuals(bestLiqID)
      kpiLiq.val:SetText(string.format("|cfff59e0bCLS %d|r · %s", bestLiqVal, lnm or bestLiqID))
    else
      kpiLiq.val:SetText("|cff64748bСоберите данные...|r")
    end

    local keys = {}
    local function MatchesSearch(id)
      if not detSearchQuery or detSearchQuery == "" then return true end
      local _, nm = NS.GetItemVisuals(id)
      return (nm and nm:lower():find(detSearchQuery, 1, true) ~= nil) or tostring(id):find(detSearchQuery, 1, true) ~= nil
    end
    if detFilter == "list" then
      for _, id in ipairs(pool) do
        if MatchesSearch(id) then table.insert(keys, id) end
      end
    else
      for id, rec in pairs(db) do
        if type(rec) == "table" and MatchesSearch(id) then
          local keep = true
          if detFilter == "ready" then
            local age = (rec.updatedAt and nowSys > 0) and math.max(0, nowSys - rec.updatedAt) or 999999
            keep = (age < FRESH_OK_SEC and ComputeConfidence(rec, nowSys) >= 70 and (rec.scans or 0) >= 5)
          elseif detFilter == "snipe" then
            keep = (rec.sniperScore or 0) >= 50
          elseif detFilter == "thin" then
            keep = (rec.resetCost15 or 0) > 0 and (rec.wall15Qty or 0) <= 40
          end
          if keep then table.insert(keys, id) end
        end
      end
    end

    table.sort(keys, function(a, b)
      local ra, rb = db[a], db[b]
      local va, vb = 0, 0
      if detSortCol == 2 then va = ra and ComputeConfidence(ra, nowSys) or -1; vb = rb and ComputeConfidence(rb, nowSys) or -1
      elseif detSortCol == 3 then va = ra and (ra.updatedAt or 0) or 0; vb = rb and (rb.updatedAt or 0) or 0
      elseif detSortCol == 4 then va = ra and (ra.cls or 0) or -1; vb = rb and (rb.cls or 0) or -1
      elseif detSortCol == 5 then va = ra and (ra.sniperScore or 0) or -1; vb = rb and (rb.sniperScore or 0) or -1
      elseif detSortCol == 6 then va = ra and (ra.p2 or ra.p1) or 0; vb = rb and (rb.p2 or rb.p1) or 0
      elseif detSortCol == 7 then va = ra and (ra.wallQty or 0) or 0; vb = rb and (rb.wallQty or 0) or 0
      elseif detSortCol == 8 then va = ra and (ra.resetCost15 or 0) or 0; vb = rb and (rb.resetCost15 or 0) or 0
      elseif detSortCol == 9 then va = ra and (ra.vDrain or 0) or 0; vb = rb and (rb.vDrain or 0) or 0
      elseif detSortCol == 10 then va = ra and (ra.dipCount or 0) or 0; vb = rb and (rb.dipCount or 0) or 0
      end
      if va ~= vb then return detSortAsc and (va < vb) or (va > vb) end
      return a < b
    end)

    for _, r in ipairs(detRows) do r:Hide() end
    local y = 0
    for i, id in ipairs(keys) do
      local rec = db[id]
      local row = GetDetRow(i)
      row.itemID = id
      row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -y)
      row._baseBg = { i % 2 == 1 and 0.092 or 0.075, i % 2 == 1 and 0.104 or 0.084, i % 2 == 1 and 0.142 or 0.118, i % 2 == 1 and 0.55 or 0.30 }
      row:SetBackdropColor(unpack(row._baseBg))
      row:SetBackdropBorderColor(0, 0, 0, 0)

      local icon, nm, r, g, b = NS.GetItemVisuals(id)
      row.ico:SetTexture(icon or 134400)
      row.name:SetText(nm or ("Item #" .. tostring(id)))
      row.name:SetTextColor(r or 0.9, g or 0.9, b or 0.9)

      if rec then
        local conf = ComputeConfidence(rec, nowSys)
        local _, ageShort, ageSec = FormatAgeBadge(rec.updatedAt, nowSys)
        local cCol = (conf >= 70 and ageSec < FRESH_OK_SEC) and "|cff10b981" or (conf >= 40 and "|cff38bdf8" or "|cff94a3b8")
        row.conf:SetText(string.format("%s%d%%|r", cCol, conf))
        local aCol = ageSec < FRESH_LIVE_SEC and "|cff10b981" or (ageSec < FRESH_OK_SEC and "|cff38bdf8" or (ageSec < STALE_SECONDS and "|cfff59e0b" or "|cfff43f5e"))
        row.fresh:SetText(aCol .. ageShort .. "|r")
        local cls = rec.cls or 0
        row.cls:SetText(string.format("%s%d|r", cls >= 70 and "|cff10b981" or (cls >= 45 and "|cfff59e0b" or "|cff94a3b8"), cls))
        local sn = rec.sniperScore or 0
        row.sniper:SetText(string.format("%s%d|r", sn >= 60 and "|cff38bdf8" or "|cff94a3b8", sn))
        local fp = rec.p2 or rec.p1 or 0
        row.floor:SetText(FormatCoinsCompact(fp))
        row.walls:SetText(string.format("|cffcbd5e1%s|r / |cff94a3b8%s|r / |cff64748b%s|r", FormatQtyCompact(rec.wallQty), FormatQtyCompact(rec.wall10Qty), FormatQtyCompact(rec.wall15Qty)))
        row.reset:SetText(FormatCoinsCompact(rec.resetCost15))
        row.drain:SetText((rec.vDrain or 0) > 0.5 and string.format("|cff10b981%.0f/ч|r", rec.vDrain) or "|cff64748b0/ч|r")
        if (rec.dipCount or 0) > 0 then
          row.dips:SetText(string.format("|cfffbbf24%d|r", rec.dipCount))
        else
          row.dips:SetText("|cff475569—|r")
        end
      else
        row.conf:SetText("|cff475569Сбор|r")
        row.fresh:SetText("|cff475569—|r")
        row.cls:SetText("|cff475569—|r")
        row.sniper:SetText("|cff475569—|r")
        row.floor:SetText("|cff475569—|r")
        row.walls:SetText("|cff475569—|r")
        row.reset:SetText("|cff475569—|r")
        row.drain:SetText("|cff475569—|r")
        row.dips:SetText("|cff475569—|r")
      end
      row:Show()
      y = y + 32
    end
    detContent:SetHeight(math.max(270, y))
    if #keys == 0 then detEmpty:Show() else detEmpty:Hide() end
    if detSB then if #keys <= 10 then detSB:Hide() else detSB:Show() end end
  end

  NS.OpenMarketDetailsFrame = function()
    detFrame:Show()
    NS.RenderMarketDetailsFrame()
  end
  NS.ToggleMarketDetailsFrame = function()
    if detFrame:IsShown() then detFrame:Hide() else NS.OpenMarketDetailsFrame() end
  end
  if NS.ApplyModernFonts then
    NS.ApplyModernFonts(scannerView)
    NS.ApplyModernFonts(detFrame)
  end

  NS.ExportLiquidityModal = function()
    local db = EnsureMarketDB()
    local nowSys = time and time() or 0
    local keys = {}
    for id, r in pairs(db) do if type(r) == "table" then table.insert(keys, id) end end
    table.sort(keys, function(a, b) return (db[a].cls or 0) > (db[b].cls or 0) end)
    local lines = { "LIQ;id;name;cls;sniperScore;floor;q1;spreadPct;wall5;wall10;wall15;resetCost15;drainPerHour;totalDepth;dipCount;dipDepthPct;dipDurSec;rebound;ageSec" }
    for _, id in ipairs(keys) do
      local rec = db[id]
      local _, nm = NS.GetItemVisuals(id)
      local ageSec = (rec.updatedAt and nowSys > 0) and math.max(0, nowSys - rec.updatedAt) or -1
      table.insert(lines, string.format("LIQ;%d;%s;%d;%d;%d;%d;%.1f;%d;%d;%d;%d;%.0f;%d;%d;%.1f;%.1f;%.2f;%d",
        id, (nm or tostring(id)):gsub(";", ","), rec.cls or 0, rec.sniperScore or 0,
        rec.p2 or rec.p1 or 0, rec.q1 or 0, rec.spreadPct or 0,
        rec.wallQty or 0, rec.wall10Qty or 0, rec.wall15Qty or 0, rec.resetCost15 or 0,
        rec.vDrain or 0, rec.totalDepth or 0,
        rec.dipCount or 0, rec.dipDepthAvg or 0, rec.dipDurAvg or 0, rec.reboundRatio or 0.96, ageSec))
    end
    if NS.OpenExportModal then
      NS.OpenExportModal("Экспорт Ликвидности АХ (Ctrl+C)", table.concat(lines, "\n"))
    end
  end
end
