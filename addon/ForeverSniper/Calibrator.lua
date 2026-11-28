local ADDON_NAME, NS = ...
if not NS or not NS.f or not NS.state then return end

local f = NS.f
local state = NS.state

-- ============================================================================
-- Calibrator, EventLog & StatDB Module (Zero-Reload Live RFC 6298 + N-Epoch)
-- Strictly legal Blizzard AH courtesy floor: >= 0.25s (1-item) / >= 0.30s (multi)
-- ============================================================================

f._recordAhError = function(itemID, name, errQty)
  if not itemID or not NS.EnsureTelemetryDB then return end
  local q = math.max(1, tonumber(errQty) or 1)
  local t = NS.EnsureTelemetryDB()
  local dk = NS.TodayKey()
  local d = t.days[dk]
  if not d then d = { buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, missedQty = 0, ahErrors = 0, dips = 0 }; t.days[dk] = d end
  d.ahErrors = (d.ahErrors or 0) + 1
  local it = t.items[itemID]
  if not it then it = { name = name, buys = 0, qty = 0, spent = 0, saved = 0, missed = 0, missedQty = 0, ahErrors = 0, dips = 0 }; t.items[itemID] = it end
  it.ahErrors = (it.ahErrors or 0) + 1
  it.ahErrorQty = (it.ahErrorQty or 0) + q
  if name and not it.name then it.name = name end
  local hb = NS.TouchHourBucket(t, NS.HourKey())
  hb.ahErrors = (hb.ahErrors or 0) + 1
end

local MAX_EVENT_LOG = 120
f._logEvent = function(kind, itemID, qty, price, extra)
  local el = ForeverSniperDB.eventLog
  if not el then
    el = { head = 0, entries = {} }
    ForeverSniperDB.eventLog = el
  end
  local idx = (el.head % MAX_EVENT_LOG) + 1
  el.head = idx
  local row = el.entries[idx]
  if not row then
    row = {}
    el.entries[idx] = row
  end
  row.ts = time and time() or 0
  row.ms = GetTime and math.floor((GetTime() % 1000) * 1000) or 0
  row.k = kind
  row.id = itemID or 0
  row.q = qty or 0
  row.p = price or 0
  row.x = extra
end

f._exportEventLogLines = function(outLines)
  local el = ForeverSniperDB.eventLog
  if not el or not el.entries then return end
  local n = #el.entries
  if n == 0 then return end
  local startIdx = (n == MAX_EVENT_LOG) and ((el.head % MAX_EVENT_LOG) + 1) or 1
  for step = 0, n - 1 do
    local idx = ((startIdx - 1 + step) % n) + 1
    local e = el.entries[idx]
    if e and e.k then
      local tStr = (date and e.ts and e.ts > 0) and date("%H:%M:%S", e.ts) or "00:00:00"
      table.insert(outLines, string.format("LOG;%s.%03d;%s;id=%d;q=%d;p=%d%s",
        tStr, (e.ms or 0) % 1000, e.k, e.id or 0, e.q or 0, e.p or 0, e.x and (";" .. tostring(e.x)) or ""))
    end
  end
end

local MAX_STAT_DB = 2000
f._recordDealStat = function(deal, result, extraPrice)
  if not deal or not deal.itemID or not ForeverSniperDB then return end
  local sb = ForeverSniperDB.statDB
  if not sb then
    sb = { head = 0, entries = {} }
    ForeverSniperDB.statDB = sb
  end
  local idx = (sb.head % MAX_STAT_DB) + 1
  sb.head = idx
  local row = sb.entries[idx]
  if not row then
    row = {}
    sb.entries[idx] = row
  end
  local endT = deal.endAt or (GetTime and GetTime() or 0)
  row.ts = time and time() or 0
  row.t = date and date("%H:%M:%S") or ""
  row.id = deal.itemID
  row.res = result
  row.bid = deal.unitPrice or 0
  row.maxP = deal.maxPrice or 0
  row.mkt = extraPrice or (state.lastSeenByItem and state.lastSeenByItem[deal.itemID] and state.lastSeenByItem[deal.itemID].lowestPrice) or 0
  row.paid = deal.quotedTotal or deal.totalCost or 0
  row.q = deal.qty or 0
  row.avail = deal.maxAvailQty or deal.qty or 0
  row.bait = (state.lastBaitByItem and state.lastBaitByItem[deal.itemID]) or 0
  row.scanRtt = state.avgRttMs or 0
  local bSec = f._getCalibrated and f._getCalibrated() or 0.025
  row.intMs = math.floor((bSec * 1000) + 0.5)
  row.reactMs = (deal.foundAt and deal.confirmAt) and math.max(0, math.floor((deal.confirmAt - deal.foundAt) * 1000 + 0.5)) or 0
  row.quoteMs = (deal.confirmAt and deal.quoteAt) and math.max(0, math.floor((deal.quoteAt - deal.confirmAt) * 1000 + 0.5)) or 0
  row.confReactMs = (deal.quoteAt and deal.confirmSentAt) and math.max(0, math.floor((deal.confirmSentAt - deal.quoteAt) * 1000 + 0.5)) or 0
  row.confRttMs = (deal.confirmSentAt and endT and endT >= deal.confirmSentAt) and math.max(0, math.floor((endT - deal.confirmSentAt) * 1000 + 0.5)) or 0
end

-- Live Online Auto-Calibrator: RFC 6298 (Jacobson/Karels) + Karn's Algorithm + AIMD + N-Iteration Epoch p90 Tuning
local CAL_SCAN_N = 12
local CAL_DEAL_N = 6
local rttRing, rttIdx, rttCnt = {}, 0, 0
local qRing, qIdx, qCnt = {}, 0, 0
local cRing, cIdx, cCnt = {}, 0, 0
local sortTmp = {}

local function PushRing(ring, cap, idx, cnt, val)
  idx = (idx % cap) + 1
  ring[idx] = val
  if cnt < cap then cnt = cnt + 1 end
  return idx, cnt
end

local function CalcP90(ring, cnt)
  if cnt <= 0 then return nil end
  for i = 1, cnt do sortTmp[i] = ring[i] end
  for i = cnt + 1, #sortTmp do sortTmp[i] = nil end
  table.sort(sortTmp)
  local k = math.max(1, math.min(cnt, math.ceil(cnt * 0.90)))
  return sortTmp[k]
end

f._recalibrateEpoch = function(now)
  now = now or (GetTime and GetTime() or 0)
  state.calEpoch = (state.calEpoch or 0) + 1
  local p90R = CalcP90(rttRing, rttCnt)
  local p90Q = CalcP90(qRing, qCnt)
  local p90C = CalcP90(cRing, cCnt)
  state.p90RttMs = p90R or state.p90RttMs
  state.p90QuoteMs = p90Q or state.p90QuoteMs
  state.p90ConfMs = p90C or state.p90ConfMs

  local thrInEpoch = state.epochThrottles or 0
  state.epochThrottles = 0
  state.epochScans = 0
  state.epochDeals = 0
  state.lastCalAt = now

  if thrInEpoch == 0 then
    local targetB = 20
    if (p90R or 0) >= 300 or (p90Q or 0) >= 380 then
      targetB = 55
    elseif (p90R or 0) >= 210 or (p90Q or 0) >= 240 then
      targetB = 35
    end
    local curB = state.breathMs or targetB
    if curB > targetB then
      state.breathMs = math.max(targetB, curB - 15)
    else
      state.breathMs = targetB
    end
  else
    local curB = state.breathMs or 30
    state.breathMs = math.min(250, math.max(60, math.floor(curB * 1.45 + 0.5)))
  end

  if ForeverSniperDB then
    ForeverSniperDB.calSnapshot = {
      at = time and time() or 0,
      avgRttMs = state.avgRttMs,
      rttVarMs = state.rttVarMs,
      emaQuoteMs = state.emaQuoteMs,
      quoteVarMs = state.quoteVarMs,
      emaConfMs = state.emaConfMs,
      confVarMs = state.confVarMs,
      p90RttMs = state.p90RttMs,
      p90QuoteMs = state.p90QuoteMs,
      p90ConfMs = state.p90ConfMs,
      breathMs = state.breathMs,
    }
  end
end

f._loadCalSnapshot = function()
  local snap = ForeverSniperDB and ForeverSniperDB.calSnapshot
  if type(snap) ~= "table" or not snap.at then return end
  local nowTs = time and time() or 0
  if nowTs > 0 and (nowTs - snap.at) <= 1800 then
    if snap.avgRttMs then state.avgRttMs = snap.avgRttMs end
    if snap.rttVarMs then state.rttVarMs = snap.rttVarMs end
    if snap.emaQuoteMs then state.emaQuoteMs = snap.emaQuoteMs end
    if snap.quoteVarMs then state.quoteVarMs = snap.quoteVarMs end
    if snap.emaConfMs then state.emaConfMs = snap.emaConfMs end
    if snap.confVarMs then state.confVarMs = snap.confVarMs end
    if snap.p90RttMs then state.p90RttMs = snap.p90RttMs end
    if snap.p90QuoteMs then state.p90QuoteMs = snap.p90QuoteMs end
    if snap.p90ConfMs then state.p90ConfMs = snap.p90ConfMs end
    if snap.breathMs then state.breathMs = math.max(20, math.min(120, snap.breathMs)) end
  end
end

f._calScanRtt = function(rttMs)
  local now = GetTime and GetTime() or 0
  if rttMs and rttMs >= 1 and rttMs <= 2500 then
    rttIdx, rttCnt = PushRing(rttRing, 16, rttIdx, rttCnt, rttMs)
    if not state.avgRttMs then
      state.avgRttMs = rttMs
      state.rttVarMs = math.max(20, math.floor(rttMs * 0.25 + 0.5))
    else
      local diff = math.abs(rttMs - state.avgRttMs)
      state.rttVarMs = math.floor((state.rttVarMs or 30) * 0.75 + diff * 0.25 + 0.5)
      state.avgRttMs = math.floor(state.avgRttMs * 0.75 + rttMs * 0.25 + 0.5)
    end
  end
  state.epochScans = (state.epochScans or 0) + 1
  if state.epochScans >= CAL_SCAN_N then
    f._recalibrateEpoch(now)
  end
end

f._calQuote = function(qMs)
  local now = GetTime and GetTime() or 0
  state.quoteToStreak = 0
  state.quoteToMult = math.max(1.0, (state.quoteToMult or 1.0) * 0.80)
  state.lastQuoteAt = now
  if qMs and qMs > 0 and qMs <= 2500 then
    qIdx, qCnt = PushRing(qRing, 12, qIdx, qCnt, qMs)
    if not state.emaQuoteMs then
      state.emaQuoteMs = qMs
      state.quoteVarMs = math.max(25, math.floor(qMs * 0.25 + 0.5))
    else
      local diff = math.abs(qMs - state.emaQuoteMs)
      state.quoteVarMs = math.floor((state.quoteVarMs or 35) * 0.75 + diff * 0.25 + 0.5)
      state.emaQuoteMs = math.floor(state.emaQuoteMs * 0.75 + qMs * 0.25 + 0.5)
    end
  end
  state.epochDeals = (state.epochDeals or 0) + 1
  if state.epochDeals >= CAL_DEAL_N then
    f._recalibrateEpoch(now)
  end
end

f._calConfirm = function(cMs)
  local now = GetTime and GetTime() or 0
  state.confToMult = math.max(1.0, (state.confToMult or 1.0) * 0.85)
  if cMs and cMs > 0 and cMs <= 4500 then
    cIdx, cCnt = PushRing(cRing, 12, cIdx, cCnt, cMs)
    if not state.emaConfMs then
      state.emaConfMs = cMs
      state.confVarMs = math.max(40, math.floor(cMs * 0.15 + 0.5))
    else
      local diff = math.abs(cMs - state.emaConfMs)
      state.confVarMs = math.floor((state.confVarMs or 50) * 0.75 + diff * 0.25 + 0.5)
      state.emaConfMs = math.floor(state.emaConfMs * 0.75 + cMs * 0.25 + 0.5)
    end
  end
  state.epochDeals = (state.epochDeals or 0) + 1
  if state.epochDeals >= CAL_DEAL_N then
    f._recalibrateEpoch(now)
  end
end

f._calBackoff = function(reason)
  local now = GetTime and GetTime() or 0
  if reason == "QUOTE_TO" then
    state.quoteToStreak = (state.quoteToStreak or 0) + 1
    state.quoteToMult = math.min(2.0, (state.quoteToMult or 1.0) * 1.35)
    return
  elseif reason == "CONF_TO" then
    state.confToMult = math.min(1.8, (state.confToMult or 1.0) * 1.25)
    return
  end
  local prevAt = state.lastThrottleAt or 0
  state.lastThrottleAt = now
  state.epochThrottles = (state.epochThrottles or 0) + 1
  local curB = state.breathMs or 25
  state.breathMs = math.min(250, math.max(60, math.floor(curB * 1.6 + 0.5)))
  if prevAt > 0 and (now - prevAt) < 20.0 then
    state.kneeBreathMs = math.min(100, math.max(45, (state.kneeBreathMs or 40) + 15))
    state.kneeUntil = now + 45.0
  end
end

f._getCalibrated = function(now)
  now = now or (GetTime and GetTime() or 0)
  local rMs = state.avgRttMs or 150
  local rVar = state.rttVarMs or 35
  local qStale = (not state.lastQuoteAt) or ((now - state.lastQuoteAt) > 30.0)
  local qMs = state.emaQuoteMs or rMs
  if qStale and rMs > qMs then qMs = rMs end
  local qVar = state.quoteVarMs or math.max(35, rVar)
  local cMs = state.emaConfMs or 660
  local cVar = state.confVarMs or 60
  local qJk = (qMs + 4 * qVar + 180) / 1000
  local qP90 = state.p90QuoteMs and ((state.p90QuoteMs * 1.45 + 180) / 1000) or 0
  local quoteToSec = math.max(0.55, math.min(1.50, math.max(qJk, qP90) * (state.quoteToMult or 1.0)))
  local cJk = (cMs + 4 * cVar + 350) / 1000
  local cP90 = state.p90ConfMs and ((state.p90ConfMs * 1.45 + 320) / 1000) or 0
  local confToSec = math.max(1.20, math.min(2.80, math.max(cJk, cP90) * (state.confToMult or 1.0)))
  if state.scanMode == "scanner" then
    return 0.15, 0.55, quoteToSec, confToSec
  end
  local baseB = 20
  if rMs >= 280 or qMs >= 350 or rVar >= 90 then
    baseB = 55
  elseif rMs >= 190 or qMs >= 220 or rVar >= 55 then
    baseB = 35
  end
  if state.kneeBreathMs and state.kneeUntil and now < state.kneeUntil and state.kneeBreathMs > baseB then
    baseB = state.kneeBreathMs
  end
  local effBreathMs = math.max(baseB, state.breathMs or baseB)
  -- Strictly legal Blizzard AH courtesy floor: >= 0.25s (1-item) / >= 0.30s (multi-item)
  local minInt = (#(state.queue or {}) > 1) and 0.30 or 0.25
  return effBreathMs / 1000, minInt, quoteToSec, confToSec
end
