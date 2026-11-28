// Goblin Broker: Forever — Crowdsourced Live Telemetry Worker (v3.0 Hardened)
// 100% read-only anonymized market metrics (0% Blizzard ToS risk, zero PII)

const MAX_BODY_BYTES = 262144; // 256 KB
const MAX_ITEMS = 500;
const MAX_SALES = 500;
const INGEST_CLIENT_TOKEN = "gb-forever-eu-v3";

const FORBIDDEN_KEYS = [
  "presets", "keybinds", "character", "account",
  "gold", "money", "bait", "watchlist", "sessionLog"
];

const FIELD_BOUNDS = {
  p1:           [1, 1_000_000_000],
  q1:           [0, 10_000_000],
  p2:           [0, 1_000_000_000],
  wallQty:      [0, 10_000_000],
  wall10Qty:    [0, 10_000_000],
  wall15Qty:    [0, 10_000_000],
  resetCost15:  [0, 10_000_000_000],
  totalDepth:   [0, 100_000_000],
  spreadPct:    [0, 10_000],
  vDrain:       [0, 1_000_000],
  cls:          [0, 100],
  sniperScore:  [0, 100],
  confidence:   [0, 100],
  dipCount:     [0, 100_000],
  dipDepthAvg:  [0, 100],
  dipDurAvg:    [0, 86400],
  reboundRatio: [0, 10],
  scans:        [0, 1_000_000],
  updatedAt:    [1_600_000_000, 2_500_000_000],
  ageSec:       [0, 31_536_000],
  dips:         [0, 100_000],
  winRate:      [0, 100],
  attempts:     [0, 1_000_000],
  avgFloor:     [0, 1_000_000_000]
};

const CORS_READ_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type"
};

function jsonResp(obj, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...CORS_READ_HEADERS,
      ...extraHeaders
    }
  });
}

function sanitizeItem(raw, nowSec) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const clean = {};
  for (const [k, v] of Object.entries(raw)) {
    const bounds = FIELD_BOUNDS[k];
    if (!bounds) continue;
    if (typeof v !== "number" || !Number.isFinite(v)) continue;
    if (v < bounds[0] || v > bounds[1]) continue;
    clean[k] = v;
  }
  // Clamp updatedAt strictly to [nowSec - 86400, nowSec + 120] to prevent future-timestamp poisoning
  if (typeof clean.updatedAt === "number") {
    if (clean.updatedAt > nowSec + 120) clean.updatedAt = nowSec;
    if (clean.updatedAt < nowSec - 86400) clean.updatedAt = nowSec - 86400;
  } else {
    clean.updatedAt = nowSec;
  }
  return Object.keys(clean).length > 1 ? clean : null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_READ_HEADERS });
    }

    if (request.method === "GET" && url.pathname === "/") {
      return jsonResp({
        service: "goblin-broker-telemetry",
        version: 2,
        endpoints: { read: "/live_telemetry.json", ingest: "/ingest" }
      });
    }

    if (request.method === "GET" && url.pathname === "/live_telemetry.json") {
      const cached = await env.TELEMETRY_KV.get("live_telemetry_v2");
      if (!cached) {
        return jsonResp({
          version: 2,
          source: "ForeverSniper",
          updated_at: new Date().toISOString(),
          updated_ts: Math.floor(Date.now() / 1000),
          items_count: 0,
          sales_count: 0,
          freshness: { fresh_15m: 0, stale_1h: 0, newest_sec: -1, oldest_sec: -1 },
          items: {},
          salesByName: {}
        }, 200, { "Cache-Control": "public, max-age=15" });
      }
      return new Response(cached, {
        status: 200,
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "public, max-age=15",
          ...CORS_READ_HEADERS
        }
      });
    }

    if (request.method === "POST" && url.pathname === "/ingest") {
      const expectedToken = env.INGEST_TOKEN || INGEST_CLIENT_TOKEN;
      if (request.headers.get("x-gb-token") !== expectedToken) {
        return jsonResp({ error: "Unauthorized" }, 401);
      }

      const len = Number(request.headers.get("content-length") || "0");
      if (len > MAX_BODY_BYTES) {
        return jsonResp({ error: "Payload too large" }, 413);
      }

      const rawText = await request.text();
      if (new TextEncoder().encode(rawText).length > MAX_BODY_BYTES) {
        return jsonResp({ error: "Payload too large" }, 413);
      }

      // Server-side Privacy Audit
      const lower = rawText.toLowerCase();
      for (const bad of FORBIDDEN_KEYS) {
        if (lower.includes(`"${bad.toLowerCase()}"`)) {
          return jsonResp({ error: `Privacy audit rejected key: ${bad}` }, 400);
        }
      }

      let incoming;
      try {
        incoming = JSON.parse(rawText);
      } catch {
        return jsonResp({ error: "Invalid JSON" }, 400);
      }

      if (!incoming || incoming.source !== "ForeverSniper" || !incoming.items || typeof incoming.items !== "object" || Array.isArray(incoming.items)) {
        return jsonResp({ error: "Invalid schema" }, 400);
      }

      let existing = { items: {}, salesByName: {} };
      try {
        const prevText = await env.TELEMETRY_KV.get("live_telemetry_v2");
        if (prevText) {
          const parsed = JSON.parse(prevText);
          if (parsed && parsed.items && typeof parsed.items === "object") existing.items = parsed.items;
          if (parsed && parsed.salesByName && typeof parsed.salesByName === "object") existing.salesByName = parsed.salesByName;
        }
      } catch {}

      const nowSec = Math.floor(Date.now() / 1000);
      let updatedCount = 0;

      for (const [itemId, rawRec] of Object.entries(incoming.items)) {
        if (!/^\d{1,7}$/.test(itemId)) continue;
        const clean = sanitizeItem(rawRec, nowSec);
        if (!clean) continue;

        const prev = existing.items[itemId];
        const prevTs = prev && typeof prev.updatedAt === "number" ? Math.min(prev.updatedAt, nowSec) : 0;
        if (!prev || clean.updatedAt >= prevTs) {
          existing.items[itemId] = clean;
          updatedCount++;
        }
      }

      // Enforce max items cap (evict oldest updatedAt)
      const itemEntries = Object.entries(existing.items);
      if (itemEntries.length > MAX_ITEMS) {
        itemEntries.sort((a, b) => (b[1].updatedAt || 0) - (a[1].updatedAt || 0));
        existing.items = Object.fromEntries(itemEntries.slice(0, MAX_ITEMS));
      }

      if (incoming.salesByName && typeof incoming.salesByName === "object" && !Array.isArray(incoming.salesByName)) {
        for (const [name, sr] of Object.entries(incoming.salesByName)) {
          if (typeof name !== "string" || name.length === 0 || name.length > 80) continue;
          if (!sr || typeof sr !== "object") continue;
          if (typeof sr.avgSellNet !== "number" || !Number.isFinite(sr.avgSellNet)) continue;
          if (typeof sr.qty !== "number" || !Number.isFinite(sr.qty)) continue;
          if (sr.avgSellNet > 0 && sr.avgSellNet <= 1_000_000_000 && sr.qty > 0 && sr.qty <= 10_000_000) {
            existing.salesByName[name] = {
              avgSellNet: Math.floor(sr.avgSellNet),
              qty: Math.floor(sr.qty),
              deals: (typeof sr.deals === "number" && Number.isFinite(sr.deals) && sr.deals > 0) ? Math.min(100000, Math.floor(sr.deals)) : 1
            };
          }
        }
        const saleKeys = Object.keys(existing.salesByName);
        if (saleKeys.length > MAX_SALES) {
          existing.salesByName = Object.fromEntries(Object.entries(existing.salesByName).slice(-MAX_SALES));
        }
      }

      let fresh15m = 0, stale1h = 0, newestAge = null, oldestAge = null;
      for (const rec of Object.values(existing.items)) {
        if (typeof rec.updatedAt === "number" && rec.updatedAt > 0) {
          const age = Math.max(0, nowSec - rec.updatedAt);
          rec.ageSec = age;
          if (age < 900) fresh15m++;
          if (age >= 3600) stale1h++;
          if (newestAge === null || age < newestAge) newestAge = age;
          if (oldestAge === null || age > oldestAge) oldestAge = age;
        }
      }

      const merged = {
        version: 2,
        source: "ForeverSniper",
        updated_at: new Date(nowSec * 1000).toISOString(),
        updated_ts: nowSec,
        items_count: Object.keys(existing.items).length,
        sales_count: Object.keys(existing.salesByName).length,
        freshness: {
          fresh_15m: fresh15m,
          stale_1h: stale1h,
          newest_sec: newestAge === null ? -1 : newestAge,
          oldest_sec: oldestAge === null ? -1 : oldestAge
        },
        items: existing.items,
        salesByName: existing.salesByName
      };

      await env.TELEMETRY_KV.put("live_telemetry_v2", JSON.stringify(merged));

      return jsonResp({
        ok: true,
        updated_items: updatedCount,
        total_items: merged.items_count,
        fresh_15m: fresh15m
      });
    }

    return jsonResp({ error: "Not found" }, 404);
  }
};
