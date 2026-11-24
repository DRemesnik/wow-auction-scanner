"""Analytics engine for transmute profitability, payback, vendor checks, and history."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Sequence

from .config import DEFAULT_AH_FEE_RATE


@dataclass(frozen=True, slots=True)
class HistoricalPriceStats:
    """Historical price summary over a lookback window (e.g. 7 or 14 days)."""

    median_copper: int | None
    p25_copper: int | None
    snapshot_count: int


@dataclass(frozen=True, slots=True)
class TransmuteReportRow:
    """Computed analytics row for a single transmute recipe."""

    recipe_id: int
    name_ru: str
    name_en: str
    cooldown_hours: int
    cooldown_pool: str
    input_name_ru: str
    output_name_ru: str
    input_cost_copper: int | None
    output_unit_price_copper: int | None
    output_qty: int
    net_profit_copper: int | None
    is_profitable: bool
    recipe_ah_price_copper: int | None
    vendor_recipe_price_copper: int | None
    recipe_overpriced_vs_vendor: bool
    input_overpriced_vs_vendor: bool
    payback_cycles: float | None
    payback_days_est: float | None
    output_total_available: int | None
    output_delta_vs_median_copper: int | None
    output_delta_vs_p25_copper: int | None
    status_note: str


@dataclass(frozen=True, slots=True)
class WatchItemRow:
    """Snapshot and historical analytics for a watched item."""

    item_id: int
    name_ru: str
    name_en: str
    category: str
    min_unit_price_copper: int | None
    median_unit_price_copper: int | None
    p25_unit_price_copper: int | None
    total_available: int | None
    vendor_price_copper: int | None
    overpriced_vs_vendor: bool
    hist_median_copper: int | None
    hist_p25_copper: int | None
    delta_vs_hist_median_copper: int | None
    delta_vs_hist_p25_copper: int | None


def calculate_net_revenue_copper(
    output_unit_price_copper: int,
    output_qty: int,
    input_total_cost_copper: int,
    *,
    ah_fee_rate: float = DEFAULT_AH_FEE_RATE,
) -> int:
    """Calculate net profit in integer copper after AH fee.

    `net_revenue = output_unit_price * output_qty * (1 - ah_fee_rate) - input_total_cost`
    """
    if ah_fee_rate < 0 or ah_fee_rate >= 1:
        raise ValueError("ah_fee_rate must be in [0, 1)")

    gross_output = Decimal(int(output_unit_price_copper) * int(output_qty))
    net_after_fee = int(
        (gross_output * (Decimal("1") - Decimal(str(ah_fee_rate)))).quantize(
            Decimal("1"), rounding=ROUND_HALF_UP
        )
    )
    return net_after_fee - int(input_total_cost_copper)


def calculate_payback(
    recipe_ah_price_copper: int | None,
    net_profit_per_cycle_copper: int | None,
    cooldown_hours: int,
) -> tuple[float | None, float | None, bool]:
    """Return `(payback_cycles, payback_days_est, is_profitable)`."""
    if net_profit_per_cycle_copper is None:
        return None, None, False
    if net_profit_per_cycle_copper <= 0:
        return None, None, False
    if recipe_ah_price_copper is None or recipe_ah_price_copper <= 0:
        return None, None, True

    cycles = recipe_ah_price_copper / net_profit_per_cycle_copper
    days_est = cycles * (cooldown_hours / 24.0)
    return round(cycles, 2), round(days_est, 2), True


def _int_median(values: Sequence[int]) -> int | None:
    if not values:
        return None
    s = sorted(values)
    n = len(s)
    mid = n // 2
    if n % 2 == 1:
        return int(s[mid])
    return (int(s[mid - 1]) + int(s[mid])) // 2


def get_latest_observation(conn: sqlite3.Connection, item_id: int) -> sqlite3.Row | None:
    """Fetch the most recent auction observation for `item_id`."""
    return conn.execute(
        """
        SELECT o.*, s.captured_at, s.window_tag, s.scan_type
        FROM auction_observations o
        JOIN snapshots s ON s.snapshot_id = o.snapshot_id
        WHERE o.item_id = ?
        ORDER BY s.captured_at DESC, o.snapshot_id DESC
        LIMIT 1
        """,
        (item_id,),
    ).fetchone()


def get_historical_stats(
    conn: sqlite3.Connection,
    item_id: int,
    *,
    days: int = 7,
    now: datetime | None = None,
) -> HistoricalPriceStats:
    """Compute historical median and p25 in integer copper over the last `days`."""
    ref_now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    cutoff = (ref_now - timedelta(days=days)).isoformat()

    rows = conn.execute(
        """
        SELECT o.median_unit_price_copper, o.p25_unit_price_copper
        FROM auction_observations o
        JOIN snapshots s ON s.snapshot_id = o.snapshot_id
        WHERE o.item_id = ? AND s.captured_at >= ?
        ORDER BY s.captured_at ASC
        """,
        (item_id, cutoff),
    ).fetchall()

    if not rows:
        return HistoricalPriceStats(median_copper=None, p25_copper=None, snapshot_count=0)

    medians = [int(r["median_unit_price_copper"]) for r in rows]
    p25s = [int(r["p25_unit_price_copper"]) for r in rows]
    return HistoricalPriceStats(
        median_copper=_int_median(medians),
        p25_copper=_int_median(p25s),
        snapshot_count=len(rows),
    )


def build_transmute_report(
    conn: sqlite3.Connection,
    *,
    ah_fee_rate: float = DEFAULT_AH_FEE_RATE,
    history_days: int = 7,
    now: datetime | None = None,
) -> list[TransmuteReportRow]:
    """Generate profitability and payback report for all transmute recipes."""
    recipes = conn.execute(
        """
        SELECT r.*,
               in_item.name_ru AS input_name_ru,
               in_item.vendor_price_copper AS input_vendor_price_copper,
               out_item.name_ru AS output_name_ru
        FROM transmute_recipes r
        JOIN items in_item ON in_item.item_id = r.input_item_id
        JOIN items out_item ON out_item.item_id = r.output_item_id
        ORDER BY r.cooldown_hours DESC, r.recipe_id ASC
        """
    ).fetchall()

    report: list[TransmuteReportRow] = []
    for r in recipes:
        recipe_id = int(r["recipe_id"])
        in_obs = get_latest_observation(conn, int(r["input_item_id"]))
        out_obs = get_latest_observation(conn, int(r["output_item_id"]))
        rec_obs = (
            get_latest_observation(conn, int(r["recipe_item_id"]))
            if r["recipe_item_id"] is not None
            else None
        )

        # Extra inputs (e.g., Thorium Bar for Arcanite)
        extra_rows = conn.execute(
            """
            SELECT e.item_id, e.qty, i.vendor_price_copper
            FROM recipe_extra_inputs e
            JOIN items i ON i.item_id = e.item_id
            WHERE e.recipe_id = ?
            """,
            (recipe_id,),
        ).fetchall()

        input_cost: int | None = None
        input_overpriced = False
        if in_obs is not None:
            in_min = int(in_obs["min_unit_price_copper"])
            input_cost = in_min * int(r["input_qty"])
            if r["input_vendor_price_copper"] is not None and in_min > int(r["input_vendor_price_copper"]):
                input_overpriced = True

            for er in extra_rows:
                er_obs = get_latest_observation(conn, int(er["item_id"]))
                if er_obs is None:
                    input_cost = None
                    break
                er_min = int(er_obs["min_unit_price_copper"])
                input_cost += er_min * int(er["qty"])
                if er["vendor_price_copper"] is not None and er_min > int(er["vendor_price_copper"]):
                    input_overpriced = True

        out_price = int(out_obs["min_unit_price_copper"]) if out_obs is not None else None
        out_avail = int(out_obs["total_available"]) if out_obs is not None else None

        net_profit: int | None = None
        if input_cost is not None and out_price is not None:
            net_profit = calculate_net_revenue_copper(
                out_price,
                int(r["output_qty"]),
                input_cost,
                ah_fee_rate=ah_fee_rate,
            )

        rec_ah_price = int(rec_obs["min_unit_price_copper"]) if rec_obs is not None else None
        vendor_rec_price = (
            int(r["vendor_recipe_price_copper"]) if r["vendor_recipe_price_copper"] is not None else None
        )
        recipe_overpriced = (
            rec_ah_price is not None
            and vendor_rec_price is not None
            and rec_ah_price > vendor_rec_price
        )

        payback_cycles, payback_days, is_profitable = calculate_payback(
            rec_ah_price, net_profit, int(r["cooldown_hours"])
        )

        hist = get_historical_stats(conn, int(r["output_item_id"]), days=history_days, now=now)
        delta_med = (
            out_price - hist.median_copper
            if (out_price is not None and hist.median_copper is not None)
            else None
        )
        delta_p25 = (
            out_price - hist.p25_copper
            if (out_price is not None and hist.p25_copper is not None)
            else None
        )

        notes: list[str] = []
        if net_profit is None:
            notes.append("нет данных АХ")
        elif net_profit <= 0:
            notes.append("убыточно")
        else:
            notes.append("выгодно")
        if recipe_overpriced:
            notes.append("рецепт на АХ дороже вендора!")
        if input_overpriced:
            notes.append("реагент на АХ дороже вендора!")

        report.append(
            TransmuteReportRow(
                recipe_id=recipe_id,
                name_ru=str(r["name_ru"]),
                name_en=str(r["name_en"]),
                cooldown_hours=int(r["cooldown_hours"]),
                cooldown_pool=str(r["cooldown_pool"]),
                input_name_ru=str(r["input_name_ru"]),
                output_name_ru=str(r["output_name_ru"]),
                input_cost_copper=input_cost,
                output_unit_price_copper=out_price,
                output_qty=int(r["output_qty"]),
                net_profit_copper=net_profit,
                is_profitable=is_profitable,
                recipe_ah_price_copper=rec_ah_price,
                vendor_recipe_price_copper=vendor_rec_price,
                recipe_overpriced_vs_vendor=recipe_overpriced,
                input_overpriced_vs_vendor=input_overpriced,
                payback_cycles=payback_cycles,
                payback_days_est=payback_days,
                output_total_available=out_avail,
                output_delta_vs_median_copper=delta_med,
                output_delta_vs_p25_copper=delta_p25,
                status_note="; ".join(notes),
            )
        )

    return report


def build_watchlist(
    conn: sqlite3.Connection,
    queries: Sequence[str],
    *,
    history_days: int = 7,
    now: datetime | None = None,
) -> list[WatchItemRow]:
    """Lookup items by item_id or partial Russian/English name and return market stats."""
    matched_items: list[sqlite3.Row] = []
    seen_ids: set[int] = set()

    if not queries:
        matched_items = conn.execute("SELECT * FROM items ORDER BY item_id ASC").fetchall()
    else:
        for q in queries:
            q_clean = q.strip()
            if not q_clean:
                continue
            if q_clean.isdigit():
                rows = conn.execute("SELECT * FROM items WHERE item_id = ?", (int(q_clean),)).fetchall()
            else:
                pattern = f"%{q_clean.lower()}%"
                rows = conn.execute(
                    "SELECT * FROM items WHERE lower(name_ru) LIKE ? OR lower(name_en) LIKE ?",
                    (pattern, pattern),
                ).fetchall()
            for r in rows:
                iid = int(r["item_id"])
                if iid not in seen_ids:
                    seen_ids.add(iid)
                    matched_items.append(r)

    results: list[WatchItemRow] = []
    for item in matched_items:
        iid = int(item["item_id"])
        obs = get_latest_observation(conn, iid)
        hist = get_historical_stats(conn, iid, days=history_days, now=now)

        min_p = int(obs["min_unit_price_copper"]) if obs is not None else None
        med_p = int(obs["median_unit_price_copper"]) if obs is not None else None
        p25_p = int(obs["p25_unit_price_copper"]) if obs is not None else None
        avail = int(obs["total_available"]) if obs is not None else None
        vendor_p = int(item["vendor_price_copper"]) if item["vendor_price_copper"] is not None else None

        overpriced = min_p is not None and vendor_p is not None and min_p > vendor_p
        delta_med = (min_p - hist.median_copper) if (min_p is not None and hist.median_copper is not None) else None
        delta_p25 = (min_p - hist.p25_copper) if (min_p is not None and hist.p25_copper is not None) else None

        results.append(
            WatchItemRow(
                item_id=iid,
                name_ru=str(item["name_ru"]),
                name_en=str(item["name_en"]),
                category=str(item["category"]),
                min_unit_price_copper=min_p,
                median_unit_price_copper=med_p,
                p25_unit_price_copper=p25_p,
                total_available=avail,
                vendor_price_copper=vendor_p,
                overpriced_vs_vendor=overpriced,
                hist_median_copper=hist.median_copper,
                hist_p25_copper=hist.p25_copper,
                delta_vs_hist_median_copper=delta_med,
                delta_vs_hist_p25_copper=delta_p25,
            )
        )
    return results
