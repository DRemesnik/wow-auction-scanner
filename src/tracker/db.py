"""SQLite schema, migrations, seed data, and snapshot persistence."""

from __future__ import annotations

import json
import sqlite3
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

from .config import ItemCategory, NormalizedLot, ScanType, SourceType, WindowTag

SCHEMA_SQL = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS snapshots (
    snapshot_id INTEGER PRIMARY KEY AUTOINCREMENT,
    captured_at TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('blizzard_api', 'saved_variables')),
    scan_type TEXT NOT NULL CHECK (scan_type IN ('full', 'partial')),
    window_tag TEXT NOT NULL CHECK (window_tag IN ('morning', 'prime', 'offpeak')),
    ruleset_id INTEGER,
    house_id INTEGER,
    meta_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS items (
    item_id INTEGER PRIMARY KEY,
    name_ru TEXT NOT NULL,
    name_en TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('essence', 'recipe', 'cloth', 'crate', 'bar', 'other')),
    vendor_price_copper INTEGER
);

CREATE TABLE IF NOT EXISTS auction_observations (
    obs_id INTEGER PRIMARY KEY AUTOINCREMENT,
    snapshot_id INTEGER NOT NULL REFERENCES snapshots(snapshot_id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES items(item_id),
    min_unit_price_copper INTEGER NOT NULL,
    median_unit_price_copper INTEGER NOT NULL,
    p25_unit_price_copper INTEGER NOT NULL,
    total_available INTEGER NOT NULL,
    sample_size INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_obs_snapshot_item
    ON auction_observations (snapshot_id, item_id);

CREATE INDEX IF NOT EXISTS idx_obs_item
    ON auction_observations (item_id);

CREATE INDEX IF NOT EXISTS idx_snapshots_captured
    ON snapshots (captured_at);

CREATE TABLE IF NOT EXISTS transmute_recipes (
    recipe_id INTEGER PRIMARY KEY AUTOINCREMENT,
    recipe_item_id INTEGER REFERENCES items(item_id),
    name_ru TEXT NOT NULL,
    name_en TEXT NOT NULL,
    cooldown_hours INTEGER NOT NULL,
    cooldown_pool TEXT NOT NULL,
    input_item_id INTEGER NOT NULL REFERENCES items(item_id),
    input_qty INTEGER NOT NULL,
    output_item_id INTEGER NOT NULL REFERENCES items(item_id),
    output_qty INTEGER NOT NULL,
    vendor_recipe_price_copper INTEGER
);

CREATE TABLE IF NOT EXISTS recipe_extra_inputs (
    recipe_id INTEGER NOT NULL REFERENCES transmute_recipes(recipe_id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES items(item_id),
    qty INTEGER NOT NULL,
    PRIMARY KEY (recipe_id, item_id)
);

CREATE TABLE IF NOT EXISTS craft_recipes (
    recipe_id INTEGER PRIMARY KEY,
    output_item_id INTEGER NOT NULL,
    profession_ru TEXT NOT NULL,
    output_qty INTEGER NOT NULL DEFAULT 1,
    reagents_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_craft_recipes_output
    ON craft_recipes (output_item_id);
"""


@dataclass(frozen=True, slots=True)
class SeedItem:
    item_id: int
    name_ru: str
    name_en: str
    category: ItemCategory
    vendor_price_copper: int | None = None


@dataclass(frozen=True, slots=True)
class SeedRecipe:
    recipe_id: int
    recipe_item_id: int | None
    name_ru: str
    name_en: str
    cooldown_hours: int
    cooldown_pool: str
    input_item_id: int
    input_qty: int
    output_item_id: int
    output_qty: int
    vendor_recipe_price_copper: int | None = None
    extra_inputs: tuple[tuple[int, int], ...] = ()


SEED_ITEMS: tuple[SeedItem, ...] = (
    # Essences
    SeedItem(12803, "Субстанция Жизни", "Essence of Life", "essence"),
    SeedItem(7076, "Субстанция Земли", "Essence of Earth", "essence"),
    SeedItem(12808, "Субстанция Нежити", "Essence of Undeath", "essence"),
    SeedItem(7080, "Субстанция Воды", "Essence of Water", "essence"),
    SeedItem(7082, "Субстанция Воздуха", "Essence of Air", "essence"),
    SeedItem(7078, "Субстанция Огня", "Essence of Fire", "essence"),
    # Reagents & Bars
    SeedItem(12363, "Чародейный кристалл", "Arcane Crystal", "other"),
    SeedItem(12359, "Ториевый слиток", "Thorium Bar", "bar"),
    SeedItem(12655, "Зачарованный ториевый слиток", "Enchanted Thorium Bar", "bar"),
    SeedItem(12360, "Арканитовый слиток", "Arcanite Bar", "bar"),
    SeedItem(3575, "Железный слиток", "Iron Bar", "bar"),
    SeedItem(3577, "Золотой слиток", "Gold Bar", "bar"),
    SeedItem(3860, "Мифриловый слиток", "Mithril Bar", "bar"),
    SeedItem(6037, "Слиток истинного серебра", "Truesilver Bar", "bar"),
    # WoW Forever specific items
    SeedItem(248819, "Кристалл Скверны", "Fel Crystal", "other"),
    SeedItem(251290, "Слиток легионита", "Legionite Bar", "bar"),
    # Recipes
    SeedItem(13488, "Рецепт: трансмутация жизни в землю", "Recipe: Transmute Life to Earth", "recipe"),
    SeedItem(13486, "Рецепт: трансмутация нежити в воду", "Recipe: Transmute Undeath to Water", "recipe"),
    SeedItem(12958, "Рецепт: трансмутация арканита", "Recipe: Transmute Arcanite", "recipe", vendor_price_copper=50_000),
    SeedItem(284871, "Рецепт: трансмутация легионита", "Recipe: Transmute Legionite", "recipe"),
    SeedItem(9304, "Рецепт: трансмутация железа в золото", "Recipe: Transmute Iron to Gold", "recipe", vendor_price_copper=8_000),
    SeedItem(9305, "Рецепт: трансмутация мифрила в истинное серебро", "Recipe: Transmute Mithril to Truesilver", "recipe", vendor_price_copper=10_000),
    # Tailoring (Портняжное дело)
    SeedItem(14342, "Луноткань", "Mooncloth", "cloth"),
    SeedItem(14256, "Ткань Скверны", "Felcloth", "cloth"),
    SeedItem(14047, "Рунная ткань", "Runecloth", "cloth"),
    SeedItem(14048, "Рулон рунной ткани", "Bolt of Runecloth", "cloth"),
    SeedItem(4338, "Магическая ткань", "Mageweave Cloth", "cloth"),
    SeedItem(14155, "Сумка из луноткани", "Mooncloth Bag", "other"),
    SeedItem(14156, "Бездонная сумка", "Bottomless Bag", "other"),
    SeedItem(14046, "Сумка из рунной ткани", "Runecloth Bag", "other"),
    SeedItem(4238, "Льняная сумка", "Linen Bag", "other"),
    SeedItem(4240, "Шерстяная сумка", "Woolen Bag", "other"),
    SeedItem(4241, "Зеленая шерстяная сумка", "Green Woolen Bag", "other"),
    SeedItem(4245, "Маленькая шелковая сумка", "Small Silk Pack", "other"),
    SeedItem(10050, "Сумка из магической ткани", "Mageweave Bag", "other"),
    SeedItem(10051, "Красная сумка из магической ткани", "Red Mageweave Bag", "other"),
    SeedItem(21340, "Сума душ", "Soul Pouch", "other"),
    SeedItem(21341, "Сумка из ткани Скверны", "Felcloth Bag", "other"),
    SeedItem(21342, "Сумка из сердцевинной ткани Скверны", "Core Felcloth Bag", "other"),
    SeedItem(22246, "Зачарованный мешочек из магической ткани", "Enchanted Mageweave Pouch", "other"),
    SeedItem(22248, "Зачарованная сумка из рунной ткани", "Enchanted Runecloth Bag", "other"),
    SeedItem(22249, "Большая сумка зачаровывателя", "Big Bag of Enchantment", "other"),
    SeedItem(22250, "Мешочек для трав", "Herb Pouch", "other"),
    SeedItem(22251, "Кенарийская сумка для трав", "Cenarion Herb Bag", "other"),
    SeedItem(22252, "Кенарийская сумка", "Satchel of Cenarius", "other"),
    # WoW Forever Reagent Bags (Сумки с реагентами)
    SeedItem(253664, "Льняная сумка с реагентами", "Linen Reagent Bag", "other"),
    SeedItem(253667, "Шерстяная сумка с реагентами", "Woolen Reagent Bag", "other"),
    SeedItem(253973, "Шелковая сумка с реагентами", "Silk Reagent Bag", "other"),
    SeedItem(254035, "Сумка с реагентами из магической ткани", "Mageweave Reagent Bag", "other"),
    SeedItem(254079, "Сумка с реагентами из рунной ткани", "Runecloth Reagent Bag", "other"),
    SeedItem(254133, "Сумка с реагентами из луноткани", "Mooncloth Reagent Bag", "other"),
    SeedItem(254139, "Бездонная сумка с реагентами", "Bottomless Reagent Bag", "other"),
    SeedItem(277715, "Сумка с реагентами из легкой кожи", "Light Leather Reagent Bag", "other"),
    SeedItem(19682, "Жилет Кровавой Лозы", "Bloodvine Vest", "other"),
    SeedItem(19683, "Поножи Кровавой Лозы", "Bloodvine Leggings", "other"),
    SeedItem(19684, "Сапоги Кровавой Лозы", "Bloodvine Boots", "other"),
    SeedItem(18407, "Перчатки из ткани Скверны", "Felcloth Gloves", "other"),
    # Alchemy crafted consumables (Алхимия: настои, эликсиры, зелья)
    SeedItem(13510, "Настой титанов", "Flask of the Titans", "other"),
    SeedItem(13512, "Настой великой силы", "Flask of Supreme Power", "other"),
    SeedItem(13511, "Настой Концентрированной мудрости", "Flask of Distilled Wisdom", "other"),
    SeedItem(13457, "Сильное зелье защиты от огня", "Greater Fire Protection Potion", "other"),
    SeedItem(13459, "Сильное зелье защиты от темной магии", "Greater Shadow Protection Potion", "other"),
    SeedItem(13458, "Сильное зелье защиты от сил природы", "Greater Nature Protection Potion", "other"),
    SeedItem(13461, "Сильное зелье защиты от тайной магии", "Greater Arcane Protection Potion", "other"),
    SeedItem(13452, "Эликсир мангуста", "Elixir of the Mongoose", "other"),
    SeedItem(13454, "Сильный чародейский эликсир", "Greater Arcane Elixir", "other"),
    SeedItem(5634, "Зелье свободы действий", "Free Action Potion", "other"),
    SeedItem(13444, "Сильнейшее зелье маны", "Major Mana Potion", "other"),
    SeedItem(13446, "Сильнейшее лечебное зелье", "Major Healing Potion", "other"),
    SeedItem(13455, "Сильное зелье каменного щита", "Greater Stoneshield Potion", "other"),
    # Alchemy 30+ level potions & elixirs
    SeedItem(6149, "Сильное зелье маны", "Greater Mana Potion", "other"),
    SeedItem(3928, "Мощное лечебное зелье", "Superior Healing Potion", "other"),
    SeedItem(13443, "Высшее зелье маны", "Superior Mana Potion", "other"),
    SeedItem(9030, "Приводящее в сознание зелье", "Restorative Potion", "other"),
    SeedItem(9036, "Зелье защиты от магии", "Magic Resistance Potion", "other"),
    SeedItem(9144, "Зелье из дикой лозы", "Wildvine Potion", "other"),
    SeedItem(9172, "Зелье невидимости", "Invisibility Potion", "other"),
    SeedItem(12190, "Зелье спокойного сна", "Dreamless Sleep Potion", "other"),
    SeedItem(20002, "Сильное зелье спокойного сна", "Major Dreamless Sleep Potion", "other"),
    SeedItem(3387, "Слабое зелье неуязвимости", "Limited Invulnerability Potion", "other"),
    SeedItem(13442, "Мощное зелье ярости", "Mighty Rage Potion", "other"),
    SeedItem(18253, "Сильнейшее зелье омоложения", "Major Rejuvenation Potion", "other"),
    SeedItem(20008, "Зелье неудержимости", "Living Action Potion", "other"),
    SeedItem(20004, "Большой эликсир тролльей крови", "Major Troll's Blood Potion", "other"),
    SeedItem(20007, "Эликсир крови волшебника", "Mageblood Potion", "other"),
    SeedItem(13462, "Зелье очищения", "Purification Potion", "other"),
    SeedItem(13456, "Сильное зелье защиты от магии льда", "Greater Frost Protection Potion", "other"),
    SeedItem(13460, "Сильное зелье священной защиты", "Greater Holy Protection Potion", "other"),
    SeedItem(8951, "Эликсир защиты", "Elixir of Greater Defense", "other"),
    SeedItem(9155, "Чародейский эликсир", "Arcane Elixir", "other"),
    SeedItem(9179, "Сильный эликсир интеллекта", "Elixir of Greater Intellect", "other"),
    SeedItem(9187, "Сильный эликсир ловкости", "Elixir of Greater Agility", "other"),
    SeedItem(9206, "Действенный эликсир силы", "Elixir of Giants", "other"),
    SeedItem(9224, "Зелье истребления демонов", "Elixir of Demonslaying", "other"),
    SeedItem(9264, "Эликсир силы тьмы", "Elixir of Shadow Power", "other"),
    SeedItem(21546, "Эликсир энергии Света", "Elixir of Greater Firepower", "other"),
    SeedItem(9088, 'Эликсир "Дар Артаса"', "Gift of Arthas", "other"),
    SeedItem(13445, "Сильный эликсир защиты", "Elixir of Superior Defense", "other"),
    SeedItem(13447, "Эликсир мудрецов", "Elixir of the Sages", "other"),
    SeedItem(13453, "Эликсир грубой силы", "Elixir of Brute Force", "other"),
    SeedItem(250337, "Эликсир совы", "Elixir of the Owl", "other"),
)

SEED_RECIPES: tuple[SeedRecipe, ...] = (
    SeedRecipe(
        recipe_id=1,
        recipe_item_id=13488,
        name_ru="Жизнь в землю",
        name_en="Transmute: Life to Earth",
        cooldown_hours=23,
        cooldown_pool="elemental_23h",
        input_item_id=12803,
        input_qty=1,
        output_item_id=7076,
        output_qty=1,
    ),
    SeedRecipe(
        recipe_id=2,
        recipe_item_id=13486,
        name_ru="Нежить в воду",
        name_en="Transmute: Undeath to Water",
        cooldown_hours=23,
        cooldown_pool="elemental_23h",
        input_item_id=12808,
        input_qty=1,
        output_item_id=7080,
        output_qty=1,
    ),
    SeedRecipe(
        recipe_id=3,
        recipe_item_id=12958,
        name_ru="Арканит",
        name_en="Transmute: Arcanite",
        cooldown_hours=47,
        cooldown_pool="arcanite_legionite_47h",
        input_item_id=12363,
        input_qty=1,
        output_item_id=12360,
        output_qty=1,
        vendor_recipe_price_copper=50_000,
        extra_inputs=((12359, 1),),
    ),
    SeedRecipe(
        recipe_id=4,
        recipe_item_id=284871,
        name_ru="Легионит",
        name_en="Transmute: Legionite",
        cooldown_hours=47,
        cooldown_pool="arcanite_legionite_47h",
        input_item_id=248819,
        input_qty=1,
        output_item_id=251290,
        output_qty=1,
        extra_inputs=((12655, 1),),
    ),
    SeedRecipe(
        recipe_id=5,
        recipe_item_id=9304,
        name_ru="Железо в золото",
        name_en="Transmute: Iron to Gold",
        cooldown_hours=1,
        cooldown_pool="metal_1h",
        input_item_id=3575,
        input_qty=1,
        output_item_id=3577,
        output_qty=1,
        vendor_recipe_price_copper=8_000,
    ),
    SeedRecipe(
        recipe_id=6,
        recipe_item_id=9305,
        name_ru="Мифрил в истинное серебро",
        name_en="Transmute: Mithril to Truesilver",
        cooldown_hours=1,
        cooldown_pool="metal_1h",
        input_item_id=3860,
        input_qty=1,
        output_item_id=6037,
        output_qty=1,
        vendor_recipe_price_copper=10_000,
    ),
)


def connect_db(db_path: str | Path) -> sqlite3.Connection:
    """Open a SQLite connection with row factory and foreign keys enabled."""
    path = Path(db_path)
    if str(db_path) != ":memory:":
        path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON;")
    return conn


def init_db(conn: sqlite3.Connection, *, with_seed: bool = True) -> None:
    """Initialize SQLite schema and optionally populate seed items/recipes."""
    conn.executescript(SCHEMA_SQL)
    if with_seed:
        seed_reference_data(conn)
    conn.commit()


def seed_reference_data(conn: sqlite3.Connection) -> None:
    """Upsert starter Alchemy 275 items and transmute recipes."""
    for item in SEED_ITEMS:
        conn.execute(
            """
            INSERT INTO items (item_id, name_ru, name_en, category, vendor_price_copper)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET
                name_ru = excluded.name_ru,
                name_en = excluded.name_en,
                category = excluded.category,
                vendor_price_copper = COALESCE(excluded.vendor_price_copper, items.vendor_price_copper)
            """,
            (item.item_id, item.name_ru, item.name_en, item.category, item.vendor_price_copper),
        )

    for recipe in SEED_RECIPES:
        conn.execute(
            """
            INSERT INTO transmute_recipes (
                recipe_id, recipe_item_id, name_ru, name_en,
                cooldown_hours, cooldown_pool, input_item_id, input_qty,
                output_item_id, output_qty, vendor_recipe_price_copper
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(recipe_id) DO UPDATE SET
                recipe_item_id = excluded.recipe_item_id,
                name_ru = excluded.name_ru,
                name_en = excluded.name_en,
                cooldown_hours = excluded.cooldown_hours,
                cooldown_pool = excluded.cooldown_pool,
                input_item_id = excluded.input_item_id,
                input_qty = excluded.input_qty,
                output_item_id = excluded.output_item_id,
                output_qty = excluded.output_qty,
                vendor_recipe_price_copper = COALESCE(
                    excluded.vendor_recipe_price_copper,
                    transmute_recipes.vendor_recipe_price_copper
                )
            """,
            (
                recipe.recipe_id,
                recipe.recipe_item_id,
                recipe.name_ru,
                recipe.name_en,
                recipe.cooldown_hours,
                recipe.cooldown_pool,
                recipe.input_item_id,
                recipe.input_qty,
                recipe.output_item_id,
                recipe.output_qty,
                recipe.vendor_recipe_price_copper,
            ),
        )
        conn.execute("DELETE FROM recipe_extra_inputs WHERE recipe_id = ?", (recipe.recipe_id,))
        for extra_item_id, extra_qty in recipe.extra_inputs:
            conn.execute(
                "INSERT INTO recipe_extra_inputs (recipe_id, item_id, qty) VALUES (?, ?, ?)",
                (recipe.recipe_id, extra_item_id, extra_qty),
            )


def _weighted_percentile_copper(sorted_pairs: Sequence[tuple[int, int]], total_qty: int, pct: float) -> int:
    """Compute integer-copper percentile weighted by unit quantity without expanding arrays."""
    if not sorted_pairs or total_qty <= 0:
        return 0
    if total_qty == 1:
        return sorted_pairs[0][0]

    # Nearest-rank on 1..total_qty
    target_rank = max(1, min(total_qty, int(round(pct * (total_qty - 1))) + 1))
    cumulative = 0
    for price, qty in sorted_pairs:
        cumulative += qty
        if cumulative >= target_rank:
            return int(price)
    return int(sorted_pairs[-1][0])


def aggregate_lots(lots: Iterable[NormalizedLot]) -> dict[int, dict[str, int | str | None]]:
    """Aggregate normalized lots per item_id into integer-copper market stats."""
    grouped: dict[int, list[tuple[int, int]]] = defaultdict(list)
    names: dict[int, str] = {}

    for lot in lots:
        if lot.unit_price_copper <= 0 or lot.quantity <= 0:
            continue
        grouped[lot.item_id].append((int(lot.unit_price_copper), int(lot.quantity)))
        if lot.item_name and lot.item_id not in names:
            names[lot.item_id] = lot.item_name

    stats: dict[int, dict[str, int | str | None]] = {}
    for item_id, pairs in grouped.items():
        pairs.sort(key=lambda p: p[0])
        total_available = sum(qty for _, qty in pairs)
        stats[item_id] = {
            "min_unit_price_copper": pairs[0][0],
            "median_unit_price_copper": _weighted_percentile_copper(pairs, total_available, 0.50),
            "p25_unit_price_copper": _weighted_percentile_copper(pairs, total_available, 0.25),
            "total_available": total_available,
            "sample_size": len(pairs),
            "item_name": names.get(item_id),
        }
    return stats


def save_snapshot(
    conn: sqlite3.Connection,
    lots: Iterable[NormalizedLot],
    *,
    source: SourceType,
    scan_type: ScanType,
    window_tag: WindowTag,
    captured_at: datetime | None = None,
    ruleset_id: int | None = None,
    house_id: int | None = None,
    meta: dict | None = None,
    only_known_items: bool = False,
) -> tuple[int, int]:
    """Persist a snapshot and its aggregated auction_observations.

    Returns `(snapshot_id, observation_count)`.
    """
    ts = (captured_at or datetime.now(timezone.utc)).astimezone(timezone.utc).isoformat()
    meta_json = json.dumps(meta or {}, ensure_ascii=False, sort_keys=True)

    aggregated = aggregate_lots(lots)

    known_ids: set[int] | None = None
    if only_known_items:
        rows = conn.execute("SELECT item_id FROM items").fetchall()
        known_ids = {int(r["item_id"]) for r in rows}

    cur = conn.execute(
        """
        INSERT INTO snapshots (
            captured_at, source, scan_type, window_tag, ruleset_id, house_id, meta_json
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (ts, source, scan_type, window_tag, ruleset_id, house_id, meta_json),
    )
    snapshot_id = int(cur.lastrowid)

    obs_count = 0
    for item_id, st in aggregated.items():
        if known_ids is not None and item_id not in known_ids:
            continue

        item_name = st["item_name"]
        fallback_name = str(item_name) if item_name else f"Item {item_id}"
        conn.execute(
            """
            INSERT INTO items (item_id, name_ru, name_en, category)
            VALUES (?, ?, ?, 'other')
            ON CONFLICT(item_id) DO NOTHING
            """,
            (item_id, fallback_name, fallback_name),
        )
        conn.execute(
            """
            INSERT INTO auction_observations (
                snapshot_id, item_id, min_unit_price_copper,
                median_unit_price_copper, p25_unit_price_copper,
                total_available, sample_size
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                snapshot_id,
                item_id,
                st["min_unit_price_copper"],
                st["median_unit_price_copper"],
                st["p25_unit_price_copper"],
                st["total_available"],
                st["sample_size"],
            ),
        )
        obs_count += 1

    conn.commit()
    return snapshot_id, obs_count
