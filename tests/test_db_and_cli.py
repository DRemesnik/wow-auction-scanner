"""Integration tests for DB aggregation and CLI commands."""

from __future__ import annotations

from pathlib import Path

from tracker.cli import main
from tracker.config import NormalizedLot
from tracker.db import aggregate_lots


def test_aggregate_lots_weighted_percentiles() -> None:
    lots = [
        NormalizedLot(7076, 10_000, 10),
        NormalizedLot(7076, 20_000, 10),
        NormalizedLot(7076, 50_000, 1),
    ]
    stats = aggregate_lots(lots)[7076]
    assert stats["min_unit_price_copper"] == 10_000
    assert stats["p25_unit_price_copper"] == 10_000
    assert stats["median_unit_price_copper"] == 20_000
    assert stats["total_available"] == 21
    assert stats["sample_size"] == 3


def test_cli_init_import_report_watch(tmp_path: Path, capsys) -> None:
    db_file = tmp_path / "test_ah.sqlite"
    lua_file = tmp_path / "PriceLog.lua"
    lua_file.write_text(
        """
        PriceLogDB = {
            items = {
                { item_id = 12803, unit_price = 10000, quantity = 5 },
                { item_id = 7076, unit_price = 30000, quantity = 6 },
            }
        }
        """,
        encoding="utf-8",
    )

    assert main(["--db", str(db_file), "init-db"]) == 0
    assert main(["--db", str(db_file), "import-lua", str(lua_file), "--scan-type", "partial", "--window", "prime"]) == 0
    assert main(["--db", str(db_file), "report", "--days", "7"]) == 0
    out_report = capsys.readouterr().out
    assert "Жизнь в землю" in out_report
    assert "выгодно" in out_report

    assert main(["--db", str(db_file), "watch", "7076"]) == 0
    out_watch = capsys.readouterr().out
    assert "Субстанция Земли" in out_watch
