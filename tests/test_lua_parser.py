"""Unit tests for Lua SavedVariables parser and addon dump normalizer."""

from __future__ import annotations

from pathlib import Path

from tracker.lua_parser import load_saved_variables, parse_lua_saved_variables


def test_parse_lua_tables_and_comments() -> None:
    lua_text = """
    -- Header comment
    --[[ Block
         comment ]]
    PriceLogDB = {
        scan_type = "full",
        items = {
            { item_id = 12363, unit_price = 450000, quantity = 3, name = "Arcane Crystal" },
            [2] = { ["itemId"] = 7076, ["buyout"] = 60000, ["count"] = 2 },
        },
        flag = true,
    }
    """
    parsed = parse_lua_saved_variables(lua_text)
    assert parsed["PriceLogDB"]["scan_type"] == "full"
    assert parsed["PriceLogDB"]["flag"] is True
    assert parsed["PriceLogDB"]["items"][1]["item_id"] == 12363


def test_load_pricelog_partial_vs_full(tmp_path: Path) -> None:
    p = tmp_path / "PriceLog.lua"
    p.write_text(
        """
        PriceLogDB = {
            items = {
                { item_id = 12808, unit_price = 12000, quantity = 5 },
                { item_id = 7076, buyout = 50000, quantity = 2 },
            }
        }
        """,
        encoding="utf-8",
    )
    res_partial = load_saved_variables(p)
    assert res_partial.scan_type == "partial"
    assert res_partial.format_name == "PriceLogDB"
    assert len(res_partial.lots) == 2
    assert res_partial.lots[0].unit_price_copper == 12000
    assert res_partial.lots[1].unit_price_copper == 25000
    assert res_partial.lots[1].quantity == 2

    res_full = load_saved_variables(p, scan_type="full")
    assert res_full.scan_type == "full"


def test_load_auctionator_with_name_resolution(tmp_path: Path) -> None:
    p = tmp_path / "Auctionator.lua"
    p.write_text(
        """
        AUCTIONATOR_PRICE_DATABASE = {
            ["__dbversion"] = 4,
            ["Пламегор Horde"] = {
                ["Субстанция Жизни"] = { ["m"] = 14500, ["h"] = 16000 },
                ["i:12363"] = { ["m"] = 480000 },
            },
        }
        """,
        encoding="utf-8",
    )
    res = load_saved_variables(p, name_to_id={"субстанция жизни": 12808})
    assert res.format_name == "Auctionator"
    assert len(res.lots) == 2
    by_id = {lot.item_id: lot for lot in res.lots}
    assert by_id[12808].unit_price_copper == 14500
    assert by_id[12363].unit_price_copper == 480000
