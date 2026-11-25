"""Command-line interface for WoW: Forever Auction House Tracker."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Sequence

from .analytics import build_transmute_report, build_watchlist
from .blizzard_api import BlizzardApiClient
from .config import TrackerConfig, format_copper, infer_window_tag
from .dashboard import generate_dashboard_file
from .db import connect_db, init_db, save_snapshot
from .lua_parser import load_saved_variables
from .static_sync import sync_craft_recipes, sync_item_media_and_descriptions, sync_item_names


def _build_name_to_id_map(conn) -> dict[str, int]:
    rows = conn.execute("SELECT item_id, name_ru, name_en FROM items").fetchall()
    mapping: dict[str, int] = {}
    for r in rows:
        iid = int(r["item_id"])
        mapping[str(r["name_ru"]).strip().lower()] = iid
        mapping[str(r["name_en"]).strip().lower()] = iid
    return mapping


def _render_table(headers: list[str], rows: list[list[str]]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def fmt_line(cells: list[str]) -> str:
        return " | ".join(cell.ljust(widths[i]) for i, cell in enumerate(cells))

    sep = "-+-".join("-" * w for w in widths)
    lines = [fmt_line(headers), sep]
    lines.extend(fmt_line(r) for r in rows)
    return "\n".join(lines)


def cmd_init_db(args: argparse.Namespace, cfg: TrackerConfig) -> int:
    with connect_db(cfg.db_path) as conn:
        init_db(conn, with_seed=not args.no_seed)
    print(f"Database initialized at {cfg.db_path} (seed={'no' if args.no_seed else 'yes'}).")
    return 0


def cmd_fetch_api(args: argparse.Namespace, cfg: TrackerConfig) -> int:
    client_id = args.client_id or cfg.blizzard_client_id
    client_secret = args.client_secret or cfg.blizzard_client_secret
    if not client_id or not client_secret:
        print("Error: BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET must be set.")
        return 2

    client = BlizzardApiClient(
        client_id,
        client_secret,
        region=args.region or cfg.blizzard_region,
        namespace=args.namespace or cfg.blizzard_namespace,
        locale=args.locale or cfg.blizzard_locale,
    )
    ruleset_id = args.ruleset_id or cfg.ruleset_id
    house_id = args.house_id or cfg.house_id

    if house_id is None:
        houses = client.get_auction_houses(ruleset_id)
        if not houses:
            print(f"No auction houses found for ruleset {ruleset_id}.")
            return 1
        house_id = houses[0].house_id

    result = client.fetch_house_snapshot(
        ruleset_id,
        house_id,
        if_modified_since_auctions=args.if_modified_since,
        if_modified_since_commodities=args.if_modified_since,
        include_commodities=not args.no_commodities,
    )
    if result.not_modified:
        print(f"Snapshot for house {house_id} not modified (HTTP 304).")
        return 0

    window_tag = args.window or infer_window_tag()
    with connect_db(cfg.db_path) as conn:
        init_db(conn, with_seed=True)
        snap_id, obs_count = save_snapshot(
            conn,
            result.lots,
            source="blizzard_api",
            scan_type="full",
            window_tag=window_tag,
            ruleset_id=ruleset_id,
            house_id=house_id,
            meta=result.meta,
            only_known_items=args.only_known,
        )
        if not args.no_dashboard:
            generate_dashboard_file(conn, Path("data/dashboard.html"), house_id=house_id)
    print(f"Saved Blizzard API snapshot #{snap_id} (house={house_id}, window={window_tag}, items={obs_count}).")
    return 0


def cmd_import_lua(args: argparse.Namespace, cfg: TrackerConfig) -> int:
    lua_path = Path(args.file) if args.file else cfg.saved_variables_path
    if not lua_path or not lua_path.exists():
        print(f"Error: SavedVariables file not found: {lua_path}")
        return 2

    window_tag = args.window or infer_window_tag()
    with connect_db(cfg.db_path) as conn:
        init_db(conn, with_seed=True)
        name_map = _build_name_to_id_map(conn)
        parsed = load_saved_variables(lua_path, scan_type=args.scan_type, name_to_id=name_map)
        snap_id, obs_count = save_snapshot(
            conn,
            parsed.lots,
            source="saved_variables",
            scan_type=parsed.scan_type,
            window_tag=window_tag,
            meta=parsed.meta,
            only_known_items=args.only_known,
        )
    print(
        f"Imported {parsed.format_name} snapshot #{snap_id} "
        f"(scan_type={parsed.scan_type}, window={window_tag}, items={obs_count})."
    )
    return 0


def cmd_report(args: argparse.Namespace, cfg: TrackerConfig) -> int:
    fee_rate = args.fee_rate if args.fee_rate is not None else cfg.ah_fee_rate
    with connect_db(cfg.db_path) as conn:
        init_db(conn, with_seed=True)
        rows = build_transmute_report(conn, ah_fee_rate=fee_rate, history_days=args.days)

    headers = [
        "Трансмутация",
        "КД",
        "Вход",
        "Выход",
        "Профит",
        "Рецепт (АХ/Вендор)",
        "Окупаемость",
        f"Δ Мед({args.days}д)",
        "АХ ост.",
        "Статус",
    ]
    table_rows: list[list[str]] = []
    for r in rows:
        if r.recipe_ah_price_copper is not None or r.vendor_recipe_price_copper is not None:
            rec_str = f"{format_copper(r.recipe_ah_price_copper)} / {format_copper(r.vendor_recipe_price_copper)}"
        else:
            rec_str = "—"

        if not r.is_profitable and r.net_profit_copper is not None:
            payback_str = "убыточно"
        elif r.payback_cycles is not None and r.payback_days_est is not None:
            payback_str = f"{r.payback_cycles}ц ({r.payback_days_est}д)"
        else:
            payback_str = "—"

        table_rows.append(
            [
                r.name_ru,
                f"{r.cooldown_hours}h",
                format_copper(r.input_cost_copper),
                format_copper(r.output_unit_price_copper),
                format_copper(r.net_profit_copper),
                rec_str,
                payback_str,
                format_copper(r.output_delta_vs_median_copper),
                str(r.output_total_available) if r.output_total_available is not None else "—",
                r.status_note,
            ]
        )

    print(_render_table(headers, table_rows))
    return 0


def cmd_watch(args: argparse.Namespace, cfg: TrackerConfig) -> int:
    with connect_db(cfg.db_path) as conn:
        init_db(conn, with_seed=True)
        rows = build_watchlist(conn, args.items, history_days=args.days)

    if not rows:
        print("No matching items found.")
        return 0

    headers = [
        "ID",
        "Предмет",
        "Мин. АХ",
        "Медиана",
        "P25",
        f"Δ Мед({args.days}д)",
        f"Δ P25({args.days}д)",
        "Вендор",
        "Ост.",
    ]
    table_rows: list[list[str]] = []
    for r in rows:
        vendor_str = format_copper(r.vendor_price_copper)
        if r.overpriced_vs_vendor:
            vendor_str += " (!АХ дороже)"
        table_rows.append(
            [
                str(r.item_id),
                r.name_ru,
                format_copper(r.min_unit_price_copper),
                format_copper(r.median_unit_price_copper),
                format_copper(r.p25_unit_price_copper),
                format_copper(r.delta_vs_hist_median_copper),
                format_copper(r.delta_vs_hist_p25_copper),
                vendor_str,
                str(r.total_available) if r.total_available is not None else "—",
            ]
        )
    print(_render_table(headers, table_rows))
    return 0


def build_parser() -> argparse.ArgumentParser:
    from . import __version__

    parser = argparse.ArgumentParser(
        prog="ah-tracker",
        description="WoW: Forever Auction House Tracker & Transmute Analytics",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.add_argument("--db", help="Path to SQLite database (default: data/ah_tracker.sqlite)")

    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init-db", help="Initialize SQLite schema and seed starter items/recipes")
    p_init.add_argument("--no-seed", action="store_true", help="Skip starter Alchemy 275 seed data")

    p_fetch = sub.add_parser("fetch-api", help="Fetch auction snapshot from Blizzard Game Data API")
    p_fetch.add_argument("--ruleset-id", type=int, help="Blizzard ruleset ID (default: 1)")
    p_fetch.add_argument("--house-id", type=int, help="Auction house ID (auto-discovers first if omitted)")
    p_fetch.add_argument("--region", help="Blizzard API region (default: eu)")
    p_fetch.add_argument("--namespace", help="API namespace (default: dynamic-forever-eu)")
    p_fetch.add_argument("--locale", help="API locale (default: ru_RU)")
    p_fetch.add_argument("--client-id", help="Blizzard OAuth2 client_id")
    p_fetch.add_argument("--client-secret", help="Blizzard OAuth2 client_secret")
    p_fetch.add_argument("--window", choices=["morning", "prime", "offpeak"], help="Window tag")
    p_fetch.add_argument("--if-modified-since", help="HTTP If-Modified-Since header")
    p_fetch.add_argument("--no-commodities", action="store_true", help="Skip commodities endpoint")
    p_fetch.add_argument("--only-known", action="store_true", help="Store only items present in items table")
    p_fetch.add_argument("--no-dashboard", action="store_true", help="Skip regenerating data/dashboard.html")

    p_lua = sub.add_parser("import-lua", help="Import local SavedVariables Lua dump")
    p_lua.add_argument("file", nargs="?", help="Path to SavedVariables .lua file")
    p_lua.add_argument("--scan-type", choices=["full", "partial"], help="Scan completeness tag")
    p_lua.add_argument("--window", choices=["morning", "prime", "offpeak"], help="Window tag")
    p_lua.add_argument("--only-known", action="store_true", help="Store only items present in items table")

    p_rep = sub.add_parser("report", help="Show transmute profitability and payback report")
    p_rep.add_argument("--days", type=int, default=7, help="Historical lookback window in days (default: 7)")
    p_rep.add_argument("--fee-rate", type=float, help="AH fee rate (default: 0.05)")

    p_watch = sub.add_parser("watch", help="Show quick market slice for item IDs or names")
    p_watch.add_argument("items", nargs="*", help="Item IDs or partial names (empty = all known items)")
    p_watch.add_argument("--days", type=int, default=7, help="Historical lookback window in days (default: 7)")

    p_dash = sub.add_parser("dashboard", help="Generate interactive HTML price dynamics dashboard")
    p_dash.add_argument("--output", default="data/dashboard.html", help="Output HTML path (default: data/dashboard.html)")
    p_dash.add_argument("--house-id", type=int, help="Auction house ID (default: configured house_id)")
    p_dash.add_argument("--hours", type=int, default=24, help="Lookback hours for dynamics (default: 24)")

    p_sync = sub.add_parser("sync-static", help="Sync Russian item names and profession recipes from Blizzard API")
    p_sync.add_argument("--items-only", action="store_true", help="Sync only missing item names")
    p_sync.add_argument("--recipes-only", action="store_true", help="Sync only profession craft recipes")
    p_sync.add_argument("--media", action="store_true", help="Sync item icons and descriptions")
    p_sync.add_argument("--workers", type=int, default=20, help="Concurrent API workers (default: 20)")

    return parser


def cmd_sync_static(args: argparse.Namespace, cfg: TrackerConfig) -> int:
    if not cfg.blizzard_client_id or not cfg.blizzard_client_secret:
        print("Error: BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET must be set.")
        return 2
    client = BlizzardApiClient(
        cfg.blizzard_client_id,
        cfg.blizzard_client_secret,
        region=cfg.blizzard_region,
        namespace="static-forever-eu",
        locale="ru_RU",
    )
    with connect_db(cfg.db_path) as conn:
        init_db(conn, with_seed=True)
        if args.media:
            mcnt = sync_item_media_and_descriptions(conn, client, max_workers=args.workers)
            print(f"Synced item media/descriptions: updated={mcnt}")
        elif not args.recipes_only:
            upd, fail = sync_item_names(conn, client, max_workers=args.workers)
            print(f"Synced item names: updated={upd}, unresolved={fail}")
        if not args.items_only and not args.media:
            cnt = sync_craft_recipes(conn, client, max_workers=args.workers)
            print(f"Synced craft recipes: saved={cnt}")
        out = generate_dashboard_file(conn, Path("data/dashboard.html"), house_id=cfg.house_id)
        print(f"Dashboard updated at {out}")
    return 0


def cmd_dashboard(args: argparse.Namespace, cfg: TrackerConfig) -> int:
    house_id = args.house_id if args.house_id is not None else cfg.house_id
    with connect_db(cfg.db_path) as conn:
        init_db(conn, with_seed=True)
        out = generate_dashboard_file(conn, args.output, house_id=house_id, hours_back=args.hours)
    print(f"Dashboard generated at {out}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    cfg = TrackerConfig.from_env(db_path=args.db)

    if args.command == "init-db":
        return cmd_init_db(args, cfg)
    if args.command == "fetch-api":
        return cmd_fetch_api(args, cfg)
    if args.command == "import-lua":
        return cmd_import_lua(args, cfg)
    if args.command == "report":
        return cmd_report(args, cfg)
    if args.command == "watch":
        return cmd_watch(args, cfg)
    if args.command == "dashboard":
        return cmd_dashboard(args, cfg)
    if args.command == "sync-static":
        return cmd_sync_static(args, cfg)
    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
