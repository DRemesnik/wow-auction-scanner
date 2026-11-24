"""Unit tests for Blizzard Game Data API client (OAuth2, normalization, 304 cache)."""

from __future__ import annotations

import json

from tracker.blizzard_api import BlizzardApiClient, HttpResponse, normalize_blizzard_auctions


def test_normalize_blizzard_auctions_and_commodities() -> None:
    regular = [
        {"id": 1, "item": {"id": 12363}, "buyout": 900_000, "quantity": 2},
        {"id": 2, "item": {"id": 12363}, "bid": 100_000, "quantity": 1},  # no buyout -> skipped
    ]
    commodities = [
        {"id": 3, "item": {"id": 7076}, "unit_price": 25_000, "quantity": 15},
    ]
    lots_reg = normalize_blizzard_auctions(regular, is_commodity=False)
    lots_comm = normalize_blizzard_auctions(commodities, is_commodity=True)

    assert len(lots_reg) == 1
    assert lots_reg[0].unit_price_copper == 450_000
    assert lots_reg[0].quantity == 2

    assert len(lots_comm) == 1
    assert lots_comm[0].unit_price_copper == 25_000
    assert lots_comm[0].quantity == 15


def test_blizzard_client_oauth_and_304_not_modified() -> None:
    calls: list[str] = []

    def fake_fetch(url: str, headers: dict[str, str], data: bytes | None) -> HttpResponse:
        calls.append(url)
        if "oauth.battle.net/token" in url:
            return HttpResponse(200, json.dumps({"access_token": "tok123"}).encode("utf-8"))
        if url.endswith("/auctions/?namespace=dynamic-forever-eu&locale=ru_RU"):
            return HttpResponse(200, json.dumps({"auctions": [{"id": 77, "name": "EU Forever"}]}).encode("utf-8"))
        if "If-Modified-Since" in headers:
            return HttpResponse(304, b"", {"last-modified": headers["If-Modified-Since"]})
        if "/commodities" in url:
            return HttpResponse(
                200,
                json.dumps({"auctions": [{"item": {"id": 7076}, "unit_price": 30_000, "quantity": 4}]}).encode("utf-8"),
                {"last-modified": "Tue, 24 Nov 2026 10:00:00 GMT"},
            )
        return HttpResponse(
            200,
            json.dumps({"auctions": [{"item": {"id": 12363}, "buyout": 500_000, "quantity": 1}]}).encode("utf-8"),
            {"last-modified": "Tue, 24 Nov 2026 10:00:00 GMT"},
        )

    client = BlizzardApiClient("cid", "csec", http_fetch=fake_fetch)
    houses = client.get_auction_houses(1)
    assert len(houses) == 1
    assert houses[0].house_id == 77

    snap = client.fetch_house_snapshot(1, 77)
    assert snap.not_modified is False
    assert len(snap.lots) == 2
    assert snap.last_modified_auctions == "Tue, 24 Nov 2026 10:00:00 GMT"

    snap_304 = client.fetch_house_snapshot(
        1,
        77,
        if_modified_since_auctions="Tue, 24 Nov 2026 10:00:00 GMT",
        if_modified_since_commodities="Tue, 24 Nov 2026 10:00:00 GMT",
    )
    assert snap_304.not_modified is True
    assert snap_304.lots == []
