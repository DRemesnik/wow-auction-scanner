"""Configuration, environment loading, and shared copper/window utilities."""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

SourceType = Literal["blizzard_api", "saved_variables"]
ScanType = Literal["full", "partial"]
WindowTag = Literal["morning", "prime", "offpeak"]
ItemCategory = Literal["essence", "recipe", "cloth", "crate", "bar", "other"]

DEFAULT_DB_PATH = Path("data/ah_tracker.sqlite")
DEFAULT_RULESET_ID = 1
DEFAULT_HOUSE_ID = 113
DEFAULT_NAMESPACE = "dynamic-forever-eu"
DEFAULT_REGION = "eu"
DEFAULT_LOCALE = "ru_RU"
DEFAULT_AH_FEE_RATE = 0.05


@dataclass(frozen=True, slots=True)
class TrackerConfig:
    """Runtime configuration resolved from environment variables and defaults."""

    db_path: Path = DEFAULT_DB_PATH
    blizzard_client_id: str | None = None
    blizzard_client_secret: str | None = None
    blizzard_region: str = DEFAULT_REGION
    blizzard_namespace: str = DEFAULT_NAMESPACE
    blizzard_locale: str = DEFAULT_LOCALE
    ruleset_id: int = DEFAULT_RULESET_ID
    house_id: int | None = DEFAULT_HOUSE_ID
    saved_variables_path: Path | None = None
    ah_fee_rate: float = DEFAULT_AH_FEE_RATE

    @classmethod
    def from_env(cls, db_path: str | Path | None = None) -> "TrackerConfig":
        """Load configuration from environment variables."""
        resolved_db = Path(db_path) if db_path else Path(os.getenv("AH_TRACKER_DB", str(DEFAULT_DB_PATH)))
        raw_house = os.getenv("BLIZZARD_HOUSE_ID")
        raw_ruleset = os.getenv("BLIZZARD_RULESET_ID")
        raw_sv = os.getenv("SAVED_VARIABLES_PATH")
        raw_fee = os.getenv("AH_FEE_RATE")

        return cls(
            db_path=resolved_db,
            blizzard_client_id=os.getenv("BLIZZARD_CLIENT_ID") or None,
            blizzard_client_secret=os.getenv("BLIZZARD_CLIENT_SECRET") or None,
            blizzard_region=os.getenv("BLIZZARD_REGION", DEFAULT_REGION),
            blizzard_namespace=os.getenv("BLIZZARD_NAMESPACE", DEFAULT_NAMESPACE),
            blizzard_locale=os.getenv("BLIZZARD_LOCALE", DEFAULT_LOCALE),
            ruleset_id=int(raw_ruleset) if raw_ruleset else DEFAULT_RULESET_ID,
            house_id=int(raw_house) if raw_house else DEFAULT_HOUSE_ID,
            saved_variables_path=Path(raw_sv) if raw_sv else None,
            ah_fee_rate=float(raw_fee) if raw_fee else DEFAULT_AH_FEE_RATE,
        )


@dataclass(frozen=True, slots=True)
class NormalizedLot:
    """Unified normalized auction listing produced by all data connectors."""

    item_id: int
    unit_price_copper: int
    quantity: int = 1
    item_name: str | None = None


def infer_window_tag(dt: datetime | None = None) -> WindowTag:
    """Infer auction window tag (`morning`, `prime`, `offpeak`) from UTC hour."""
    current = dt or datetime.now(timezone.utc)
    hour = current.hour
    if 6 <= hour < 13:
        return "morning"
    if 16 <= hour < 23:
        return "prime"
    return "offpeak"


def format_copper(copper: int | None) -> str:
    """Format an integer copper amount into `Xg Ys Zc` (only for display)."""
    if copper is None:
        return "—"
    sign = "-" if copper < 0 else ""
    abs_val = abs(int(copper))
    gold = abs_val // 10_000
    silver = (abs_val % 10_000) // 100
    rem_copper = abs_val % 100

    parts: list[str] = []
    if gold > 0:
        parts.append(f"{gold}g")
    if silver > 0 or gold > 0:
        parts.append(f"{silver}s")
    parts.append(f"{rem_copper}c")
    return f"{sign}{' '.join(parts)}"
