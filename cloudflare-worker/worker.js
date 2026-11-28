// Goblin Broker: Forever — Crowdsourced Live Telemetry Worker (v3.0)
// 100% read-only anonymized market metrics (0% Blizzard ToS risk, zero PII)

const MAX_BODY_BYTES = 262144; // 256 KB
const FORBIDDEN_KEYS = [
  "presets", "keybinds", "character", "account",
  "gold", "money", "bait", "watchlist", "sessionLog"
];
const ALLOWED_ITEM_FIELDS = new Set([
  "p1", "q1", "p2", "wallQty", "wall10Qty", "wall15Qty", "resetCost15",
  "totalDepth", "spreadPct", "vDrain", "cls", "sniperScore", "confidence",
  "dipCount", "dipDepthAvg", "dipDurAvg", "reboundRatio", "scans",
  "updatedAt", "ageSec", "dips", "winRate", "attempts", "avgFloor"
]);

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Client-Version"
};

function jsonResp(obj, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...CORS_HEADERS,
      ...extraHeaders
    }
  });
}

function sanitizeItem(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const clean = {};
  for (const [k, v] of Object.entries(raw)) {
    if (!ALLOWED_ITEM_FIELDS.has(k)) continue;
    if (typeof v === "number" && Number.isFinite(v)) {
      clean[k] = v;
    }
  }
  return Object.keys(clean).length > 0 ? clean : null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    // Health check
    if (request.method === "GET" && url.pathname === "/") {
      return jsonResp({
        service: "goblin-broker-telemetry",
        version: 2,
        endpoints: {
          read: "/live_telemetry.json",
          ingest: "/ingest"
        }
      });
    }

    // Serve merged crowdsourced telemetry to Web Dashboard
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
          ...CORS_HEADERS
        }
      });
    }

    // Ingest anonymized snapshot from GoblinBrokerDesktop.exe
    if (request.method === "POST" && url.pathname === "/ingest") {
      const len = Number(request.headers.get("content-length") || "0");
      if (len > MAX_BODY_BYTES) {
        return jsonResp({ error: "Payload too large" }, 413);
      }

      const rawText = await request.text();
      if (rawText.length > MAX_BODY_BYTES) {
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

      if (!incoming || incoming.source !== "ForeverSniper" || typeof incoming.items !== "object") {
        return jsonResp({ error: "Invalid schema" }, 400);
      }

      // Load existing merged state from KV and merge by newest updatedAt per itemID
      let existing = { items: {}, salesByName: {} };
      try {
        const prevText = await env.TELEMETRY_KV.get("live_telemetry_v2");
        if (prevText) {
          const parsed = JSON.parse(prevText);
          if (parsed && typeof parsed.items === "object") existing.items = parsed.items;
          if (parsed && typeof parsed.salesByName === "object") existing.salesByName = parsed.salesByName;
        }
      } catch {}

      const nowSec = Math.floor(Date.now() / 1000);
      let updatedCount = 0;

      for (const [itemId, rawRec] of Object.entries(incoming.items)) {
        if (!/^\d{1,7}$/.test(itemId)) continue;
        const clean = sanitizeItem(rawRec);
        if (!clean) continue;

        const prev = existing.items[itemId];
        const prevTs = prev && typeof prev.updatedAt === "number" ? prev.updatedAt : 0;
        const newTs = typeof clean.updatedAt === "number" ? clean.updatedAt : nowSec;

        // Keep whichever snapshot is fresher (crowdsourced multi-friend merge)
        if (!prev || newTs >= prevTs) {
          existing.items[itemId] = clean;
          updatedCount++;
        }
      }

      // Merge anonymized confirmed sales averages
      if (incoming.salesByName && typeof incoming.salesByName === "object") {
        for (const [name, sr] of Object.entries(incoming.salesByName)) {
          if (typeof name !== "string" || name.length > 80) continue;
          if (!sr || typeof sr.avgSellNet !== "number" || typeof sr.qty !== "number") continue;
          if (sr.avgSellNet > 0 && sr.qty > 0) {
            existing.salesByName[name] = {
              avgSellNet: Math.floor(sr.avgSellNet),
              qty: Math.floor(sr.qty),
              deals: typeof sr.deals === "number" ? Math.floor(sr.deals) : 1
            };
          }
        }
      }

      // Recompute freshness summary across all merged items
      let fresh15m = 0;
      let stale1h = 0;
      let newestAge = null;
      let oldestAge = null;
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
