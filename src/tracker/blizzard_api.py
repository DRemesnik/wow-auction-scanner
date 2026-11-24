"""Blizzard Game Data API connector (OAuth2 client_credentials + dynamic-forever-eu)."""

from __future__ import annotations

import base64
import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable

from .config import NormalizedLot

TOKEN_URL = "https://oauth.battle.net/token"


class BlizzardApiError(RuntimeError):
    """Raised when Blizzard OAuth2 or Game Data API requests fail."""


@dataclass(frozen=True, slots=True)
class HttpResponse:
    """Minimal HTTP response container for testability."""

    status: int
    body: bytes
    headers: dict[str, str] = field(default_factory=dict)


HttpFetcher = Callable[[str, dict[str, str], bytes | None], HttpResponse]


def default_http_fetch(url: str, headers: dict[str, str], data: bytes | None = None) -> HttpResponse:
    """Execute an HTTP request using standard library urllib."""
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_headers = {k.lower(): v for k, v in resp.headers.items()}
            return HttpResponse(status=resp.status, body=resp.read(), headers=resp_headers)
    except urllib.error.HTTPError as exc:
        if exc.code == 304:
            resp_headers = {k.lower(): v for k, v in exc.headers.items()} if exc.headers else {}
            return HttpResponse(status=304, body=b"", headers=resp_headers)
        detail = exc.read().decode("utf-8", errors="replace")
        raise BlizzardApiError(f"HTTP {exc.code} for {url}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise BlizzardApiError(f"Network error for {url}: {exc.reason}") from exc


@dataclass(frozen=True, slots=True)
class AuctionHouseInfo:
    """Auction house descriptor returned by Blizzard ruleset auctions index."""

    house_id: int
    name: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class ApiFetchResult:
    """Normalized result from fetching an auction house snapshot."""

    house_id: int
    lots: list[NormalizedLot]
    not_modified: bool = False
    last_modified_auctions: str | None = None
    last_modified_commodities: str | None = None
    meta: dict[str, Any] = field(default_factory=dict)


class BlizzardApiClient:
    """Client for Blizzard Game Data API (`dynamic-forever-eu`)."""

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        *,
        region: str = "eu",
        namespace: str = "dynamic-forever-eu",
        locale: str = "ru_RU",
        http_fetch: HttpFetcher = default_http_fetch,
    ) -> None:
        if not client_id or not client_secret:
            raise ValueError("BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET are required")
        self.client_id = client_id
        self.client_secret = client_secret
        self.region = region
        self.namespace = namespace
        self.locale = locale
        self._http_fetch = http_fetch
        self._access_token: str | None = None

    @property
    def base_url(self) -> str:
        return f"https://{self.region}.api.blizzard.com"

    def authenticate(self) -> str:
        """Obtain an OAuth2 access token using client_credentials."""
        creds = f"{self.client_id}:{self.client_secret}".encode("utf-8")
        basic = base64.b64encode(creds).decode("ascii")
        headers = {
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
        }
        body = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode("utf-8")
        resp = self._http_fetch(TOKEN_URL, headers, body)
        if resp.status != 200:
            raise BlizzardApiError(f"OAuth2 token request failed with status {resp.status}")
        payload = json.loads(resp.body.decode("utf-8"))
        token = payload.get("access_token")
        if not token:
            raise BlizzardApiError("OAuth2 response missing access_token")
        self._access_token = str(token)
        return self._access_token

    def _get_json(
        self,
        path: str,
        *,
        if_modified_since: str | None = None,
    ) -> tuple[dict[str, Any] | None, str | None, bool]:
        token = self._access_token or self.authenticate()
        sep = "&" if "?" in path else "?"
        url = f"{self.base_url}{path}{sep}namespace={urllib.parse.quote(self.namespace)}&locale={urllib.parse.quote(self.locale)}"
        headers = {"Authorization": f"Bearer {token}"}
        if if_modified_since:
            headers["If-Modified-Since"] = if_modified_since

        resp = self._http_fetch(url, headers, None)
        last_modified = resp.headers.get("last-modified")
        if resp.status == 304:
            return None, last_modified or if_modified_since, True
        if resp.status != 200:
            raise BlizzardApiError(f"API request failed ({resp.status}) for {url}")
        return json.loads(resp.body.decode("utf-8")), last_modified, False

    def get_auction_houses(self, ruleset_id: int) -> list[AuctionHouseInfo]:
        """List auction houses for `/data/wow/ruleset/{ruleset_id}/auctions/`."""
        data, _, _ = self._get_json(f"/data/wow/ruleset/{ruleset_id}/auctions/")
        if not data:
            return []
        houses: list[AuctionHouseInfo] = []
        raw_list = data.get("auctions") or data.get("connected_realms") or data.get("auction_houses") or []
        for entry in raw_list:
            house_id = entry.get("id")
            if house_id is None and isinstance(entry.get("href"), str):
                # Fallback: extract trailing integer from href
                parts = [p for p in entry["href"].split("/") if p]
                for part in reversed(parts):
                    if part.isdigit():
                        house_id = int(part)
                        break
            if house_id is not None:
                houses.append(
                    AuctionHouseInfo(
                        house_id=int(house_id),
                        name=entry.get("name"),
                        raw=entry,
                    )
                )
        return houses

    def fetch_house_snapshot(
        self,
        ruleset_id: int,
        house_id: int,
        *,
        if_modified_since_auctions: str | None = None,
        if_modified_since_commodities: str | None = None,
        include_commodities: bool = True,
    ) -> ApiFetchResult:
        """Fetch regular auctions (`buyout`) and commodities (`unit_price`) for a house."""
        lots: list[NormalizedLot] = []

        auc_data, lm_auc, not_mod_auc = self._get_json(
            f"/data/wow/ruleset/{ruleset_id}/auctions/{house_id}",
            if_modified_since=if_modified_since_auctions,
        )
        if auc_data:
            lots.extend(normalize_blizzard_auctions(auc_data.get("auctions", []), is_commodity=False))

        lm_comm: str | None = None
        not_mod_comm = True
        if include_commodities:
            comm_data, lm_comm, not_mod_comm = self._get_json(
                f"/data/wow/ruleset/{ruleset_id}/auctions/{house_id}/commodities",
                if_modified_since=if_modified_since_commodities,
            )
            if comm_data:
                lots.extend(normalize_blizzard_auctions(comm_data.get("auctions", []), is_commodity=True))

        all_not_modified = not_mod_auc and (not_mod_comm if include_commodities else True)
        return ApiFetchResult(
            house_id=house_id,
            lots=lots,
            not_modified=all_not_modified,
            last_modified_auctions=lm_auc,
            last_modified_commodities=lm_comm,
            meta={
                "namespace": self.namespace,
                "ruleset_id": ruleset_id,
                "house_id": house_id,
                "last_modified_auctions": lm_auc,
                "last_modified_commodities": lm_comm,
            },
        )


def normalize_blizzard_auctions(raw_auctions: list[dict[str, Any]], *, is_commodity: bool) -> list[NormalizedLot]:
    """Normalize Blizzard AH JSON entries into `NormalizedLot` objects in integer copper."""
    lots: list[NormalizedLot] = []
    for entry in raw_auctions:
        item = entry.get("item")
        if not isinstance(item, dict) or item.get("id") is None:
            continue
        item_id = int(item["id"])
        quantity = int(entry.get("quantity") or 1)
        if quantity <= 0:
            continue

        if is_commodity:
            raw_price = entry.get("unit_price")
            if raw_price is None or int(raw_price) <= 0:
                continue
            unit_price = int(raw_price)
        else:
            raw_buyout = entry.get("buyout")
            if raw_buyout is None or int(raw_buyout) <= 0:
                continue
            unit_price = int(raw_buyout) // quantity
            if unit_price <= 0:
                continue

        lots.append(NormalizedLot(item_id=item_id, unit_price_copper=unit_price, quantity=quantity))
    return lots
