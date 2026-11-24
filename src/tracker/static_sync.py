"""Synchronize Russian item names and profession craft recipes from Blizzard static-forever-eu API."""

from __future__ import annotations

import http.client
import json
import sqlite3
import threading
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from .blizzard_api import BlizzardApiClient, BlizzardApiError

_thread_local = threading.local()


def _get_json_keepalive(
    host: str,
    path: str,
    *,
    token: str,
    namespace: str,
    locale: str,
) -> dict[str, Any] | None:
    """Fetch JSON over a thread-local keep-alive HTTPS connection."""
    conn: http.client.HTTPSConnection | None = getattr(_thread_local, "conn", None)
    if conn is None:
        conn = http.client.HTTPSConnection(host, timeout=15)
        _thread_local.conn = conn

    sep = "&" if "?" in path else "?"
    full_path = f"{path}{sep}namespace={urllib.parse.quote(namespace)}&locale={urllib.parse.quote(locale)}"
    headers = {"Authorization": f"Bearer {token}", "Connection": "keep-alive"}

    for attempt in range(2):
        try:
            conn.request("GET", full_path, headers=headers)
            resp = conn.getresponse()
            body = resp.read()
            if resp.status == 200:
                return json.loads(body.decode("utf-8"))
            if resp.status in (404, 429, 500, 502, 503):
                return None
            return None
        except (http.client.HTTPException, OSError):
            try:
                conn.close()
            except Exception:
                pass
            conn = http.client.HTTPSConnection(host, timeout=15)
            _thread_local.conn = conn
            if attempt == 1:
                return None
    return None


def sync_item_names(
    conn: sqlite3.Connection,
    client: BlizzardApiClient,
    *,
    max_workers: int = 8,
    limit: int | None = None,
) -> tuple[int, int]:
    """Fetch exact `ru_RU` names from `static-forever-eu` for placeholder `Item <id>` rows.

    Uses keyset-paginated `/data/wow/search/item` first, then thread-local keep-alive
    `/data/wow/item/{id}` for any remaining IDs.
    """
    rows = conn.execute(
        "SELECT item_id FROM items WHERE name_ru LIKE 'Item %' ORDER BY item_id ASC"
    ).fetchall()
    target_ids = [int(r["item_id"]) for r in rows]
    if limit is not None:
        target_ids = target_ids[:limit]
    if not target_ids:
        return 0, 0

    token = client.authenticate()
    host = f"{client.region}.api.blizzard.com"
    remaining = set(target_ids)
    updated = 0

    # Phase 1: Fast keyset-paginated search
    cursor = min(remaining)
    while remaining:
        try:
            data, _, _ = client._get_json(
                f"/data/wow/search/item?orderby=id&id=[{cursor},]&_pageSize=1000&_page=1"
            )
        except BlizzardApiError:
            break
        results = (data or {}).get("results", [])
        if not results:
            break

        max_seen = cursor
        for res in results:
            it = res.get("data") or {}
            iid = it.get("id")
            if iid is None:
                continue
            iid = int(iid)
            if iid > max_seen:
                max_seen = iid
            if iid in remaining:
                names = it.get("name") or {}
                ru_name = names.get("ru_RU") or names.get("en_US")
                en_name = names.get("en_US") or ru_name
                if ru_name:
                    conn.execute(
                        "UPDATE items SET name_ru = ?, name_en = ? WHERE item_id = ?",
                        (str(ru_name), str(en_name), iid),
                    )
                    remaining.discard(iid)
                    updated += 1

        if not remaining:
            break
        next_target = min((x for x in remaining if x > max_seen), default=None)
        if next_target is None:
            break
        cursor = next_target

    conn.commit()
    if not remaining:
        return updated, 0

    # Phase 2: Keep-alive pool for remaining IDs
    def fetch_one(iid: int) -> tuple[int, str | None]:
        data = _get_json_keepalive(
            host,
            f"/data/wow/item/{iid}",
            token=token,
            namespace=client.namespace,
            locale=client.locale,
        )
        name = data.get("name") if data else None
        return iid, str(name) if name else None

    failed = 0
    done = 0
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = [pool.submit(fetch_one, iid) for iid in sorted(remaining)]
        for fut in as_completed(futures):
            iid, name = fut.result()
            done += 1
            if name:
                conn.execute("UPDATE items SET name_ru = ? WHERE item_id = ?", (name, iid))
                updated += 1
            else:
                failed += 1
            if done % 500 == 0:
                conn.commit()

    conn.commit()
    return updated, failed


def sync_craft_recipes(
    conn: sqlite3.Connection,
    client: BlizzardApiClient,
    *,
    max_workers: int = 8,
) -> int:
    """Fetch profession recipes from `static-forever-eu` into `craft_recipes`."""
    token = client.authenticate()
    host = f"{client.region}.api.blizzard.com"
    existing_ids = {
        int(r["recipe_id"])
        for r in conn.execute("SELECT recipe_id FROM craft_recipes").fetchall()
    }

    prof_index, _, _ = client._get_json("/data/wow/profession/index")
    professions = prof_index.get("professions", []) if prof_index else []

    recipe_jobs: list[tuple[int, str]] = []
    seen_recipes: set[int] = set(existing_ids)

    for prof in professions:
        pid = int(prof["id"])
        pname = str(prof.get("name") or f"Profession {pid}")
        try:
            pdata, _, _ = client._get_json(f"/data/wow/profession/{pid}")
        except BlizzardApiError:
            continue
        for tier in (pdata or {}).get("skill_tiers", []):
            tid = int(tier["id"])
            try:
                tdata, _, _ = client._get_json(f"/data/wow/profession/{pid}/skill-tier/{tid}")
            except BlizzardApiError:
                continue
            for cat in (tdata or {}).get("categories", []):
                for rec in cat.get("recipes", []):
                    rid = int(rec["id"])
                    if rid not in seen_recipes:
                        seen_recipes.add(rid)
                        recipe_jobs.append((rid, pname))

    if not recipe_jobs:
        return 0

    def fetch_recipe(job: tuple[int, str]) -> tuple[int, str, dict[str, Any] | None]:
        rid, pname = job
        rdata = _get_json_keepalive(
            host,
            f"/data/wow/recipe/{rid}",
            token=token,
            namespace=client.namespace,
            locale=client.locale,
        )
        return rid, pname, rdata

    saved = 0
    done = 0
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = [pool.submit(fetch_recipe, job) for job in recipe_jobs]
        for fut in as_completed(futures):
            rid, pname, rdata = fut.result()
            done += 1
            if not rdata:
                continue
            crafted = rdata.get("crafted_item") or {}
            out_id = crafted.get("id")
            if out_id is None:
                continue
            out_id = int(out_id)
            out_name = crafted.get("name")
            qty_raw = (rdata.get("crafted_quantity") or {}).get("value") or 1
            out_qty = max(1, int(round(float(qty_raw))))

            reagents: list[list[int]] = []
            for reg in rdata.get("reagents", []):
                r_obj = reg.get("reagent") or {}
                if r_obj.get("id") is None:
                    continue
                reg_id = int(r_obj["id"])
                reg_qty = int(reg.get("quantity") or 1)
                reagents.append([reg_id, reg_qty])
                if r_obj.get("name"):
                    conn.execute(
                        """
                        INSERT INTO items (item_id, name_ru, name_en, category)
                        VALUES (?, ?, ?, 'other')
                        ON CONFLICT(item_id) DO UPDATE SET
                            name_ru = CASE WHEN items.name_ru LIKE 'Item %' THEN excluded.name_ru ELSE items.name_ru END
                        """,
                        (reg_id, str(r_obj["name"]), str(r_obj["name"])),
                    )

            if not reagents:
                continue

            if out_name:
                conn.execute(
                    """
                    INSERT INTO items (item_id, name_ru, name_en, category)
                    VALUES (?, ?, ?, 'other')
                    ON CONFLICT(item_id) DO UPDATE SET
                        name_ru = CASE WHEN items.name_ru LIKE 'Item %' THEN excluded.name_ru ELSE items.name_ru END
                    """,
                    (out_id, str(out_name), str(out_name)),
                )

            conn.execute(
                """
                INSERT INTO craft_recipes (recipe_id, output_item_id, profession_ru, output_qty, reagents_json)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(recipe_id) DO UPDATE SET
                    output_item_id = excluded.output_item_id,
                    profession_ru = excluded.profession_ru,
                    output_qty = excluded.output_qty,
                    reagents_json = excluded.reagents_json
                """,
                (rid, out_id, pname, out_qty, json.dumps(reagents)),
            )
            saved += 1
            if done % 500 == 0:
                conn.commit()

    conn.commit()
    return saved
