"""Synchronize Russian item names and profession craft recipes from Blizzard static-forever-eu API."""

from __future__ import annotations

import http.client
import json
import sqlite3
import threading
import time
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

    for attempt in range(4):
        try:
            conn.request("GET", full_path, headers=headers)
            resp = conn.getresponse()
            body = resp.read()
            if resp.status == 200:
                return json.loads(body.decode("utf-8"))
            if resp.status == 404:
                return None
            if resp.status in (429, 500, 502, 503) and attempt < 3:
                time.sleep(0.4 * (attempt + 1))
                continue
            return None
        except (http.client.HTTPException, OSError):
            try:
                conn.close()
            except Exception:
                pass
            conn = http.client.HTTPSConnection(host, timeout=15)
            _thread_local.conn = conn
            if attempt == 3:
                return None
            time.sleep(0.3 * (attempt + 1))
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

    # Phase 1: Fast keyset-paginated search across static-forever-eu, static-classic-eu, static-eu
    for ns in (client.namespace, "static-classic-eu", "static-eu"):
        if not remaining:
            break
        orig_ns = client.namespace
        client.namespace = ns
        cursor = min(remaining)
        try:
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
        finally:
            client.namespace = orig_ns
        conn.commit()

    if not remaining:
        return updated, 0

    # Phase 2: Keep-alive pool for remaining IDs (static-forever-eu -> static-classic-eu)
    def fetch_one(iid: int) -> tuple[int, str | None]:
        for ns in (client.namespace, "static-classic-eu"):
            data = _get_json_keepalive(
                host,
                f"/data/wow/item/{iid}",
                token=token,
                namespace=ns,
                locale=client.locale,
            )
            name = data.get("name") if data else None
            if name:
                return iid, str(name)
        return iid, None

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


def _clean_wow_plural(text: str) -> str:
    """Resolve WoW `N |4singular:few:many;` pluralization tags into Russian."""
    import re

    def _repl(m: re.Match[str]) -> str:
        num = int(m.group(1))
        forms = [f for f in m.group(2).split(":") if f]
        if not forms:
            return m.group(1)
        if len(forms) == 1:
            word = forms[0]
        elif len(forms) == 2:
            word = forms[0] if num == 1 else forms[1]
        else:
            mod100 = num % 100
            mod10 = num % 10
            if 11 <= mod100 <= 14:
                word = forms[2]
            elif mod10 == 1:
                word = forms[0]
            elif 2 <= mod10 <= 4:
                word = forms[1]
            else:
                word = forms[2]
        return f"{num} {word}"

    return re.sub(r"(\d+)\s+\|4([^;]+);", _repl, text)


def _format_item_description(data: dict[str, Any]) -> tuple[str | None, str | None]:
    """Extract structured WoW-tooltip JSON `description_ru` and `quality_type` from Blizzard `/data/wow/item/{id}`."""
    quality = (data.get("quality") or {}).get("type")
    prev = data.get("preview_item") or {}

    binding = (prev.get("binding") or {}).get("name")
    inv_type = prev.get("inventory_type") or data.get("inventory_type") or {}
    slot = None if inv_type.get("type") == "NON_EQUIP" else inv_type.get("name")
    subclass = None if prev.get("is_subclass_hidden") else ((prev.get("item_subclass") or data.get("item_subclass") or {}).get("name"))

    lines: list[dict[str, str]] = []
    armor_disp = ((prev.get("armor") or {}).get("display") or {}).get("display_string")
    if armor_disp:
        lines.append({"t": str(armor_disp), "c": "w"})

    weapon = prev.get("weapon") or {}
    dmg_disp = (weapon.get("damage") or {}).get("display_string")
    spd_disp = (weapon.get("attack_speed") or {}).get("display_string")
    dps_disp = (weapon.get("dps") or {}).get("display_string")
    if dmg_disp and spd_disp:
        lines.append({"t": f"{dmg_disp} · {spd_disp}", "c": "w"})
    elif dmg_disp:
        lines.append({"t": str(dmg_disp), "c": "w"})
    if dps_disp:
        lines.append({"t": str(dps_disp), "c": "w"})

    c_slots = (prev.get("container_slots") or {}).get("display_string")
    if c_slots:
        lines.append({"t": _clean_wow_plural(str(c_slots)), "c": "w"})

    for st in prev.get("stats", [])[:6]:
        disp = (st.get("display") or {}).get("display_string")
        if disp:
            is_green = bool(st.get("is_equip_bonus")) or (
                (st.get("display") or {}).get("color", {}).get("g") == 255
                and (st.get("display") or {}).get("color", {}).get("r") == 0
            )
            lines.append({"t": str(disp), "c": "g" if is_green else "w"})

    for sp in prev.get("spells", [])[:3]:
        desc = sp.get("description")
        if desc:
            lines.append({"t": str(desc), "c": "g"})

    dur_disp = (prev.get("durability") or {}).get("display_string")
    if dur_disp:
        lines.append({"t": str(dur_disp), "c": "w"})

    req_disp = ((prev.get("requirements") or {}).get("level") or {}).get("display_string")
    if not req_disp:
        req_lvl = int(data.get("required_level") or 0)
        if req_lvl > 0:
            req_disp = f"Требуется {req_lvl}-й уровень"
    if req_disp:
        lines.append({"t": str(req_disp), "c": "w"})

    flavor = prev.get("description") or data.get("description")
    if flavor:
        lines.append({"t": f'"{flavor}"', "c": "y"})

    sell_val = (prev.get("sell_price") or {}).get("value")
    if sell_val is None:
        sell_val = data.get("sell_price")
    sell_copper = int(sell_val) if sell_val else None

    if not any([binding, slot, subclass, lines, sell_copper]):
        return None, (str(quality) if quality else None)

    payload: dict[str, Any] = {}
    if binding:
        payload["b"] = str(binding)
    if slot:
        payload["sl"] = str(slot)
    if subclass:
        payload["sc"] = str(subclass)
    if lines:
        payload["l"] = lines
    if sell_copper:
        payload["sp"] = sell_copper

    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")), (str(quality) if quality else None)


def sync_item_media_and_descriptions(
    conn: sqlite3.Connection,
    client: BlizzardApiClient,
    *,
    item_ids: list[int] | None = None,
    max_workers: int = 8,
) -> int:
    """Fetch `icon_url`, `description_ru`, and `quality` for items missing media/description."""
    if item_ids is not None:
        target_jobs = [(iid, None) for iid in sorted(set(item_ids))]
    else:
        rows = conn.execute(
            """
            SELECT item_id, icon_url FROM items
            WHERE (icon_url IS NULL OR description_ru IS NULL OR description_ru NOT LIKE '{%')
              AND (
                item_id IN (SELECT output_item_id FROM craft_recipes)
                OR name_ru NOT LIKE 'Item %'
              )
            ORDER BY item_id ASC
            """
        ).fetchall()
        target_jobs = [(int(r["item_id"]), r["icon_url"]) for r in rows]

    if not target_jobs:
        return 0

    token = client.authenticate()
    host = f"{client.region}.api.blizzard.com"

    def fetch_meta(job: tuple[int, str | None]) -> tuple[int, str | None, str | None, str | None]:
        iid, existing_icon = job
        icon_url: str | None = existing_icon
        desc_ru: str | None = None
        quality: str | None = None

        if not icon_url:
            for ns in (client.namespace, "static-classic-eu"):
                mdata = _get_json_keepalive(host, f"/data/wow/media/item/{iid}", token=token, namespace=ns, locale=client.locale)
                if mdata and mdata.get("assets"):
                    icon_url = str(mdata["assets"][0].get("value") or "") or None
                    if icon_url:
                        break

        for ns in (client.namespace, "static-classic-eu"):
            idata = _get_json_keepalive(host, f"/data/wow/item/{iid}", token=token, namespace=ns, locale=client.locale)
            if idata:
                desc_ru, quality = _format_item_description(idata)
                if desc_ru or quality:
                    break

        return iid, icon_url, desc_ru, quality

    updated = 0
    done = 0
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = [pool.submit(fetch_meta, job) for job in target_jobs]
        for fut in as_completed(futures):
            iid, icon_url, desc_ru, quality = fut.result()
            done += 1
            if icon_url or desc_ru or quality:
                conn.execute(
                    """
                    UPDATE items
                    SET icon_url = COALESCE(?, icon_url),
                        description_ru = COALESCE(?, description_ru),
                        quality = COALESCE(?, quality)
                    WHERE item_id = ?
                    """,
                    (icon_url, desc_ru, quality, iid),
                )
                updated += 1
            if done % 300 == 0:
                conn.commit()

    conn.commit()
    return updated
