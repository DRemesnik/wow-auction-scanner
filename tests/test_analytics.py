"""Unit tests for copper math, AH fee, payback, vendor checks, and historical deltas."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from tracker.analytics import (
    build_transmute_report,
    build_watchlist,
    calculate_net_revenue_copper,
    calculate_payback,
)
from tracker.config import NormalizedLot, format_copper
from tracker.db import connect_db, init_db, save_snapshot


def test_format_copper_integer_only() -> None:
    assert format_copper(0) == "0c"
    assert format_copper(45) == "45c"
    assert format_copper(12345) == "1g 23s 45c"
    assert format_copper(-50200) == "-5g 2s 0c"
    assert format_copper(None) == "—"


def test_net_revenue_copper_rounding_and_fee() -> None:
    # 10g output = 100_000c; 5% fee -> 95_000c; input 3g = 30_000c -> 65_000c
    profit = calculate_net_revenue_copper(100_000, 1, 30_000, ah_fee_rate=0.05)
    assert isinstance(profit, int)
    assert profit == 65_000

    # Zero margin: 100c * 0.95 = 95c; input 95c -> 0c
    assert calculate_net_revenue_copper(100, 1, 95, ah_fee_rate=0.05) == 0

    # Negative margin: 100c * 0.95 = 95c; input 120c -> -25c
    assert calculate_net_revenue_copper(100, 1, 120, ah_fee_rate=0.05) == -25


def test_payback_profitable_zero_and_negative() -> None:
    cycles, days, profitable = calculate_payback(200_000, 50_000, cooldown_hours=23)
    assert profitable is True
    assert cycles == 4.0
    assert days == pytest.approx(4.0 * 23 / 24.0, rel=1e-2)

    # Zero profit -> unprofitable
    c_zero, d_zero, p_zero = calculate_payback(200_000, 0, cooldown_hours=23)
    assert p_zero is False
    assert c_zero is None
    assert d_zero is None

    # Negative profit -> unprofitable
    c_neg, d_neg, p_neg = calculate_payback(200_000, -10_000, cooldown_hours=47)
    assert p_neg is False
    assert c_neg is None
    assert d_neg is None


def test_report_vendor_overpriced_and_history_deltas() -> None:
    conn = connect_db(":memory:")
    init_db(conn, with_seed=True)

    now = datetime(2026, 11, 24, 12, 0, tzinfo=timezone.utc)
    # Historical snapshot 3 days ago: Essence of Earth (7076) at 2g (20_000c)
    save_snapshot(
        conn,
        [NormalizedLot(7076, 20_000, 5)],
        source="blizzard_api",
        scan_type="full",
        window_tag="morning",
        captured_at=now - timedelta(days=3),
    )

    # Latest snapshot:
    # Life (12808) = 1g (10_000c), Earth (7076) = 3g (30_000c) -> profitable!
    # Recipe: Transmute Arcanite (12958) on AH = 8g (80_000c) > vendor 5g (50_000c)!
    # Arcane Crystal (12363) = 50g (500_000c), Thorium Bar (12359) = 1g (10_000c), Arcanite Bar (12360) = 52g (520_000c)
    # 520_000 * 0.95 - 510_000 = 494_000 - 510_000 = -16_000c (unprofitable due to 5% AH fee!)
    save_snapshot(
        conn,
        [
            NormalizedLot(12803, 10_000, 10),
            NormalizedLot(7076, 30_000, 8),
            NormalizedLot(12958, 80_000, 1),
            NormalizedLot(12363, 500_000, 4),
            NormalizedLot(12359, 10_000, 20),
            NormalizedLot(12360, 520_000, 3),
        ],
        source="blizzard_api",
        scan_type="full",
        window_tag="prime",
        captured_at=now,
    )

    rows = build_transmute_report(conn, ah_fee_rate=0.05, history_days=7, now=now)
    by_name = {r.name_en: r for r in rows}

    life_to_earth = by_name["Transmute: Life to Earth"]
    assert life_to_earth.is_profitable is True
    assert life_to_earth.net_profit_copper == 18_500  # 30_000 * 0.95 - 10_000
    assert life_to_earth.output_total_available == 8
    # Historical median of [20_000, 30_000] = 25_000 -> delta = +5_000
    assert life_to_earth.output_delta_vs_median_copper == 5_000

    arcanite = by_name["Transmute: Arcanite"]
    assert arcanite.is_profitable is False
    assert arcanite.net_profit_copper == -16_000
    assert arcanite.recipe_overpriced_vs_vendor is True
    assert "убыточно" in arcanite.status_note
    assert "рецепт на АХ дороже вендора!" in arcanite.status_note

    watch = build_watchlist(conn, ["12958", "Жизни"], history_days=7, now=now)
    assert len(watch) == 2
    rec_watch = next(w for w in watch if w.item_id == 12958)
    assert rec_watch.overpriced_vs_vendor is True
