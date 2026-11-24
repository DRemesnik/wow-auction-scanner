"""Unit tests for current-snapshot craft cost calculation and HTML dashboard generation."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from tracker.config import NormalizedLot
from tracker.dashboard import build_dashboard_data, generate_dashboard_file
from tracker.db import connect_db, init_db, save_snapshot


def test_dashboard_current_craft_cost_and_profit(tmp_path: Path) -> None:
    conn = connect_db(":memory:")
    init_db(conn, with_seed=True)

    now = datetime(2026, 11, 24, 10, 30, tzinfo=timezone.utc)
    # Mooncloth (14342) = 2x Felcloth (14256)
    # Felcloth = 10_000c -> craft cost = 20_000c
    # Mooncloth AH min = 50_000c -> after 5% fee = 47_500c -> profit = 27_500c
    # 4 lots x 5 qty = 20 total_available, sample_size=4 -> liquid КРАФТИТЬ
    save_snapshot(
        conn,
        [
            NormalizedLot(14256, 10_000, 10),
            NormalizedLot(14342, 50_000, 5),
            NormalizedLot(14342, 52_000, 5),
            NormalizedLot(14342, 54_000, 5),
            NormalizedLot(14342, 55_000, 5),
            # Low-liquidity high-price item (1 lot at 300g) -> must be НЕЛИКВИД
            NormalizedLot(14048, 2_000, 10),
            NormalizedLot(14341, 4_000, 10),
            NormalizedLot(14155, 3_000_000, 1),
        ],
        source="blizzard_api",
        scan_type="full",
        window_tag="morning",
        house_id=113,
        captured_at=now,
    )

    data = build_dashboard_data(conn, house_id=113, now=now)
    mooncloth = next(i for i in data["items"] if i.item_id == 14342)
    assert mooncloth.current_min_copper == 50_000
    assert mooncloth.craft_cost_copper == 20_000
    assert mooncloth.craft_profit_copper == 27_500
    assert mooncloth.roi_pct == 137.5
    assert mooncloth.trade_signal == "КРАФТИТЬ"
    assert mooncloth.liquidity_label in ("Средняя", "Высокая")

    bag = next(i for i in data["items"] if i.item_id == 14155)
    assert bag.trade_signal == "НЕЛИКВИД"

    out_html = generate_dashboard_file(conn, tmp_path / "dashboard.html", house_id=113)
    text = out_html.read_text(encoding="utf-8")
    assert "Луноткань" in text
    assert "Динамика цен" in text
    assert "Торговые сигналы" in text
