"""Interactive HTML dashboard generator for current AH prices and craft costs."""

from __future__ import annotations

import html
import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

from . import __version__
from .analytics import build_transmute_report
from .config import DEFAULT_AH_FEE_RATE, format_copper
from .db import SEED_ITEMS

# Tradeable reagent recipes: output_item_id -> tuple of (reagent_item_id, qty)
CRAFT_RECIPES: dict[int, tuple[tuple[int, int], ...]] = {
    # Transmutes
    7076: ((12803, 1),),                   # Субстанция Земли <- Субстанция Жизни
    7080: ((12808, 1),),                   # Субстанция Воды <- Субстанция Нежити
    12360: ((12363, 1), (12359, 1)),       # Арканитовый слиток <- Чародейный кристалл + Ториевый слиток
    251290: ((248819, 1), (12655, 1)),     # Слиток легионита <- Кристалл Скверны + Зачарованный ториевый слиток
    3577: ((3575, 1),),                    # Золотой слиток <- Железный слиток
    6037: ((3860, 1),),                    # Слиток истинного серебра <- Мифриловый слиток
    # Tailoring
    14048: ((14047, 5),),                  # Рулон рунной ткани <- 5x Рунная ткань
    14342: ((14256, 2),),                  # Луноткань <- 2x Ткань Скверны
    14046: ((14048, 5), (8170, 2), (14341, 1)),    # Сумка из рунной ткани
    14155: ((14048, 4), (14342, 1), (14341, 1)),   # Сумка из луноткани
    14156: ((14342, 12), (14344, 8), (17012, 2), (14341, 2)),  # Бездонная сумка
    4238:  ((2996, 3), (2320, 3)),                 # Льняная сумка
    4240:  ((2997, 3), (2321, 1)),                 # Шерстяная сумка
    4241:  ((2997, 3), (2321, 1), (2605, 1)),      # Зеленая шерстяная сумка
    4245:  ((4305, 3), (4234, 2), (4291, 3)),      # Маленькая шелковая сумка
    10050: ((4339, 4), (8343, 2)),                 # Сумка из магической ткани
    10051: ((4339, 5), (8343, 2), (2604, 2)),      # Красная сумка из магической ткани
    21340: ((14048, 6), (8170, 4), (14341, 2)),    # Сума душ
    21341: ((14256, 12), (14048, 6), (11176, 4), (14341, 2)),  # Сумка из ткани Скверны
    21342: ((14342, 20), (17012, 12), (14344, 8), (14341, 4)), # Сумка из сердцевинной ткани Скверны
    22246: ((4339, 4), (11137, 2), (8343, 2)),     # Зачарованный мешочек из магической ткани
    22248: ((14048, 5), (16204, 2), (14341, 2)),   # Зачарованная сумка из рунной ткани
    22249: ((14048, 6), (11177, 4), (14341, 2)),   # Большая сумка зачаровывателя
    22250: ((4339, 4), (8153, 2), (8343, 2)),      # Мешочек для трав
    22251: ((14048, 5), (8831, 4), (14341, 2)),    # Кенарийская сумка для трав
    22252: ((14342, 4), (13463, 4), (14341, 2)),   # Кенарийская сумка
    # WoW Forever Reagent Bags (Сумки с реагентами)
    253664: ((2996, 6), (2320, 6)),                # Льняная сумка с реагентами
    253667: ((2997, 3), (2321, 1), (249409, 1)),   # Шерстяная сумка с реагентами
    253973: ((4305, 3), (4234, 2), (2321, 3), (249409, 3)),  # Шелковая сумка с реагентами
    254035: ((4339, 4), (8343, 2), (249430, 1), (249409, 1)),  # Сумка с реагентами из магической ткани
    254079: ((14048, 5), (8170, 2), (14341, 1), (249431, 1)),  # Сумка с реагентами из рунной ткани
    254133: ((14048, 4), (14342, 1), (14341, 1), (249431, 10), (249430, 1), (249409, 1)),  # Сумка с реагентами из луноткани
    254139: ((14048, 8), (14342, 12), (14344, 2), (249427, 5), (14341, 2), (249428, 5), (249429, 5)),  # Бездонная сумка с реагентами
    277715: ((2318, 8), (4231, 1), (2320, 3)),     # Сумка с реагентами из легкой кожи
    19682: ((14048, 4), (19726, 2), (14342, 2), (14341, 2)),   # Жилет Кровавой Лозы
    19683: ((14048, 4), (19726, 2), (14342, 1), (14341, 2)),   # Поножи Кровавой Лозы
    19684: ((14048, 4), (19726, 1), (14342, 1), (14341, 2)),   # Сапоги Кровавой Лозы
    # Alchemy (Flasks, Potions, Elixirs 30+)
    13510: ((13468, 1), (8846, 7), (13423, 30), (18256, 1)),   # Настой титанов
    13512: ((13468, 1), (13463, 30), (13465, 10), (18256, 1)), # Настой великой силы
    13511: ((13468, 1), (13463, 30), (13467, 10), (18256, 1)), # Настой очищенной мудрости
    13457: ((7068, 1), (13463, 1), (8925, 1)),                 # Сильное зелье защиты от огня
    13459: ((7078, 1), (13463, 1), (8925, 1)),                 # Сильное зелье защиты от темной магии
    13458: ((7067, 1), (13463, 1), (8925, 1)),                 # Сильное зелье защиты от природы
    13461: ((11176, 1), (13463, 1), (8925, 1)),                # Сильное зелье защиты от тайной магии
    13456: ((7070, 1), (13463, 1), (8925, 1)),                 # Сильное зелье защиты от магии льда
    13460: ((13463, 1), (7078, 1), (8925, 1)),                 # Сильное зелье защиты от светлой магии
    13452: ((13465, 2), (13466, 2), (8925, 1)),                # Эликсир мангуста
    13454: ((13463, 3), (13465, 1), (8925, 1)),                # Сильный эликсир тайной магии
    5634:  ((6358, 2), (3356, 1), (3372, 1)),                  # Зелье свободного действия
    13444: ((13463, 3), (13467, 2), (8925, 1)),                # Сильнейшее зелье маны
    13455: ((13423, 3), (3821, 1), (8925, 1)),                 # Сильное зелье каменного щита
    6149:  ((3358, 1), (3821, 1), (3372, 1)),                  # Сильное зелье маны
    13443: ((8838, 2), (8839, 2), (8925, 1)),                  # Высшее зелье маны
    9030:  ((7067, 1), (3821, 1), (8925, 1)),                  # Зелье восстановления
    9036:  ((3358, 1), (4625, 1), (8925, 1)),                  # Зелье защиты от магии
    9144:  ((8153, 1), (4625, 1), (8925, 1)),                  # Зелье дикой лозы
    9172:  ((8845, 1), (8838, 1), (8925, 1)),                  # Зелье невидимости
    12190: ((4625, 3), (8925, 1)),                             # Зелье спокойного сна
    20002: ((13463, 2), (13466, 1), (8925, 1)),                # Мощное зелье спокойного сна
    3387:  ((8839, 2), (8845, 1), (8925, 1)),                  # Зелье ограниченной неуязвимости
    13442: ((8846, 3), (8925, 1)),                             # Мощное зелье ярости
    18253: ((13468, 1), (13464, 4), (13463, 4), (18256, 1)),   # Мощное зелье омоложения
    20008: ((13467, 2), (13465, 2), (13463, 2), (8925, 1)),    # Зелье живого действия
    20004: ((8846, 1), (13466, 2), (8925, 1)),                 # Мощное зелье тролльей крови
    20007: ((13463, 1), (13466, 2), (8925, 1)),                # Эликсир крови мага
    13462: ((13467, 2), (13466, 2), (8925, 1)),                # Зелье очищения
    8951:  ((8153, 1), (3820, 1), (3372, 1)),                  # Эликсир великой защиты
    9155:  ((8839, 1), (3821, 1), (8925, 1)),                  # Магический эликсир
    9179:  ((8839, 1), (3358, 1), (8925, 1)),                  # Эликсир великого интеллекта
    9187:  ((8838, 1), (3821, 1), (8925, 1)),                  # Эликсир великой ловкости
    9206:  ((8838, 1), (8846, 1), (8925, 1)),                  # Эликсир великанов
    9224:  ((8846, 1), (8845, 1), (8925, 1)),                  # Эликсир убийцы демонов
    9264:  ((8845, 3), (8925, 1)),                             # Эликсир теневой силы
    21546: ((4625, 3), (7068, 1), (8925, 1)),                  # Эликсир великой огневой мощи
    9088:  ((9262, 1), (8839, 1), (8925, 1)),                  # Дар Артаса
    13445: ((13423, 2), (8838, 1), (8925, 1)),                 # Эликсир превосходной защиты
    13447: ((13463, 1), (13466, 2), (8925, 1)),                # Эликсир мудрецов
    13453: ((8846, 2), (13466, 2), (8925, 1)),                 # Эликсир грубой силы
}


@dataclass(frozen=True, slots=True)
class DashboardItemRow:
    """Current snapshot price and live craft cost for a single tracked item."""

    item_id: int
    name_ru: str
    group_label: str
    is_craftable: bool
    profession_ru: str | None
    current_min_copper: int | None
    p25_copper: int | None
    current_median_copper: int | None
    craft_cost_copper: int | None
    craft_profit_copper: int | None
    roi_pct: float | None
    trade_signal: str
    signal_score: int
    signal_reason: str
    liquidity_label: str
    sample_size: int
    reagents_text: str
    total_available: int
    icon_url: str | None = None
    description_ru: str | None = None
    quality: str | None = None


def _classify_liquidity(avail: int, sample_size: int, current_min: int | None) -> str:
    if avail >= 20 and sample_size >= 8:
        return "Высокая"
    if avail >= 10 and sample_size >= 4 and not (current_min is not None and current_min >= 500_000 and avail < 12):
        return "Средняя"
    if avail >= 5 and sample_size >= 3 and (current_min is None or current_min < 500_000):
        return "Огранич."
    return "Низкая"


def _evaluate_trade_decision(
    *,
    current_min: int | None,
    p25: int | None,
    median: int | None,
    craft_cost: int | None,
    craft_profit: int | None,
    roi_pct: float | None,
    avail: int,
    sample_size: int,
    history_pts: list[list] | None = None,
    reagent_batches: int | None = None,
) -> tuple[str, int, str]:
    """Compute `(signal, score_0_100, reason)` using liquidity, margin, book stability, velocity, and risk guards."""
    liq = _classify_liquidity(avail, sample_size, current_min)
    reasons: list[str] = []

    # 1. Liquidity & Depth (0..35)
    if sample_size >= 15 and avail >= 40:
        liq_score = 35
        reasons.append(f"глубокий рынок ({sample_size} лотов, {avail} шт.)")
    elif sample_size >= 8 and avail >= 20:
        liq_score = 28
        reasons.append(f"высокая ликвидность ({sample_size} лотов)")
    elif sample_size >= 4 and avail >= 10:
        liq_score = 18
        reasons.append(f"средняя ликвидность ({sample_size} лотов)")
    else:
        liq_score = 5 if avail >= 5 else 0

    # 2. Order-book stability: median / p25 (0..15)
    stab_score = 0
    spread_ratio = (median / p25) if (p25 and median and p25 > 0) else None
    if spread_ratio is not None:
        if spread_ratio <= 1.4:
            stab_score = 15
            reasons.append("плотный стакан")
        elif spread_ratio <= 2.0:
            stab_score = 8
        else:
            reasons.append("широкий разброс цен")

    # 3. Cross-snapshot demand velocity, dumping & 24h spike guard (-20..+15)
    vel_score = 0
    is_dumping = False
    is_price_spike = False
    hist_med_min: int | None = None
    if history_pts and len(history_pts) >= 2:
        first_min, first_avail = history_pts[0][1], history_pts[0][4]
        prev_min, prev_avail = history_pts[-2][1], history_pts[-2][4]
        cur_min_h, cur_avail_h = history_pts[-1][1], history_pts[-1][4]
        sorted_mins = sorted(int(pt[1]) for pt in history_pts)
        hist_med_min = sorted_mins[len(sorted_mins) // 2]

        # Price dumping check: >=8% drop from earliest snapshot with high supply
        if first_min > 0 and cur_min_h < first_min * 0.92 and cur_avail_h >= 20:
            is_dumping = True
            vel_score -= 20
            reasons.append("демпинг: цена падает")
        elif cur_avail_h < prev_avail and cur_min_h >= prev_min * 0.98:
            vel_score += 15
            reasons.append("спрос: остатки уходят")
        elif len(history_pts) >= 3 and cur_avail_h >= first_avail and cur_min_h <= first_min:
            vel_score -= 10
            reasons.append("затоваривание: остатки стоят")
        elif cur_avail_h != prev_avail:
            vel_score += 5

        if (
            len(history_pts) >= 4
            and current_min is not None
            and hist_med_min > 0
            and current_min > hist_med_min * 1.40
        ):
            is_price_spike = True
            vel_score -= 15
            reasons.append("пик цены vs 24ч медианы")

    # 3b. Non-stackable 1-unit-per-lot competition vs stackable commodity velocity
    is_crowded_singles = sample_size >= 30 and avail == sample_size
    is_single_unit_gear = sample_size >= 10 and avail == sample_size
    if is_crowded_singles:
        vel_score -= 15
        reasons.append(f"конкуренция {sample_size} лотов по 1 шт.")
    elif is_single_unit_gear:
        vel_score -= 8
        reasons.append(f"единичные лоты ({sample_size} шт.)")
    elif sample_size >= 8 and avail >= sample_size * 3:
        vel_score += 5
        reasons.append("высокая оборачиваемость")

    # Low liquidity guard: never recommend heavy crafting on thin books
    if liq == "Низкая":
        if craft_profit is not None and craft_profit > 0:
            return "НЕЛИКВИД", min(30, liq_score + stab_score), f"риск зависания: {avail} шт., {sample_size} лот."
        if craft_profit is not None and craft_profit <= 0:
            return "УБЫТОЧНО", 0, "отрицательная маржа и низкая ликвидность"
        return "—", 0, "нет крафта"

    # 4. Snipe / Arbitrage check (deep tight book, non-gear, validated against 24h median)
    if (
        current_min is not None
        and current_min > 0
        and p25 is not None
        and p25 > 0
        and avail >= 20
        and sample_size >= 8
        and not is_single_unit_gear
        and (spread_ratio is None or spread_ratio <= 1.5)
    ):
        flip_profit = int(p25 * 0.95) - current_min
        disc_vs_p25 = (p25 - current_min) / p25
        flip_roi = (flip_profit / current_min) * 100.0
        not_overpriced_hist = (
            hist_med_min is None
            or len(history_pts or []) < 3
            or current_min <= int(hist_med_min * 1.02)
        )
        if disc_vs_p25 >= 0.20 and flip_profit >= 5_000 and not_overpriced_hist:
            flip_pts = min(20, int(flip_profit / 2_500)) + min(15, int(flip_roi / 4))
            score = max(0, min(100, liq_score + stab_score + max(0, vel_score) + flip_pts))
            return "СКУПКА", score, f"дисконт {int(disc_vs_p25 * 100)}% к P25 (+{format_copper(flip_profit)}/шт.); " + ", ".join(reasons)

    # 5. Margin & Absolute Profit (0..35)
    if craft_profit is not None and craft_cost is not None and craft_cost > 0:
        if craft_profit <= 0:
            return "УБЫТОЧНО", 0, "крафт дороже продажи (-5% АХ)"

        # Penalize micro-profits (< 20s = 2_000c) even if ROI% looks high
        if craft_profit < 2_000:
            score = min(44, 10 + liq_score // 2 + stab_score // 2)
            return "ОСТОРОЖНО", score, f"микро-профит ({format_copper(craft_profit)}); " + ", ".join(reasons)

        abs_pts = min(20, int(craft_profit / 2_500))  # 50s -> 20 pts
        roi_pts = min(15, int((roi_pct or 0) / 4))     # 60% ROI -> 15 pts
        total_score = max(0, min(100, liq_score + stab_score + vel_score + abs_pts + roi_pts))

        if reagent_batches is not None and reagent_batches < 2:
            return "ОСТОРОЖНО", min(52, total_score), f"мало реагентов на АХ (хватит на {reagent_batches} шт.); " + ", ".join(reasons)
        if is_price_spike and hist_med_min is not None and int(hist_med_min * 0.95) <= craft_cost:
            return "ОСТОРОЖНО", min(55, total_score), "; ".join(reasons)
        if is_dumping or is_crowded_singles:
            return "ОСТОРОЖНО", min(59, total_score), "; ".join(reasons)
        if liq == "Огранич.":
            return "ОСТОРОЖНО", min(55, total_score), f"огранич. ликвидность ({avail} шт.); " + ", ".join(reasons)
        if total_score >= 65:
            return "КРАФТИТЬ", total_score, "; ".join(reasons) or "высокая маржа и ликвидность"
        if total_score >= 45:
            return "ВЫГОДНО", total_score, "; ".join(reasons) or "положительная маржа"
        return "ОСТОРОЖНО", total_score, "; ".join(reasons) or "умеренная оценка"

    return "—", liq_score + stab_score, ", ".join(reasons) or "рыночный товар"


REAGENT_NAMES_RU: dict[int, str] = {
    2318: "Тонкая кожа",
    2320: "Грубая нить",
    2321: "Тонкая нить",
    2604: "Красная краска",
    2605: "Зеленая краска",
    2996: "Рулон льняной ткани",
    2997: "Рулон шерсти",
    3356: "Королевская кровь",
    3358: "Кадгаров ус",
    3372: "Освинцованная колба",
    3575: "Железный слиток",
    3820: "Удавник",
    3821: "Златошип",
    3860: "Мифриловый слиток",
    4231: "Обработанная легкая шкура",
    4234: "Толстая кожа",
    4291: "Шелковая нить",
    4305: "Рулон шелка",
    4339: "Рулон магической ткани",
    4625: "Огнецвет",
    6358: "Масляный черноротик",
    7067: "Первородная земля",
    7068: "Первородный огонь",
    7070: "Первородная вода",
    7078: "Субстанция Огня",
    8153: "Дикая лоза",
    8170: "Грубая кожа",
    8343: "Толстая шелковая нить",
    8831: "Лиловый лотос",
    8838: "Солнечник",
    8839: "Пастушья сумка",
    8845: "Призрачная поганка",
    8846: "Кровь Грома",
    8925: "Хрустальная колба",
    9262: "Черный купорос",
    11137: "Пыль провидения",
    11176: "Сонная пыль",
    11177: "Малый светозарный осколок",
    12359: "Ториевый слиток",
    12363: "Чародейный кристалл",
    12655: "Зачарованный ториевый слиток",
    12803: "Субстанция Жизни",
    12808: "Субстанция Нежити",
    13423: "Масло каменного угря",
    13463: "Снолист",
    13464: "Золотой сансам",
    13465: "Горный серебряный шалфей",
    13466: "Чумоцвет",
    13467: "Ледяной зев",
    13468: "Черный лотос",
    14047: "Рунная ткань",
    14048: "Рулон рунной ткани",
    14256: "Ткань Скверны",
    14341: "Руническая нить",
    14342: "Луноткань",
    14344: "Большой сверкающий осколок",
    16204: "Пыль иллюзий",
    17012: "Сердцевинная кожа",
    18256: "Укрепленная колба",
    19726: "Кровавая лоза",
    248819: "Кристалл Скверны",
    249409: "Небесно-голубая краска",
    249427: "Нетронутая кожа",
    249428: "Нетронутая шкура",
    249429: "Нетронутая чешуя",
    249430: "Малиновая краска",
    249431: "Изумрудная краска",
}


def _format_reagents_text(
    recipe: tuple[tuple[int, int], ...] | None,
    names_map: dict[int, str],
) -> str:
    if not recipe:
        return "—"
    parts = [
        f"{qty}× {names_map.get(rid) or REAGENT_NAMES_RU.get(rid, f'#{rid}')}"
        for rid, qty in recipe
    ]
    return ", ".join(parts)


TAILORING_ITEM_IDS = {
    14156, 14155, 14046, 19682, 19683, 19684, 18407,
    4238, 4240, 4241, 4245, 10050, 10051,
    21340, 21341, 21342, 22246, 22248, 22249, 22250, 22251, 22252,
    253664, 253667, 253973, 254035, 254079, 254133, 254139, 277715,
}

# In WoW: Forever, healing potions & discolored healing potions belong to First Aid (Первая помощь)
FOREVER_FIRST_AID_ITEMS = {118, 858, 1710, 3928, 4596, 13446, 241650, 247239, 247240, 247241, 247242}


def _classify_item_group(item_id: int, category: str) -> str:
    if category == "cloth" or item_id in TAILORING_ITEM_IDS:
        return "Портняжное дело"
    if category in {"essence", "bar", "recipe"} or item_id in {12363, 248819}:
        return "Трансмутации и реагенты"
    return "Алхимия"


def _compute_craft_cost(
    recipe: tuple[tuple[int, int], ...] | None,
    price_map: dict[int, int],
    output_qty: int = 1,
) -> int | None:
    if not recipe:
        return None
    total = 0
    for reagent_id, qty in recipe:
        unit_p = price_map.get(reagent_id)
        if unit_p is None:
            return None
        total += unit_p * qty
    return total // max(1, output_qty)


def build_dashboard_data(
    conn: sqlite3.Connection,
    *,
    house_id: int | None = 113,
    ah_fee_rate: float = DEFAULT_AH_FEE_RATE,
    now: datetime | None = None,
    hours_back: int = 24,  # kept for signature compatibility
) -> dict:
    """Collect current snapshot prices and live craft costs (no historical lookback)."""
    ref_now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)

    if house_id is not None:
        latest_snap = conn.execute(
            "SELECT snapshot_id, captured_at, house_id, window_tag FROM snapshots WHERE house_id = ? ORDER BY captured_at DESC, snapshot_id DESC LIMIT 1",
            (house_id,),
        ).fetchone()
    else:
        latest_snap = conn.execute(
            "SELECT snapshot_id, captured_at, house_id, window_tag FROM snapshots ORDER BY captured_at DESC, snapshot_id DESC LIMIT 1"
        ).fetchone()

    items_out: list[DashboardItemRow] = []
    history_map: dict[str, list[list[Any]]] = {}
    if latest_snap is not None:
        snap_id = int(latest_snap["snapshot_id"])
        all_obs = conn.execute(
            "SELECT item_id, min_unit_price_copper, total_available FROM auction_observations WHERE snapshot_id = ?",
            (snap_id,),
        ).fetchall()
        price_map = {int(r["item_id"]): int(r["min_unit_price_copper"]) for r in all_obs}
        avail_map = {int(r["item_id"]): int(r["total_available"]) for r in all_obs}

        seed_ids = [item.item_id for item in SEED_ITEMS]
        seed_set = set(seed_ids)
        rows = conn.execute(
            """
            SELECT i.item_id, i.name_ru, i.category, i.icon_url, i.description_ru, i.quality,
                   o.min_unit_price_copper, o.p25_unit_price_copper,
                   o.median_unit_price_copper, o.total_available, o.sample_size
            FROM items i
            LEFT JOIN auction_observations o
              ON o.item_id = i.item_id AND o.snapshot_id = ?
            WHERE o.snapshot_id IS NOT NULL
               OR i.item_id IN ({})
               OR i.item_id IN (
                   SELECT output_item_id FROM craft_recipes
               )
            ORDER BY i.item_id ASC
            """.format(",".join("?" for _ in seed_ids)),
            [snap_id, *seed_ids],
        ).fetchall()

        # Load synced Blizzard craft recipes from SQLite
        db_recipes: dict[int, tuple[tuple[tuple[int, int], ...], int, str]] = {}
        for cr in conn.execute(
            "SELECT output_item_id, profession_ru, output_qty, reagents_json FROM craft_recipes"
        ).fetchall():
            oid = int(cr["output_item_id"])
            if oid not in db_recipes:
                parsed_reags = tuple((int(x[0]), int(x[1])) for x in json.loads(cr["reagents_json"]))
                raw_prof = str(cr["profession_ru"])
                if raw_prof == "Profession 2933":
                    raw_prof = "Горное дело"
                db_recipes[oid] = (parsed_reags, int(cr["output_qty"]), raw_prof)

        all_item_names = {
            int(r["item_id"]): str(r["name_ru"])
            for r in conn.execute("SELECT item_id, name_ru FROM items").fetchall()
        }

        history_map: dict[int, list[list]] = {}
        hist_sql = """
            SELECT o.item_id, s.captured_at, o.min_unit_price_copper,
                   o.p25_unit_price_copper, o.median_unit_price_copper, o.total_available
            FROM auction_observations o
            JOIN snapshots s ON s.snapshot_id = o.snapshot_id
            {where_clause}
            ORDER BY s.captured_at ASC, s.snapshot_id ASC
        """.format(where_clause="WHERE s.house_id = ?" if house_id is not None else "")
        hist_rows = conn.execute(hist_sql, (house_id,) if house_id is not None else ()).fetchall()
        for hr in hist_rows:
            history_map.setdefault(int(hr["item_id"]), []).append(
                [
                    str(hr["captured_at"])[:16].replace("T", " "),
                    int(hr["min_unit_price_copper"]),
                    int(hr["p25_unit_price_copper"]),
                    int(hr["median_unit_price_copper"]),
                    int(hr["total_available"]),
                ]
            )

        fee_mult = Decimal("1") - Decimal(str(ah_fee_rate))
        for r in rows:
            iid = int(r["item_id"])
            cur_min = int(r["min_unit_price_copper"]) if r["min_unit_price_copper"] is not None else None
            p25_val = int(r["p25_unit_price_copper"]) if r["p25_unit_price_copper"] is not None else None
            med_val = int(r["median_unit_price_copper"]) if r["median_unit_price_copper"] is not None else None
            avail_val = int(r["total_available"]) if r["total_available"] is not None else 0
            sample_val = int(r["sample_size"]) if r["sample_size"] is not None else 0

            curated_reags = CRAFT_RECIPES.get(iid)
            db_rec = db_recipes.get(iid)
            if curated_reags is not None:
                active_reags = curated_reags
                out_qty = 1
                prof_ru = db_rec[2] if db_rec else _classify_item_group(iid, str(r["category"]))
            elif db_rec is not None:
                active_reags, out_qty, prof_ru = db_rec
            else:
                active_reags, out_qty, prof_ru = None, 1, None

            if iid in FOREVER_FIRST_AID_ITEMS or prof_ru == "Первая помощь":
                prof_ru = "Первая помощь"

            is_craftable = active_reags is not None
            craft_cost = _compute_craft_cost(active_reags, price_map, out_qty) if is_craftable else None
            reagent_batches: int | None = None
            if is_craftable and active_reags:
                reagent_batches = min(avail_map.get(rid, 0) // max(1, rqty) for rid, rqty in active_reags)
            craft_profit: int | None = None
            roi_pct: float | None = None
            if craft_cost is not None and cur_min is not None:
                after_fee = int((Decimal(cur_min) * fee_mult).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
                craft_profit = after_fee - craft_cost
                if craft_cost > 0:
                    roi_pct = round((craft_profit / craft_cost) * 100.0, 1)

            signal, sig_score, sig_reason = _evaluate_trade_decision(
                current_min=cur_min,
                p25=p25_val,
                median=med_val,
                craft_cost=craft_cost,
                craft_profit=craft_profit,
                roi_pct=roi_pct,
                avail=avail_val,
                sample_size=sample_val,
                history_pts=history_map.get(iid),
                reagent_batches=reagent_batches,
            )
            liq_label = _classify_liquidity(avail_val, sample_val, cur_min)

            # Skip curated items that have neither AH listings nor a craft recipe
            if cur_min is None and not is_craftable:
                continue

            if prof_ru == "Первая помощь":
                group_label = "Первая помощь"
            elif prof_ru and prof_ru != "other":
                group_label = prof_ru
            elif iid in seed_set:
                group_label = _classify_item_group(iid, str(r["category"]))
            else:
                group_label = "Весь рынок"

            items_out.append(
                DashboardItemRow(
                    item_id=iid,
                    name_ru=str(r["name_ru"]),
                    group_label=group_label,
                    is_craftable=is_craftable,
                    profession_ru=prof_ru,
                    current_min_copper=cur_min,
                    p25_copper=p25_val,
                    current_median_copper=med_val,
                    craft_cost_copper=craft_cost,
                    craft_profit_copper=craft_profit,
                    roi_pct=roi_pct,
                    trade_signal=signal,
                    signal_score=sig_score,
                    signal_reason=sig_reason,
                    liquidity_label=liq_label,
                    sample_size=sample_val,
                    reagents_text=_format_reagents_text(active_reags, all_item_names),
                    total_available=avail_val,
                    icon_url=str(r["icon_url"]) if r["icon_url"] else None,
                    description_ru=str(r["description_ru"]) if r["description_ru"] else None,
                    quality=str(r["quality"]) if r["quality"] else None,
                )
            )

    items_out.sort(key=lambda x: (x.group_label, x.name_ru))
    transmutes = build_transmute_report(conn, ah_fee_rate=ah_fee_rate, history_days=7, now=ref_now)

    return {
        "generated_at": ref_now.isoformat(),
        "snapshot": dict(latest_snap) if latest_snap else None,
        "house_id": house_id,
        "items": items_out,
        "history": history_map,
        "transmutes": transmutes,
    }


def _format_copper_html(copper: int | None) -> str:
    """Format integer copper as inline HTML with WoW gold/silver/copper coin icons."""
    if copper is None:
        return "—"
    sign = "-" if copper < 0 else ""
    a = abs(int(copper))
    g, rem = divmod(a, 10_000)
    s, c = divmod(rem, 100)
    parts: list[str] = []
    if g > 0:
        parts.append(f'{g}<span class="wt-coin wt-coin-g" title="з"></span>')
    if s > 0 or g > 0:
        parts.append(f'{s}<span class="wt-coin wt-coin-s" title="с"></span>')
    parts.append(f'{c}<span class="wt-coin wt-coin-c" title="м"></span>')
    return f'<span class="coin-price">{sign}{"".join(parts)}</span>'


def render_dashboard_html(data: dict) -> str:
    """Render a self-contained dark-mode HTML dashboard with current prices & craft costs."""
    snap = data["snapshot"] or {}
    snap_time = snap.get("captured_at", "—")
    house_id = data.get("house_id") or snap.get("house_id") or "—"

    transmute_rows_html = []
    for t in data["transmutes"]:
        profit_cls = "pos" if (t.net_profit_copper or 0) > 0 else "neg"
        transmute_rows_html.append(
            f"<tr>"
            f"<td>{html.escape(t.name_ru)}</td>"
            f"<td>{t.cooldown_hours}h</td>"
            f"<td>{_format_copper_html(t.input_cost_copper)}</td>"
            f"<td>{_format_copper_html(t.output_unit_price_copper)}</td>"
            f"<td class='{profit_cls}'>{_format_copper_html(t.net_profit_copper)}</td>"
            f"<td>{t.output_total_available if t.output_total_available is not None else '—'}</td>"
            f"<td>{html.escape(t.status_note)}</td>"
            f"</tr>"
        )

    items_json = json.dumps(
        [
            {
                "item_id": it.item_id,
                "name_ru": it.name_ru,
                "group": it.group_label,
                "is_craftable": it.is_craftable,
                "profession": it.profession_ru or "—",
                "current_min": it.current_min_copper,
                "current_min_fmt": format_copper(it.current_min_copper),
                "p25": it.p25_copper,
                "p25_fmt": format_copper(it.p25_copper),
                "median": it.current_median_copper,
                "median_fmt": format_copper(it.current_median_copper),
                "craft_cost": it.craft_cost_copper,
                "craft_cost_fmt": format_copper(it.craft_cost_copper),
                "craft_profit": it.craft_profit_copper,
                "craft_profit_fmt": format_copper(it.craft_profit_copper),
                "roi": it.roi_pct,
                "roi_fmt": f"{it.roi_pct:+.1f}%" if it.roi_pct is not None else "—",
                "signal": it.trade_signal,
                "score": it.signal_score,
                "reason": it.signal_reason,
                "liquidity": it.liquidity_label,
                "samples": it.sample_size,
                "reagents": it.reagents_text,
                "avail": it.total_available,
                "icon": it.icon_url,
                "desc": it.description_ru,
                "quality": it.quality,
            }
            for it in data["items"]
        ],
        ensure_ascii=False,
    )
    history_json = json.dumps(data.get("history", {}), ensure_ascii=False)

    profitable_crafts = sum(1 for it in data["items"] if (it.craft_profit_copper or 0) > 0 and it.liquidity_label != "Низкая")
    action_signals = sum(1 for it in data["items"] if it.trade_signal in {"КРАФТИТЬ", "СКУПКА", "ВЫГОДНО"})

    prof_order = [
        "Алхимия",
        "Портняжное дело",
        "Кузнечное дело",
        "Кожевничество",
        "Инженерное дело",
        "Наложение чар",
        "Кулинария",
        "Первая помощь",
        "Горное дело",
        "Травничество",
    ]
    prof_counts: dict[str, int] = {}
    for it in data["items"]:
        if it.group_label not in {"Весь рынок", "Трансмутации и реагенты"}:
            prof_counts[it.group_label] = prof_counts.get(it.group_label, 0) + 1
    ordered_profs = [p for p in prof_order if p in prof_counts or p in {"Алхимия", "Портняжное дело", "Первая помощь"}] + sorted(
        p for p in prof_counts if p not in prof_order
    )
    prof_icons = {
        "Алхимия": '<path d="M9 3h6"/><path d="M10 3v6l-5 9a2 2 0 0 0 1.7 3h10.6a2 2 0 0 0 1.7-3l-5-9V3"/>',
        "Портняжное дело": '<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><line x1="20" y1="4" x2="8.12" y2="15.88"/><line x1="14.47" y1="14.48" x2="20" y2="20"/>',
        "Первая помощь": '<path d="M12 5v14"/><path d="M5 12h14"/><rect x="3" y="3" width="18" height="18" rx="3"/>',
        "Кузнечное дело": '<path d="m15 12-8.5 8.5c-.83.83-2.17.83-3 0 0 0 0 0 0 0a2.12 2.12 0 0 1 0-3L12 9"/><path d="M17.64 15 22 10.64"/><path d="m20.91 11.7-1.25-1.25c-.6-.6-.93-1.4-.93-2.25v-.86L16.01 4.6a5.56 5.56 0 0 0-3.94-1.64H9l.92.82A6.18 6.18 0 0 1 12 8.4v1.56l2 2h2.47l2.26 1.91"/>',
        "Кожевничество": '<path d="M12 3c4 0 7 3 7 7 0 5-3 11-7 11S5 15 5 10c0-4 3-7 7-7z"/>',
        "Инженерное дело": '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9c.26.6.85 1 1.51 1H21a2 2 0 1 1 0 4h-.09c-.66 0-1.25.4-1.51 1z"/>',
        "Наложение чар": '<path d="m12 3-1.912 5.813a2 2 0 0 1-1.275 1.275L3 12l5.813 1.912a2 2 0 0 1 1.275 1.275L12 21l1.912-5.813a2 2 0 0 1 1.275-1.275L21 12l-5.813-1.912a2 2 0 0 1-1.275-1.275L12 3Z"/>',
        "Кулинария": '<path d="M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2"/><path d="M7 2v20"/><path d="M21 15V2v0a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7"/>',
        "Горное дело": '<path d="m14 13-8.5 8.5a2.12 2.12 0 1 1-3-3L11 10"/><path d="m16 16 6-6"/><path d="m8 8 6-6"/><path d="m9 7 8 8"/>',
        "Травничество": '<path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10Z"/><path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12"/>',
    }
    prof_nav_html = "".join(
        f'<button class="nav-btn" data-view="{html.escape(pname)}">'
        f'<span class="nav-left"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
        f'{prof_icons.get(pname, "<circle cx=12 cy=12 r=4/>")}</svg> {html.escape(pname)}</span>'
        f'<span class="nav-count">{prof_counts.get(pname, 0)}</span>'
        f'</button>'
        for pname in ordered_profs
    )
    prof_tabs_html = (
        '<button class="prof-tab active" data-view="overview">Обзор</button>'
        '<button class="prof-tab" data-view="signals">Сигналы</button>'
        + "".join(
            f'<button class="prof-tab" data-view="{html.escape(pname)}">{html.escape(pname)} <span class="tab-cnt">{prof_counts.get(pname, 0)}</span></button>'
            for pname in ordered_profs
        )
        + f'<button class="prof-tab" data-view="ALL">Весь рынок <span class="tab-cnt">{len(data["items"])}</span></button>'
    )

    def _top_signals_for_prof(prof_name: str, limit: int = 6) -> list[DashboardItemRow]:
        candidates = [
            it
            for it in data["items"]
            if (it.profession_ru == prof_name or it.group_label == prof_name)
            and it.trade_signal in {"КРАФТИТЬ", "СКУПКА", "ВЫГОДНО"}
            and (it.craft_profit_copper or 0) > 0
        ]
        candidates.sort(key=lambda x: (x.signal_score, x.craft_profit_copper or 0), reverse=True)
        return candidates[:limit]

    def _render_signal_cards(rows: list[DashboardItemRow]) -> str:
        if not rows:
            return '<div class="meta">Нет активных сигналов в текущем снимке</div>'
        out = []
        for it in rows:
            sig_cls = "sig-craft" if it.trade_signal in {"КРАФТИТЬ", "ВЫГОДНО"} else ("sig-snipe" if it.trade_signal == "СКУПКА" else "sig-low")
            roi_txt = f" ({it.roi_pct:+.0f}%)" if it.roi_pct is not None else ""
            out.append(
                f"<div class='sig-row'>"
                f"<div><span class='badge {sig_cls}'>{html.escape(it.trade_signal)}</span> <b>{html.escape(it.name_ru)}</b> <span class='meta'>#{it.item_id} · ост. {it.total_available}</span></div>"
                f"<div class='pos'>+{_format_copper_html(it.craft_profit_copper)}{roi_txt}</div>"
                f"</div>"
                f"<div class='sig-sub'>АХ: {_format_copper_html(it.current_min_copper)} · Крафт: {_format_copper_html(it.craft_cost_copper)} · {html.escape(it.reagents_text)}</div>"
            )
        return "".join(out)

    def _render_prof_health(rows: list[DashboardItemRow], accent_hex: str) -> str:
        total = len(rows)
        if total == 0:
            return '<div class="meta">Нет позиций</div>'
        c_good = sum(1 for x in rows if x.trade_signal in {"КРАФТИТЬ", "ВЫГОДНО"})
        c_snipe = sum(1 for x in rows if x.trade_signal == "СКУПКА")
        c_warn = sum(1 for x in rows if x.trade_signal in {"ОСТОРОЖНО", "НЕЛИКВИД"})
        c_bad = max(0, total - c_good - c_snipe - c_warn)

        p_good = (c_good / total) * 100
        p_snipe = (c_snipe / total) * 100
        p_warn = (c_warn / total) * 100
        p_bad = max(0.0, 100.0 - p_good - p_snipe - p_warn)

        top_roi = sorted(
            [x for x in rows if x.trade_signal in {"КРАФТИТЬ", "СКУПКА", "ВЫГОДНО"} and (x.roi_pct or 0) > 0],
            key=lambda x: x.roi_pct or 0,
            reverse=True,
        )[:3]
        pills = "".join(
            f"<button class='quick-pill' data-id='{it.item_id}' title='Показать на графике'>"
            f"<span>{html.escape(it.name_ru[:22] + ('…' if len(it.name_ru) > 22 else ''))}</span>"
            f"<b class='mono' style='color:{accent_hex};'>+{it.roi_pct:.0f}%</b>"
            f"</button>"
            for it in top_roi
        ) or '<span class="meta">Нет ликвидных сигналов</span>'

        return (
            f"<div style='display:flex; justify-content:space-between; align-items:baseline; margin-bottom:10px;'>"
            f"<div><span class='dt-hex-big'>{c_good + c_snipe}</span> <span class='meta'>/ {total} ликвидных</span></div>"
            f"<span class='mono' style='font-size:12px; color:{accent_hex}; font-weight:600;'>{((c_good + c_snipe) / total) * 100:.0f}% рынка в плюсе</span>"
            f"</div>"
            f"<div class='seg-bar'>"
            f"<div style='width:{p_good:.1f}%; background:#2AB86F;' title='Крафтить/Выгодно: {c_good}'></div>"
            f"<div style='width:{p_snipe:.1f}%; background:#00B4D8;' title='Скупка: {c_snipe}'></div>"
            f"<div style='width:{p_warn:.1f}%; background:#F59E0B;' title='Осторожно/Неликвид: {c_warn}'></div>"
            f"<div style='width:{p_bad:.1f}%; background:#232D42;' title='Убыточно/Без цены: {c_bad}'></div>"
            f"</div>"
            f"<div class='seg-legend'>"
            f"<span><i style='background:#2AB86F'></i>Крафт: <b>{c_good}</b></span>"
            f"<span><i style='background:#00B4D8'></i>Скупка: <b>{c_snipe}</b></span>"
            f"<span><i style='background:#F59E0B'></i>Риск: <b>{c_warn}</b></span>"
            f"<span><i style='background:#334155'></i>Минус: <b>{c_bad}</b></span>"
            f"</div>"
            f"<div class='card-label' style='margin:12px 0 6px;'>Макс. ROI % (клик → график)</div>"
            f"<div style='display:flex; gap:6px; flex-wrap:wrap;'>{pills}</div>"
        )

    def _render_profit_svg(rows: list[DashboardItemRow], pill_bg: str = "#0078A8") -> str:
        if not rows:
            return '<div class="meta">Недостаточно данных для графика</div>'
        max_p = max((it.craft_profit_copper or 1) for it in rows)
        out = []
        for it in rows:
            val = max(0, it.craft_profit_copper or 0)
            pct = max(6, int((val / max_p) * 100))
            val_html = _format_copper_html(val)
            name_txt = html.escape(it.name_ru[:28] + ("…" if len(it.name_ru) > 28 else ""))
            out.append(
                f"<div class='dt-bar-row' data-id='{it.item_id}' style='cursor:pointer;'>"
                f"<span class='dt-bar-val mono'>{val_html}</span>"
                f"<div class='dt-bar-track'><div class='dt-bar-fill' style='width:{pct}%; background:{pill_bg};'>{name_txt}</div></div>"
                f"</div>"
            )
        return "".join(out)

    alch_all = [it for it in data["items"] if (it.profession_ru == "Алхимия" or it.group_label == "Алхимия") and it.is_craftable]
    tailor_all = [it for it in data["items"] if (it.profession_ru == "Портняжное дело" or it.group_label == "Портняжное дело") and it.is_craftable]
    alch_top = _top_signals_for_prof("Алхимия", 5)
    tailor_top = _top_signals_for_prof("Портняжное дело", 5)
    illiquid_count = sum(1 for it in data["items"] if it.trade_signal == "НЕЛИКВИД")
    best_liquid = max(
        (it for it in data["items"] if it.trade_signal in {"КРАФТИТЬ", "СКУПКА", "ВЫГОДНО"} and (it.craft_profit_copper or 0) > 0),
        key=lambda x: x.craft_profit_copper or 0,
        default=None,
    )
    best_liquid_html = f"+{_format_copper_html(best_liquid.craft_profit_copper)}" if best_liquid else "—"
    best_liquid_sub = html.escape(best_liquid.name_ru) if best_liquid else "—"

    return f"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate" />
<meta http-equiv="Pragma" content="no-cache" />
<meta http-equiv="Expires" content="0" />
<meta name="app-build" content="{html.escape(__version__)}|{html.escape(str(snap_time))}" />
<title>Goblin Broker: Forever — WoW: Forever EU Орда</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cdefs%3E%3ClinearGradient id='g1' x1='0' y1='0' x2='1' y2='1'%3E%3Cstop offset='0%25' stop-color='%23FEF08A'/%3E%3Cstop offset='55%25' stop-color='%23EAB308'/%3E%3Cstop offset='100%25' stop-color='%23B45309'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='32' height='32' rx='7' fill='%230B0F17'/%3E%3Cpath d='M2 7 L11 11 L10 16 Z M30 7 L21 11 L22 16 Z' fill='url(%23g1)'/%3E%3Cpath d='M9.5 10 L22.5 10 L20.5 22.5 L16 28.5 L11.5 22.5 Z' fill='url(%23g1)'/%3E%3Cpath d='M11.5 14.5 L15 16 L12 17 Z' fill='%230B0F17'/%3E%3Cpath d='M15 21.5 L16 17 L17 21.5 Z' fill='%230B0F17'/%3E%3Ccircle cx='20' cy='15.5' r='4.2' fill='%23064E3B' stroke='%23FEF08A' stroke-width='1.6'/%3E%3Ccircle cx='20' cy='15.5' r='2.2' fill='%2334D399'/%3E%3Cpath d='M23 19 L23 25' stroke='%2334D399' stroke-width='1.5' stroke-linecap='round'/%3E%3C/svg%3E" />
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600;700&family=Fira+Sans:wght@400;500;600;700&display=swap" rel="stylesheet" />
<style>
  :root {{
    --bg: #0B0F17; --rail: #101622; --card: #151C2B; --card-alt: #1C2538;
    --border: #232D42; --border-strong: #334155;
    --text: #F1F5F9; --muted: #94A3B8; --accent: #00B4D8; --accent-soft: rgba(0, 180, 216, 0.14);
    --pos: #2AB86F; --neg: #F43F5E; --warn: #F59E0B; --purple: #8B5CF6;
  }}
  * {{ box-sizing: border-box; scrollbar-width: thin; scrollbar-color: #334155 #101622; }}
  ::-webkit-scrollbar {{ width: 8px; height: 8px; }}
  ::-webkit-scrollbar-track {{ background: #101622; border-left: 1px solid #1E293B; }}
  ::-webkit-scrollbar-thumb {{ background: #334155; border-radius: 999px; border: 2px solid #101622; }}
  ::-webkit-scrollbar-thumb:hover {{ background: #00B4D8; }}
  ::-webkit-scrollbar-corner {{ background: #101622; }}
  body {{
    margin: 0;
    font-family: "Fira Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.45;
    font-variant-numeric: tabular-nums;
  }}
  .mono {{ font-family: "Fira Code", ui-monospace, SFMono-Regular, Menlo, monospace; }}
  .shell {{ display: grid; grid-template-columns: 232px 1fr; min-height: 100vh; }}
  .rail {{
    background: var(--rail);
    border-right: 1px solid var(--border);
    padding: 18px 14px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    position: sticky;
    top: 0;
    height: 100vh;
    overflow-y: auto;
  }}
  .brand {{ display: flex; align-items: center; gap: 10px; padding: 4px 6px; }}
  .brand-mark {{
    width: 34px; height: 34px; border-radius: 9px; flex-shrink: 0;
    background: #0B0F17; border: 1.5px solid rgba(250, 204, 21, 0.55);
    display: grid; place-items: center;
    box-shadow: 0 2px 10px rgba(250, 204, 21, 0.14);
  }}
  .brand-title {{ font-weight: 700; font-size: 14px; letter-spacing: -0.01em; }}
  .brand-sub {{ font-size: 11px; color: var(--muted); }}
  .nav-group {{ display: flex; flex-direction: column; gap: 3px; }}
  .nav-label {{ font-size: 10.5px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); padding: 6px 10px 4px; font-weight: 600; list-style: none; }}
  summary.nav-label {{ cursor: pointer; display: flex; align-items: center; justify-content: space-between; user-select: none; }}
  summary.nav-label::-webkit-details-marker {{ display: none; }}
  details.nav-group[open] summary.nav-label::after {{ content: "▾"; font-size: 11px; }}
  details.nav-group:not([open]) summary.nav-label::after {{ content: "▸"; font-size: 11px; }}
  .nav-btn {{
    display: flex; align-items: center; justify-content: space-between; gap: 8px;
    width: 100%; background: transparent; border: 1px solid transparent; border-radius: 8px;
    color: var(--muted); padding: 7px 10px; font-size: 13px; font-weight: 500;
    cursor: pointer; font-family: inherit; text-align: left; transition: all .14s ease;
  }}
  .nav-btn:hover {{ background: rgba(255,255,255,0.03); color: var(--text); }}
  .nav-btn.active {{ background: var(--accent-soft); border-color: rgba(0,180,216,0.32); color: var(--text); }}
  .nav-left {{ display: inline-flex; align-items: center; gap: 9px; }}
  .nav-count {{ font-family: "Fira Code", monospace; font-size: 11px; color: var(--muted); background: rgba(255,255,255,0.04); padding: 1px 6px; border-radius: 999px; }}
  .rail-footer {{ margin-top: auto; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 11px 12px; font-size: 11.5px; color: var(--muted); }}
  .main {{ display: flex; flex-direction: column; min-width: 0; }}
  .context-bar {{
    position: sticky; top: 0; z-index: 10;
    background: rgba(8, 11, 18, 0.88); backdrop-filter: blur(10px);
    border-bottom: 1px solid var(--border);
    padding: 12px 24px;
    display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap;
  }}
  .crumb {{ display: flex; align-items: center; gap: 8px; font-size: 13px; }}
  .crumb b {{ color: var(--text); }}
  .crumb span {{ color: var(--muted); }}
  .ctx-right {{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }}
  .search-wrap {{ position: relative; }}
  .search-wrap svg {{ position: absolute; left: 10px; top: 50%; transform: translateY(-50%); color: var(--muted); pointer-events: none; }}
  input[type=search] {{
    background: var(--card); color: var(--text); border: 1px solid var(--border);
    border-radius: 8px; padding: 7px 12px 7px 32px; min-width: 270px; font-size: 13px; color-scheme: dark;
  }}
  .btn:focus-visible, .nav-btn:focus-visible, input[type=search]:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
  .live-pill {{ display: inline-flex; align-items: center; gap: 8px; background: var(--card); border: 1px solid var(--border-strong); padding: 6px 12px; border-radius: 999px; font-size: 12px; color: var(--muted); }}
  .live-dot {{ width: 8px; height: 8px; border-radius: 50%; background: var(--pos); box-shadow: 0 0 10px var(--pos); animation: pulse 2.2s infinite; }}
  @keyframes pulse {{ 0%, 100% {{ opacity: 1; }} 50% {{ opacity: .45; }} }}
  .content {{ padding: 16px 24px 36px; display: flex; flex-direction: column; gap: 16px; max-width: 2100px; width: 100%; margin: 0 auto; }}
  .kpi-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(195px, 1fr)); gap: 12px; }}
  .card {{ background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 13px 15px; box-shadow: inset 0 1px 0 rgba(255,255,255,0.03); }}
  .dt-bento {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; margin-bottom: 12px; }}
  .dt-hex-big {{ font-family: "Fira Code", monospace; font-size: 24px; font-weight: 700; color: var(--text); }}
  .seg-bar {{ display: flex; height: 8px; border-radius: 999px; overflow: hidden; background: #1E293B; gap: 2px; margin-bottom: 10px; }}
  .seg-legend {{ display: flex; gap: 12px; flex-wrap: wrap; font-size: 11.5px; color: var(--muted); }}
  .seg-legend i {{ display: inline-block; width: 8px; height: 8px; border-radius: 2px; margin-right: 5px; }}
  .quick-pill {{ display: inline-flex; align-items: center; gap: 6px; background: var(--rail); border: 1px solid var(--border); border-radius: 6px; padding: 4px 8px; color: var(--text); font-size: 11.5px; cursor: pointer; font-family: inherit; transition: border-color .14s ease; }}
  .quick-pill:hover {{ border-color: var(--accent); background: var(--card-alt); }}
  .dt-bar-row {{ display: grid; grid-template-columns: 116px 1fr; gap: 8px; align-items: center; margin-bottom: 5px; font-size: 11.5px; }}
  .dt-bar-val {{ text-align: right; color: var(--text); font-weight: 600; display: flex; justify-content: flex-end; }}
  .dt-bar-track {{ background: #0E131D; border-radius: 4px; overflow: hidden; }}
  .dt-bar-fill {{ padding: 3px 8px; color: #FFFFFF; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; border-radius: 4px; }}
  .card-label {{ color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .06em; font-weight: 600; }}
  .card-val {{ font-family: "Fira Code", monospace; font-size: 22px; font-weight: 700; margin-top: 6px; letter-spacing: -0.02em; }}
  .card-sub {{ color: var(--muted); font-size: 12px; margin-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
  .panel-2 {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 14px; }}
  .section-head {{ display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px; }}
  .section-title {{ font-size: 14px; font-weight: 600; letter-spacing: -0.01em; margin: 0; }}
  .meta {{ color: var(--muted); font-size: 12px; }}
  .sig-row {{ display: flex; justify-content: space-between; align-items: center; padding-top: 9px; border-top: 1px solid var(--border); margin-top: 9px; font-size: 13px; cursor: pointer; }}
  .sig-row:hover {{ color: var(--accent); }}
  .sig-row:first-child {{ border-top: 0; margin-top: 0; padding-top: 0; }}
  .sig-sub {{ color: var(--muted); font-size: 11.5px; margin-top: 3px; }}
  .badge {{ display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 10.5px; font-weight: 700; letter-spacing: .04em; }}
  .sig-craft {{ background: rgba(42, 184, 111, 0.14); color: #2AB86F; border: 1px solid rgba(42, 184, 111, 0.38); }}
  .sig-snipe {{ background: rgba(0, 180, 216, 0.14); color: #00B4D8; border: 1px solid rgba(0, 180, 216, 0.38); }}
  .sig-low {{ background: rgba(245, 158, 11, 0.14); color: #F59E0B; border: 1px solid rgba(245, 158, 11, 0.38); }}
  .sig-bad {{ background: rgba(239, 68, 68, 0.12); color: #EF4444; border: 1px solid rgba(239, 68, 68, 0.32); }}
  .workspace-split {{ display: grid; grid-template-columns: minmax(0, 1.55fr) minmax(460px, 560px); gap: 16px; align-items: start; }}
  #inspectorSection {{ position: sticky; top: 68px; }}
  .inspector-grid {{ display: flex; flex-direction: column; gap: 12px; }}
  .insp-metrics {{ display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 10px; }}
  .insp-kv {{ background: var(--rail); border: 1px solid var(--border); border-radius: 8px; padding: 9px 11px; }}
  .insp-k {{ font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }}
  .insp-v {{ font-family: "Fira Code", monospace; font-size: 14px; font-weight: 600; margin-top: 3px; }}
  .prof-tabs-wrap {{ position: relative; display: flex; align-items: center; gap: 6px; margin-bottom: 10px; }}
  .prof-tabs {{ display: flex; gap: 6px; flex-wrap: nowrap; overflow-x: auto; scrollbar-width: none; scroll-behavior: smooth; flex: 1; min-width: 0; padding: 2px 0; }}
  .prof-tabs::-webkit-scrollbar {{ display: none; }}
  .tabs-arrow {{
    flex-shrink: 0; width: 26px; height: 26px; border-radius: 50%;
    background: var(--card); color: var(--text); border: 1px solid var(--border-strong);
    display: grid; place-items: center; cursor: pointer; font-size: 14px; line-height: 1;
    transition: all .14s ease;
  }}
  .tabs-arrow:hover {{ border-color: var(--accent); color: var(--accent); background: var(--card-alt); }}
  .tabs-arrow.hidden {{ display: none; }}
  .prof-tab {{
    background: var(--card); color: var(--muted); border: 1px solid var(--border); white-space: nowrap; flex-shrink: 0;
    border-radius: 999px; padding: 4px 10px; font-size: 12px; font-weight: 500;
    cursor: pointer; font-family: inherit; transition: all .14s ease; display: inline-flex; align-items: center; gap: 6px;
  }}
  .prof-tab:hover {{ color: var(--text); border-color: var(--border-strong); }}
  .prof-tab.active {{ color: var(--accent); border-color: var(--accent); background: var(--accent-soft); }}
  .tab-cnt {{ font-family: "Fira Code", monospace; font-size: 10.5px; opacity: .8; }}
  .controls {{ display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }}
  .btn {{ background: var(--card); color: var(--text); border: 1px solid var(--border); border-radius: 8px; padding: 6px 12px; cursor: pointer; font-size: 12.5px; font-weight: 500; transition: all .14s ease; font-family: inherit; }}
  .btn:hover {{ border-color: var(--border-strong); background: var(--card-alt); }}
  .btn.active {{ border-color: var(--accent); color: var(--accent); background: var(--accent-soft); }}
  .table-wrap {{ background: var(--card); border: 1px solid var(--border); border-radius: 10px; overflow: auto; max-height: 760px; }}
  .hide-reagents .col-reagents {{ display: none; }}
  table {{ width: 100%; border-collapse: collapse; }}
  th, td {{ padding: 7px 10px; border-bottom: 1px solid var(--border); text-align: left; font-size: 12.5px; white-space: nowrap; }}
  .item-name-txt {{ max-width: 230px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: inline-block; vertical-align: middle; }}
  th {{ position: sticky; top: 0; z-index: 2; color: var(--muted); font-weight: 600; background: #0D111C; font-size: 11px; text-transform: uppercase; letter-spacing: .05em; white-space: nowrap; }}
  th.num, td.num {{ text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }}
  td.num .coin-price {{ justify-content: flex-end; }}
  th.sortable {{ cursor: pointer; user-select: none; }}
  th.sortable:hover {{ color: var(--text); }}
  th.sortable.active-sort {{ color: var(--accent); }}
  tbody tr {{ transition: background .1s ease; }}
  tbody tr:hover {{ background: #182034; }}
  tbody tr.selected-row {{ background: rgba(0, 180, 216, 0.11); }}
  .fav-btn {{ background: transparent; border: 0; color: #475569; cursor: pointer; font-size: 14px; line-height: 1; padding: 2px 4px; transition: color .12s ease, transform .12s ease; }}
  .fav-btn:hover {{ color: #FACC15; transform: scale(1.12); }}
  .fav-btn.is-fav {{ color: #FACC15; }}
  .pos {{ color: var(--pos); font-weight: 600; font-family: "Fira Code", monospace; }}
  .neg {{ color: var(--neg); font-weight: 600; font-family: "Fira Code", monospace; }}
  .copy-btn {{ background: transparent; border: 0; color: var(--muted); cursor: pointer; padding: 2px 4px; border-radius: 4px; vertical-align: middle; opacity: .7; }}
  .copy-btn:hover {{ color: var(--accent); opacity: 1; }}
  .item-cell {{ display: inline-flex; align-items: center; gap: 8px; }}
  .item-icon {{ width: 22px; height: 22px; border-radius: 4px; border: 1px solid var(--border-strong); background: #0B0F17; object-fit: cover; flex-shrink: 0; }}
  .q-COMMON {{ color: #F1F5F9; }}
  .q-UNCOMMON {{ color: #1EFF00; }}
  .q-RARE {{ color: #38BDF8; }}
  .q-EPIC {{ color: #C084FC; }}
  #itemTooltip {{
    position: fixed; display: none; pointer-events: none; z-index: 60;
    min-width: 260px; max-width: 360px; background: rgba(9, 12, 20, 0.97);
    border: 1px solid #475569; border-radius: 7px; padding: 10px 12px;
    font-size: 12.5px; line-height: 1.38; box-shadow: 0 14px 34px rgba(0,0,0,0.72);
  }}
  .wt-line-w {{ color: #FFFFFF; }}
  .wt-line-g {{ color: #1EFF00; }}
  .wt-line-y {{ color: #FFD100; }}
  .wt-split {{ display: flex; justify-content: space-between; gap: 18px; color: #FFFFFF; }}
  .coin-price {{ white-space: nowrap; display: inline-flex; align-items: center; }}
  .wt-coin {{ display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin: 0 5px 0 2px; vertical-align: -1px; box-shadow: inset 0 -1px 2px rgba(0,0,0,0.55), 0 0 0 1px rgba(0,0,0,0.35); flex-shrink: 0; }}
  .wt-coin-g {{ background: radial-gradient(circle at 35% 30%, #FEF08A, #EAB308 65%, #A16207); }}
  .wt-coin-s {{ background: radial-gradient(circle at 35% 30%, #F8FAFC, #CBD5E1 65%, #64748B); }}
  .wt-coin-c {{ background: radial-gradient(circle at 35% 30%, #FDBA74, #D97706 65%, #7C2D12); }}
  #toast {{ position: fixed; bottom: 20px; right: 24px; background: var(--card); border: 1px solid var(--pos); color: var(--text); padding: 9px 14px; border-radius: 10px; font-size: 12.5px; opacity: 0; pointer-events: none; transition: opacity .2s ease; box-shadow: 0 8px 24px rgba(0,0,0,0.45); z-index: 50; }}
  #toast.show {{ opacity: 1; }}
  .hidden {{ display: none !important; }}
  @media (prefers-reduced-motion: reduce) {{
    *, *::before, *::after {{ animation: none !important; transition: none !important; }}
  }}
  @media (max-width: 1240px) {{
    .workspace-split {{ grid-template-columns: 1fr; }}
    #inspectorSection {{ position: static; }}
  }}
  @media (max-width: 980px) {{
    .shell {{ grid-template-columns: 1fr; }}
    .rail {{ position: static; height: auto; }}
    .panel-2 {{ grid-template-columns: 1fr; }}
  }}
</style>
</head>
<body>
<div class="shell">
  <aside class="rail">
    <div class="brand">
      <div class="brand-mark" aria-hidden="true">
        <svg width="28" height="28" viewBox="0 0 32 32" fill="none">
          <defs><linearGradient id="gbHead" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#FEF08A"/><stop offset="55%" stop-color="#EAB308"/><stop offset="100%" stop-color="#B45309"/></linearGradient></defs>
          <path d="M2 7 L11 11 L10 16 Z M30 7 L21 11 L22 16 Z" fill="url(#gbHead)"/>
          <path d="M9.5 10 L22.5 10 L20.5 22.5 L16 28.5 L11.5 22.5 Z" fill="url(#gbHead)"/>
          <path d="M11.5 14.5 L15 16 L12 17 Z" fill="#0B0F17"/>
          <path d="M15 21.5 L16 17 L17 21.5 Z" fill="#0B0F17"/>
          <circle cx="20" cy="15.5" r="4.2" fill="#064E3B" stroke="#FEF08A" stroke-width="1.6"/>
          <circle cx="20" cy="15.5" r="2.2" fill="#34D399"/>
          <path d="M23 19 L23 25" stroke="#34D399" stroke-width="1.5" stroke-linecap="round"/>
        </svg>
      </div>
      <div>
        <div class="brand-title">Goblin Broker: Forever</div>
        <div class="brand-sub">EU Орда · House {html.escape(str(house_id))} · v{html.escape(__version__)}</div>
      </div>
    </div>

    <div class="nav-group">
      <div class="nav-label">Консоль</div>
      <button class="nav-btn active" data-view="overview">
        <span class="nav-left"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="9" rx="1"/><rect x="14" y="3" width="7" height="5" rx="1"/><rect x="14" y="12" width="7" height="9" rx="1"/><rect x="3" y="16" width="7" height="5" rx="1"/></svg> Обзор (Overview)</span>
      </button>
      <button class="nav-btn" data-view="signals">
        <span class="nav-left"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg> Сигналы и рейтинг</span>
        <span class="nav-count" style="color:var(--pos);">{action_signals}</span>
      </button>
      <button class="nav-btn" data-view="transmutes">
        <span class="nav-left"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16"/><path d="M16 16h5v5"/></svg> Трансмутации (КД)</span>
        <span class="nav-count">{len(data['transmutes'])}</span>
      </button>
      <button class="nav-btn" data-view="ALL">
        <span class="nav-left"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="m19 9-5 5-4-4-3 3"/></svg> Весь рынок</span>
        <span class="nav-count">{len(data['items'])}</span>
      </button>
    </div>

    <details class="nav-group" open>
      <summary class="nav-label">Профессии ({len(ordered_profs)})</summary>
      {prof_nav_html}
    </details>

    <div class="rail-footer">
      <div style="color:var(--text); font-weight:600; margin-bottom:4px;">Телеметрия АХ</div>
      <div>Каденс: <span class="mono">1ч → 4ч → 6ч</span></div>
      <div>Комиссия АХ: <span class="mono">5%</span></div>
      <div>Защита: <span style="color:var(--pos);">Анти-неликвид ON</span></div>
    </div>
  </aside>

  <div class="main">
    <header class="context-bar">
      <div class="crumb">
        <span>EU Орда</span> <span>/</span> <span>House {html.escape(str(house_id))}</span> <span>/</span> <b id="viewTitle">Обзор (Overview)</b>
      </div>
      <div class="ctx-right">
        <div class="search-wrap">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
          <input type="search" id="searchBox" placeholder="Поиск по названию или ID (/)" />
        </div>
        <div class="live-pill">
          <span class="live-dot"></span>
          <span class="mono">{html.escape(str(snap_time)[:19].replace('T', ' '))} UTC</span>
        </div>
        <div class="live-pill" id="addonLiveBadge" style="display:none; border-color:rgba(52,211,153,.45); background:rgba(16,185,129,.12); color:#34D399;" title="Живая телеметрия из аддона Goblin Broker: Forever"></div>
      </div>
    </header>

    <main class="content">
      <section class="kpi-grid">
        <div class="card"><div class="card-label">Рыночный охват</div><div class="card-val">{len(data['items'])}</div><div class="card-sub">Активных позиций на АХ</div></div>
        <div class="card"><div class="card-label">Ликвидных сигналов</div><div class="card-val" style="color:var(--accent)">{action_signals}</div><div class="card-sub">КРАФТИТЬ / СКУПКА / ВЫГОДНО</div></div>
        <div class="card"><div class="card-label">Прибыльных крафтов</div><div class="card-val pos">{profitable_crafts}</div><div class="card-sub">После вычета комиссии 5%</div></div>
        <div class="card"><div class="card-label">Фильтр неликвида</div><div class="card-val" style="color:var(--warn)">{illiquid_count}</div><div class="card-sub">Отсеяны редкие/дорогие лоты</div></div>
        <div class="card"><div class="card-label">Топ ликвидный профит</div><div class="card-val pos">{best_liquid_html}</div><div class="card-sub">{best_liquid_sub}</div></div>
      </section>

      <details id="signalsSection" open>
        <summary class="section-head" style="cursor:pointer; list-style:none;">
          <h2 class="section-title">Торговые сигналы: Алхимия и Портняжное дело ▾</h2>
          <span class="meta">Свернуть / развернуть обзор</span>
        </summary>
        <div class="dt-bento">
          <div class="card">
            <div class="card-label" style="margin-bottom:8px;">Алхимия — Обзор возможностей</div>
            {_render_prof_health(alch_all, "#00B4D8")}
          </div>
          <div class="card">
            <div class="card-label" style="margin-bottom:8px;">Портняжное дело — Обзор возможностей</div>
            {_render_prof_health(tailor_all, "#8B5CF6")}
          </div>
          <div class="card">
            <div class="card-label" style="margin-bottom:10px;">Алхимия — Топ профит</div>
            {_render_profit_svg(alch_top, "linear-gradient(90deg, #0284C7, #00B4D8)")}
          </div>
          <div class="card">
            <div class="card-label" style="margin-bottom:10px;">Портняжное дело — Топ профит</div>
            {_render_profit_svg(tailor_top, "linear-gradient(90deg, #7C3AED, #8B5CF6)")}
          </div>
        </div>
        <div class="panel-2">
          <div class="card">
            <div class="card-label" style="margin-bottom:8px;">Алхимия — Приоритетные сигналы</div>
            {_render_signal_cards(alch_top[:3])}
          </div>
          <div class="card">
            <div class="card-label" style="margin-bottom:8px;">Портняжное дело — Приоритетные сигналы</div>
            {_render_signal_cards(tailor_top[:3])}
          </div>
        </div>
      </details>

      <div class="workspace-split" id="workspaceSplit">
      <section id="explorerSection">
        <div class="section-head">
          <h2 class="section-title">Обозреватель рынка и крафта</h2>
          <span id="countInfo" class="meta"></span>
        </div>
        <div class="prof-tabs-wrap">
          <button class="tabs-arrow hidden" id="tabsPrevBtn" title="Листать влево">‹</button>
          <div class="prof-tabs" id="profTabs">{prof_tabs_html}</div>
          <button class="tabs-arrow" id="tabsNextBtn" title="Листать вправо">›</button>
        </div>
        <div class="controls" style="margin-bottom:12px;">
          <button class="btn" id="onlyFavsBtn">★ Избранное (<span id="favCount">0</span>)</button>
          <button class="btn" id="onlyCraftableBtn">Только крафтовые</button>
          <button class="btn" id="onlySignalsBtn">Только сигналы</button>
          <button class="btn" id="onlyProfitBtn">Только выгодные</button>
          <button class="btn" id="toggleReagentsBtn">Показать реагенты</button>
          <button class="btn" id="exportAddonBtn" title="Скопировать лимиты цен для аддона ForeverSniper">Экспорт в аддон</button>
        </div>
        <div class="table-wrap hide-reagents" id="itemsTableWrap">
        <table>
          <thead>
            <tr>
              <th>★</th>
              <th class="sortable" data-sort="name_ru">Предмет</th>
              <th class="sortable" data-sort="profession">Крафт</th>
              <th class="sortable num" data-sort="score">Скор</th>
              <th class="sortable" data-sort="signal">Сигнал</th>
              <th class="sortable" data-sort="liquidity">Ликвид.</th>
              <th class="sortable num" data-sort="current_min">Мин. АХ</th>
              <th class="sortable num" data-sort="p25">P25</th>
              <th class="sortable num" data-sort="craft_cost">Крафт</th>
              <th class="sortable num" data-sort="craft_profit">Профит (-5%)</th>
              <th class="sortable num" data-sort="roi">ROI %</th>
              <th class="sortable col-reagents" data-sort="reagents">Реагенты</th>
              <th class="sortable num" data-sort="avail">Ост.</th>
            </tr>
          </thead>
          <tbody id="itemsBody"></tbody>
        </table>
        </div>
        <div style="margin-top:10px;">
          <button class="btn" id="loadMoreBtn" style="display:none;">Показать ещё +200</button>
        </div>
      </section>

      <section id="inspectorSection">
        <div class="section-head"><h2 class="section-title">Динамика цен и инспектор</h2><span class="meta">Кликните по строке слева</span></div>
        <div class="inspector-grid">
          <div class="card" style="position:relative;">
            <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px; margin-bottom:10px;">
              <div id="chartTitle" style="font-weight:600; font-size:13.5px;">Выберите предмет</div>
              <div id="chartLegend" style="display:flex; gap:10px; flex-wrap:wrap; font-size:11.5px; color:var(--muted);"></div>
            </div>
            <svg id="dynSvg" viewBox="0 0 520 265" style="width:100%; height:265px; display:block; overflow:visible;"></svg>
            <div id="chartTooltip" style="position:absolute; display:none; pointer-events:none; background:rgba(13,17,28,0.96); border:1px solid var(--border-strong); border-radius:8px; padding:8px 11px; font-size:11.5px; box-shadow:0 10px 24px rgba(0,0,0,0.5); z-index:20; min-width:170px;"></div>
          </div>
          <div class="card" id="inspectorDetail">
            <div class="card-label">Карточка предмета</div>
            <div id="inspName" style="font-size:16px; font-weight:700; margin-top:6px;">—</div>
            <div id="inspReason" style="font-size:12px; color:var(--accent); margin-top:4px;">—</div>
            <div id="inspReagents" class="meta" style="margin-top:6px; line-height:1.45;">Реагенты: —</div>
            <div class="insp-metrics">
              <div class="insp-kv"><div class="insp-k">Мин. АХ</div><div class="insp-v" id="inspMin">—</div></div>
              <div class="insp-kv"><div class="insp-k">Крафт</div><div class="insp-v" id="inspCost">—</div></div>
              <div class="insp-kv"><div class="insp-k">Профит (-5%)</div><div class="insp-v pos" id="inspProfit">—</div></div>
              <div class="insp-kv"><div class="insp-k">Ликвидность</div><div class="insp-v" id="inspLiq">—</div></div>
            </div>
          </div>
        </div>
      </section>
      </div>

      <section id="transmutesSection">
        <div class="section-head"><h2 class="section-title">Трансмутации Алхимии (КД и окупаемость рецептов)</h2><span class="meta">Комиссия АХ 5%</span></div>
        <div class="table-wrap">
        <table>
          <thead>
            <tr><th>Трансмутация</th><th>КД</th><th>Вход</th><th>Выход</th><th>Чистый профит</th><th>Ост.</th><th>Статус</th></tr>
          </thead>
          <tbody>{"".join(transmute_rows_html)}</tbody>
        </table>
        </div>
      </section>

      <footer style="margin-top:8px; padding-top:14px; border-top:1px solid var(--border); color:var(--muted); font-size:11.5px; line-height:1.5;">
        Неофициальный некоммерческий фан-проект на базе официального Blizzard Game Data API. World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of Blizzard Entertainment, Inc. in the U.S. and/or other countries.
      </footer>
    </main>
  </div>
</div>

<div id="itemTooltip"></div>
<div id="toast"></div>
<script>
const ITEMS = {items_json};
const HISTORY = {history_json};
let currentView = "overview";
let currentQuery = "";
let onlyFavs = false;
let onlyCraftable = false;
let onlySignals = false;
let onlyProfit = false;
let showReagents = false;
let sortKey = "score";
let sortDir = -1;
let renderLimit = 200;
const FAV_KEY = "wow_ah_favorites_v1";
const FAVORITES = new Set((() => {{
  try {{ return JSON.parse(localStorage.getItem(FAV_KEY) || "[]").map(Number); }} catch (_e) {{ return []; }}
}})());
function saveFavorites() {{
  try {{ localStorage.setItem(FAV_KEY, JSON.stringify([...FAVORITES])); }} catch (_e) {{}}
  const fc = document.getElementById("favCount");
  if (fc) fc.textContent = String(FAVORITES.size);
}}

function compareValues(a, b) {{
  const va = a[sortKey];
  const vb = b[sortKey];
  const aNull = va === null || va === undefined;
  const bNull = vb === null || vb === undefined;
  if (aNull && bNull) return 0;
  if (aNull) return 1;
  if (bNull) return -1;
  if (typeof va === "string") return va.localeCompare(vb, "ru") * sortDir;
  return (va - vb) * sortDir;
}}

function updateSortHeaders() {{
  document.querySelectorAll("th.sortable").forEach(th => {{
    const base = th.dataset.label || th.textContent.replace(/ [▲▼]$/, "");
    th.dataset.label = base;
    if (th.dataset.sort === sortKey) {{
      th.classList.add("active-sort");
      th.textContent = base + (sortDir === 1 ? " ▲" : " ▼");
    }} else {{
      th.classList.remove("active-sort");
      th.textContent = base;
    }}
  }});
}}

function fmtCopper(c) {{
  if (c === null || c === undefined) return "—";
  const sign = c < 0 ? "-" : "";
  const a = Math.abs(Math.round(c));
  const g = Math.floor(a / 10000);
  const s = Math.floor((a % 10000) / 100);
  const cp = a % 100;
  return sign + (g ? g + "g " : "") + ((g || s) ? s + "s " : "") + cp + "c";
}}

function fmtCoinsHtml(copper) {{
  if (copper === null || copper === undefined) return "—";
  const sign = copper < 0 ? "-" : "";
  const a = Math.abs(Math.round(copper));
  const g = Math.floor(a / 10000);
  const s = Math.floor((a % 10000) / 100);
  const c = a % 100;
  const parts = [];
  if (g > 0) parts.push(`${{g}}<span class="wt-coin wt-coin-g"></span>`);
  if (s > 0 || g > 0) parts.push(`${{s}}<span class="wt-coin wt-coin-s"></span>`);
  parts.push(`${{c}}<span class="wt-coin wt-coin-c"></span>`);
  return `<span class="coin-price">${{sign}}${{parts.join("")}}</span>`;
}}

function smoothPath(points) {{
  if (points.length === 1) return `M ${{points[0][0]}} ${{points[0][1]}}`;
  let d = `M ${{points[0][0]}} ${{points[0][1]}}`;
  for (let i = 0; i < points.length - 1; i++) {{
    const p0 = points[i], p1 = points[i + 1];
    const cx = (p0[0] + p1[0]) / 2;
    d += ` C ${{cx}} ${{p0[1]}}, ${{cx}} ${{p1[1]}}, ${{p1[0]}} ${{p1[1]}}`;
  }}
  return d;
}}

function drawDynamicsChart(item) {{
  const pts = HISTORY[String(item.item_id)] || [];
  document.getElementById("chartTitle").textContent = `${{item.name_ru}} (#${{item.item_id}}) · Снимков: ${{pts.length}}`;
  const qCls = item.quality ? `q-${{item.quality}}` : "";
  const iconHtml = item.icon ? `<img src="${{item.icon}}" style="width:24px;height:24px;border-radius:4px;border:1px solid #475569;vertical-align:middle;" />` : "";
  document.getElementById("inspName").innerHTML = `<span style="display:inline-flex;align-items:center;gap:8px;">${{iconHtml}}<span class="${{qCls}}">${{item.name_ru}}</span></span>`;
  document.getElementById("inspReason").textContent = `Оценка: ${{item.score}}/100 · ${{item.reason}}`;
  document.getElementById("inspReagents").textContent = `Реагенты: ${{item.reagents}}`;
  document.getElementById("inspMin").innerHTML = fmtCoinsHtml(item.current_min);
  document.getElementById("inspCost").innerHTML = fmtCoinsHtml(item.craft_cost);
  const pEl = document.getElementById("inspProfit");
  pEl.innerHTML = `${{fmtCoinsHtml(item.craft_profit)}} (${{item.roi_fmt}})`;
  pEl.className = "insp-v " + (item.craft_profit > 0 ? "pos" : item.craft_profit < 0 ? "neg" : "");
  document.getElementById("inspLiq").textContent = `${{item.liquidity}} (${{item.avail}} шт / ${{item.samples}} лот.)`;

  window._activeInspectorItem = item;
  const legend = document.getElementById("chartLegend");
  const last = pts[pts.length - 1];
  const liveParts = [];
  if (item._live) {{
    if (item._live.p1 > 0) liveParts.push(`<span style="color:#34D399;">● LIVE: <b class="mono">${{fmtCoinsHtml(item._live.p1)}}</b></span>`);
    if (item._live.vDrain > 0) liveParts.push(`<span style="color:#34D399;">Выкуп/ч: <b class="mono">${{item._live.vDrain}}</b></span>`);
    if (item._live.dips > 0) liveParts.push(`<span style="color:#FBBF24;">Просадки: <b class="mono">${{item._live.dips}}</b></span>`);
    if (item._live.winRate != null) liveParts.push(`<span style="color:#38BDF8;">WR: <b class="mono">${{item._live.winRate}}%</b></span>`);
  }}
  if (item._sale && item._sale.avgSellNet > 0) {{
    liveParts.push(`<span style="color:#A78BFA;">Почта (чист.): <b class="mono">${{fmtCoinsHtml(item._sale.avgSellNet)}}</b> (×${{item._sale.qty}})</span>`);
  }}
  const liveHtml = liveParts.length
    ? `<span style="margin-left:8px;padding-left:8px;border-left:1px solid rgba(52,211,153,.35);display:inline-flex;gap:10px;flex-wrap:wrap;">${{liveParts.join("")}}</span>`
    : "";
  legend.innerHTML = (last ? `
    <span><span style="color:#00B4D8;">●</span> Мин: <b class="mono" style="color:var(--text);">${{fmtCoinsHtml(last[1])}}</b></span>
    <span><span style="color:#2AB86F;">●</span> P25: <b class="mono" style="color:var(--text);">${{fmtCoinsHtml(last[2])}}</b></span>
    <span><span style="color:#8B5CF6;">●</span> Мед: <b class="mono" style="color:var(--text);">${{fmtCoinsHtml(last[3])}}</b></span>
    <span><span style="color:#38BDF8;">▮</span> Ост: <b class="mono" style="color:var(--text);">${{last[4]}}</b></span>
  ` : "") + liveHtml;

  const svg = document.getElementById("dynSvg");
  const tooltip = document.getElementById("chartTooltip");
  tooltip.style.display = "none";

  if (!pts.length) {{
    svg.innerHTML = `<text x="20" y="120" fill="#94A3B8" font-size="13">Нет истории снимков для этого предмета</text>`;
    return;
  }}

  const prices = pts.flatMap(p => [p[1], p[2], p[3]]);
  const rawMin = Math.min(...prices), rawMax = Math.max(...prices);
  const padP = Math.max(1, Math.round((rawMax - rawMin) * 0.12));
  const minP = Math.max(0, rawMin - padP), maxP = rawMax + padP;
  const spanP = Math.max(1, maxP - minP);
  const maxA = Math.max(1, ...pts.map(p => p[4]));

  const fmtAxisCopper = c => {{
    if (c >= 100000 && spanP >= 50000) return `${{Math.round(c / 10000)}}g`;
    if (c >= 10000) {{
      const g = Math.floor(c / 10000);
      const s = Math.floor((c % 10000) / 100);
      return s > 0 ? `${{g}}g ${{s}}s` : `${{g}}g`;
    }}
    return fmtCopper(c);
  }};

  const W = 438, H = 152, OX = 66, OY = 16;
  const xAt = i => pts.length === 1 ? OX + W / 2 : OX + (i * W) / (pts.length - 1);
  const yAt = v => OY + H - ((v - minP) / spanP) * H;

  const gridLines = [0, 0.33, 0.66, 1].map(t => {{
    const val = Math.round(minP + t * spanP);
    const y = yAt(val);
    return `<line x1="${{OX}}" y1="${{y}}" x2="${{OX + W}}" y2="${{y}}" stroke="#1F283D" stroke-dasharray="3,4" />` +
           `<text x="${{OX - 8}}" y="${{y + 4}}" fill="#CBD5E1" font-size="11.5" font-family="Fira Code, monospace" text-anchor="end">${{fmtAxisCopper(val)}}</text>`;
  }}).join("");

  // Supply sub-chart (bottom band: y=184..232)
  const sepLine = `<line x1="${{OX}}" y1="180" x2="${{OX + W}}" y2="180" stroke="#1F283D" />`;
  const barW = Math.max(4, Math.min(20, Math.floor((W / Math.max(1, pts.length)) * 0.56)));
  const availBars = pts.map((p, i) => {{
    const bh = Math.max(4, Math.round((p[4] / maxA) * 34));
    const x = xAt(i);
    const lbl = barW >= 13
      ? `<text x="${{x}}" y="${{221 - bh}}" fill="#64748B" font-size="9.5" font-family="Fira Code, monospace" text-anchor="middle">${{p[4]}}</text>`
      : "";
    return `<rect x="${{x - barW / 2}}" y="${{226 - bh}}" width="${{barW}}" height="${{bh}}" rx="2.5" fill="rgba(0,180,216,0.22)" stroke="rgba(0,180,216,0.45)" stroke-width="1" />` + lbl;
  }}).join("");

  const minPts = pts.map((p, i) => [xAt(i), yAt(p[1])]);
  const p25Pts = pts.map((p, i) => [xAt(i), yAt(p[2])]);
  const medPts = pts.map((p, i) => [xAt(i), yAt(p[3])]);
  const linePath = arr => pts.length > 12
    ? "M " + arr.map(pt => `${{pt[0].toFixed(1)}},${{pt[1].toFixed(1)}}`).join(" L ")
    : smoothPath(arr);

  // Shaded spread band between P25 and Median
  const spreadPoly = [...medPts, ...[...p25Pts].reverse()].map(pt => `${{pt[0]}},${{pt[1]}}`).join(" ");
  const spreadBand = `<polygon points="${{spreadPoly}}" fill="rgba(139,92,246,0.08)" />`;

  const areaPath = linePath(minPts) + ` L ${{minPts[minPts.length - 1][0]}} ${{OY + H}} L ${{minPts[0][0]}} ${{OY + H}} Z`;
  const defs = `<defs>
    <linearGradient id="minGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#00B4D8" stop-opacity="0.32"/>
      <stop offset="100%" stop-color="#00B4D8" stop-opacity="0.0"/>
    </linearGradient>
    <filter id="glow"><feGaussianBlur stdDeviation="2.5" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  </defs>`;

  const minPath = `<path d="${{linePath(minPts)}}" fill="none" stroke="#00B4D8" stroke-width="2.4" stroke-linejoin="round" stroke-linecap="round" filter="url(#glow)" />`;
  const p25Path = `<path d="${{linePath(p25Pts)}}" fill="none" stroke="#2AB86F" stroke-width="1.8" stroke-dasharray="5,3" stroke-linejoin="round" />`;
  const medPath = `<path d="${{linePath(medPts)}}" fill="none" stroke="#8B5CF6" stroke-width="1.8" stroke-linejoin="round" />`;

  const rSm = pts.length > 24 ? 2.2 : 3.2;
  const rLg = pts.length > 24 ? 3.0 : 4.2;
  const dots = pts.map((p, i) => `
    <circle cx="${{xAt(i)}}" cy="${{yAt(p[3])}}" r="${{rSm}}" fill="#8B5CF6" />
    <circle cx="${{xAt(i)}}" cy="${{yAt(p[2])}}" r="${{rSm}}" fill="#2AB86F" />
    <circle cx="${{xAt(i)}}" cy="${{yAt(p[1])}}" r="${{rLg}}" fill="#00B4D8" stroke="#080B12" stroke-width="1.4" />
  `).join("");

  // Evenly spaced non-overlapping X-axis ticks (max 5 labels for crisp 520px chart)
  const tickStep = Math.max(1, Math.ceil((pts.length - 1) / 4));
  const tickIndices = [];
  for (let i = 0; i < pts.length; i += tickStep) tickIndices.push(i);
  if (tickIndices[tickIndices.length - 1] !== pts.length - 1) {{
    if (pts.length - 1 - tickIndices[tickIndices.length - 1] < tickStep * 0.75 && tickIndices.length > 1) {{
      tickIndices[tickIndices.length - 1] = pts.length - 1;
    }} else {{
      tickIndices.push(pts.length - 1);
    }}
  }}
  let prevDay = "";
  const labels = tickIndices.map((i, k) => {{
    const ts = pts[i][0]; // YYYY-MM-DD HH:MM
    const day = ts.slice(8, 10) + "." + ts.slice(5, 7);
    const hm = ts.slice(11, 16);
    const txt = (k === 0 || day !== prevDay) ? `${{day}} ${{hm}}` : hm;
    prevDay = day;
    const x = xAt(i);
    const anchor = k === 0 && pts.length > 2 ? "start" : (k === tickIndices.length - 1 && pts.length > 2 ? "end" : "middle");
    return `<line x1="${{x}}" y1="227" x2="${{x}}" y2="233" stroke="#475569" />` +
           `<text x="${{x}}" y="249" fill="#CBD5E1" font-size="11.5" font-family="Fira Code, monospace" text-anchor="${{anchor}}">${{txt}}</text>`;
  }}).join("");
  const hoverLine = `<line id="crosshair" x1="0" y1="${{OY}}" x2="0" y2="230" stroke="#00B4D8" stroke-width="1" stroke-dasharray="3,3" style="display:none;" />`;
  const hitZones = pts.map((p, i) => {{
    const x = xAt(i);
    const hw = pts.length === 1 ? W : W / Math.max(1, pts.length - 1);
    return `<rect class="hit-zone" data-idx="${{i}}" x="${{x - hw / 2}}" y="0" width="${{hw}}" height="255" fill="transparent" style="cursor:crosshair;" />`;
  }}).join("");

  svg.innerHTML = defs + gridLines + sepLine + availBars + spreadBand + `<path d="${{areaPath}}" fill="url(#minGrad)" />` + medPath + p25Path + minPath + dots + labels + hoverLine + hitZones;

  svg.querySelectorAll(".hit-zone").forEach(zone => {{
    zone.addEventListener("mouseenter", () => {{
      const idx = Number(zone.dataset.idx);
      const p = pts[idx];
      const cx = xAt(idx);
      const ch = svg.querySelector("#crosshair");
      if (ch) {{ ch.setAttribute("x1", cx); ch.setAttribute("x2", cx); ch.style.display = "block"; }}
      tooltip.innerHTML = `
        <div class="mono" style="color:var(--accent); font-weight:600; margin-bottom:4px;">${{p[0]}} UTC</div>
        <div>Мин. АХ: <b class="mono">${{fmtCoinsHtml(p[1])}}</b></div>
        <div>P25 (1/4): <b class="mono" style="color:#2AB86F;">${{fmtCoinsHtml(p[2])}}</b></div>
        <div>Медиана: <b class="mono" style="color:#8B5CF6;">${{fmtCoinsHtml(p[3])}}</b></div>
        <div style="margin-top:3px; color:var(--muted);">Остаток: <b class="mono" style="color:var(--text);">${{p[4]}} шт.</b></div>
      `;
      tooltip.style.display = "block";
      const pctX = (cx / 520) * 100;
      tooltip.style.left = pctX > 65 ? "auto" : `calc(${{pctX}}% + 12px)`;
      tooltip.style.right = pctX > 65 ? `calc(${{100 - pctX}}% + 12px)` : "auto";
      tooltip.style.top = "44px";
    }});
  }});
  svg.addEventListener("mouseleave", () => {{
    const ch = svg.querySelector("#crosshair");
    if (ch) ch.style.display = "none";
    tooltip.style.display = "none";
  }});
}}

function signalBadge(sig) {{
  if (!sig || sig === "—") return "—";
  if (sig === "КРАФТИТЬ" || sig === "ВЫГОДНО") return `<span class="badge sig-craft">${{sig}}</span>`;
  if (sig === "СКУПКА") return `<span class="badge sig-snipe">${{sig}}</span>`;
  if (sig === "ОСТОРОЖНО" || sig === "НЕЛИКВИД") return `<span class="badge sig-low">${{sig}}</span>`;
  return `<span class="badge sig-bad">${{sig}}</span>`;
}}

function applyViewVisibility() {{
  const isTrans = currentView === "transmutes";
  document.getElementById("signalsSection").classList.toggle("hidden", currentView !== "overview" && currentView !== "signals");
  document.getElementById("workspaceSplit").classList.toggle("hidden", isTrans);
  document.getElementById("transmutesSection").classList.toggle("hidden", !isTrans);
}}

function renderTable() {{
  applyViewVisibility();
  saveFavorites();
  const tbody = document.getElementById("itemsBody");
  const filtered = ITEMS.filter(it =>
    (currentView === "ALL" || currentView === "signals"
      ? (currentView !== "signals" || ["КРАФТИТЬ", "СКУПКА", "ВЫГОДНО"].includes(it.signal))
      : (currentView === "overview" ? it.group !== "Весь рынок" : it.group === currentView)) &&
    (!onlyFavs || FAVORITES.has(it.item_id)) &&
    (!onlyCraftable || it.is_craftable) &&
    (!onlySignals || ["КРАФТИТЬ", "СКУПКА", "ВЫГОДНО"].includes(it.signal)) &&
    (!onlyProfit || (it.craft_profit !== null && it.craft_profit > 0)) &&
    (!currentQuery || it.name_ru.toLowerCase().includes(currentQuery) || String(it.item_id).includes(currentQuery))
  ).sort((a, b) => {{
    const primary = compareValues(a, b);
    if (primary !== 0) return primary;
    return ((b.craft_profit ?? -1e12) - (a.craft_profit ?? -1e12));
  }});
  updateSortHeaders();
  const visible = filtered.slice(0, renderLimit);
  document.getElementById("countInfo").textContent = `Показано ${{visible.length}} из ${{filtered.length}}`;
  const moreBtn = document.getElementById("loadMoreBtn");
  moreBtn.style.display = filtered.length > renderLimit ? "inline-block" : "none";
  tbody.innerHTML = visible.map(it => {{
    const iconTag = it.icon
      ? `<img class="item-icon" src="${{it.icon}}" loading="lazy" alt="" />`
      : `<span class="item-icon" style="display:inline-grid;place-items:center;font-size:10px;color:var(--muted);">•</span>`;
    const qCls = it.quality ? `q-${{it.quality}}` : "";
    const isFav = FAVORITES.has(it.item_id);
    return `
    <tr data-id="${{it.item_id}}" style="cursor:pointer;">
      <td><button class="fav-btn ${{isFav ? 'is-fav' : ''}}" data-fav="${{it.item_id}}" title="В избранное">★</button></td>
      <td><span class="item-cell" data-tip-id="${{it.item_id}}">${{iconTag}}<span class="item-name-txt ${{qCls}}">${{it.name_ru}}</span><button class="copy-btn" data-copy="${{it.name_ru.replace(/"/g, '&quot;')}}" title="Копировать название"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg></button></span></td>
      <td>${{it.is_craftable ? '<span class="pos">' + it.profession + '</span>' : '—'}}</td>
      <td class="mono num"><b style="color:${{it.score >= 65 ? 'var(--pos)' : it.score >= 45 ? 'var(--accent)' : 'var(--muted)'}}">${{it.score}}</b></td>
      <td>${{signalBadge(it.signal)}}</td>
      <td style="color:var(--muted);">${{it.liquidity}}</td>
      <td class="mono num"><b>${{fmtCoinsHtml(it.current_min)}}</b>${{it._live && it._live.p1 > 0 ? `<span style="display:inline-block;margin-left:5px;padding:1px 5px;border-radius:4px;font-size:10px;font-weight:700;background:rgba(16,185,129,.16);color:#34D399;border:1px solid rgba(52,211,153,.35);vertical-align:middle;" title="Живая цена из аддона${{it._live.vDrain ? ' · Выкуп/ч: ' + it._live.vDrain : ''}}${{it._live.dips ? ' · Просадки: ' + it._live.dips : ''}}">LIVE</span>` : ''}}</td>
      <td class="mono num" style="color:var(--muted);">${{fmtCoinsHtml(it.p25)}}</td>
      <td class="mono num" style="color:var(--muted);">${{fmtCoinsHtml(it.craft_cost)}}</td>
      <td class="num ${{it.craft_profit > 0 ? 'pos' : it.craft_profit < 0 ? 'neg' : 'mono'}}">${{fmtCoinsHtml(it.craft_profit)}}</td>
      <td class="num ${{it.roi > 0 ? 'pos' : it.roi < 0 ? 'neg' : 'mono'}}">${{it.roi_fmt}}</td>
      <td class="col-reagents" style="color:var(--muted); font-size:12px;">${{it.reagents}}</td>
      <td class="mono num">${{it.avail}}</td>
    </tr>
  `;}}).join("");
  tbody.querySelectorAll(".fav-btn").forEach(btn => {{
    btn.addEventListener("click", e => {{
      e.stopPropagation();
      const id = Number(btn.dataset.fav);
      if (FAVORITES.has(id)) FAVORITES.delete(id);
      else FAVORITES.add(id);
      renderTable();
    }});
  }});
  const tipEl = document.getElementById("itemTooltip");
  tbody.querySelectorAll(".item-cell[data-tip-id]").forEach(el => {{
    el.addEventListener("mouseenter", e => {{
      const it = ITEMS.find(x => String(x.item_id) === el.dataset.tipId);
      if (!it) return;
      const qCls = it.quality ? `q-${{it.quality}}` : "q-COMMON";
      const img = it.icon ? `<img src="${{it.icon}}" style="width:28px;height:28px;border-radius:4px;border:1px solid #475569;flex-shrink:0;" />` : "";
      let bodyHtml = "";
      if (it.desc && it.desc.startsWith("{{")) {{
        try {{
          const d = JSON.parse(it.desc);
          if (d.b) bodyHtml += `<div class="wt-line-w">${{d.b}}</div>`;
          if (d.sl || d.sc) bodyHtml += `<div class="wt-split"><span>${{d.sl || ""}}</span><span>${{d.sc || ""}}</span></div>`;
          if (Array.isArray(d.l)) {{
            d.l.forEach(ln => {{
              const cls = ln.c === "g" ? "wt-line-g" : ln.c === "y" ? "wt-line-y" : "wt-line-w";
              bodyHtml += `<div class="${{cls}}">${{ln.t}}</div>`;
            }});
          }}
          if (d.sp) bodyHtml += `<div class="wt-line-w">Цена продажи: ${{fmtCoinsHtml(d.sp)}}</div>`;
        }} catch (_err) {{
          bodyHtml = `<div class="wt-line-w">${{it.desc}}</div>`;
        }}
      }} else if (it.desc) {{
        bodyHtml = `<div class="wt-line-w">${{it.desc}}</div>`;
      }}
      tipEl.innerHTML = `
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:4px;">
          ${{img}}
          <div style="font-size:13.5px;font-weight:700;" class="${{qCls}}">${{it.name_ru}}</div>
        </div>
        ${{bodyHtml}}
        <div style="border-top:1px solid rgba(148,163,184,0.22);margin-top:7px;padding-top:6px;">
          <div style="color:var(--accent);font-size:11.5px;">Скор: <b>${{it.score}}/100</b> · ${{it.reason}}</div>
          ${{it.reagents !== "—" ? `<div style="color:var(--muted);font-size:11px;margin-top:2px;">Реагенты: ${{it.reagents}}</div>` : ""}}
        </div>
      `;
      tipEl.style.display = "block";
    }});
    el.addEventListener("mousemove", e => {{
      const tw = tipEl.offsetWidth || 320;
      const th = tipEl.offsetHeight || 180;
      tipEl.style.left = Math.min(window.innerWidth - tw - 12, e.clientX + 16) + "px";
      tipEl.style.top = Math.min(window.innerHeight - th - 12, e.clientY + 14) + "px";
    }});
    el.addEventListener("mouseleave", () => {{ tipEl.style.display = "none"; }});
  }});
  tbody.querySelectorAll(".copy-btn").forEach(btn => {{
    btn.addEventListener("click", e => {{
      e.stopPropagation();
      navigator.clipboard?.writeText(btn.dataset.copy);
      const t = document.getElementById("toast");
      t.textContent = `Скопировано: ${{btn.dataset.copy}}`;
      t.classList.add("show");
      setTimeout(() => t.classList.remove("show"), 1600);
    }});
  }});
  tbody.querySelectorAll("tr[data-id]").forEach(tr => {{
    tr.addEventListener("click", () => {{
      tbody.querySelectorAll("tr.selected-row").forEach(x => x.classList.remove("selected-row"));
      tr.classList.add("selected-row");
      const found = ITEMS.find(x => String(x.item_id) === tr.dataset.id);
      if (found) drawDynamicsChart(found);
    }});
  }});
  if (visible.length) {{
    const firstRow = tbody.querySelector("tr[data-id]");
    if (firstRow) firstRow.classList.add("selected-row");
    drawDynamicsChart(visible[0]);
  }}
}}

document.querySelectorAll("th.sortable").forEach(th => {{
  th.addEventListener("click", () => {{
    const key = th.dataset.sort;
    if (sortKey === key) sortDir = -sortDir;
    else {{
      sortKey = key;
      sortDir = (key === "name_ru" || key === "group" || key === "reagents") ? 1 : -1;
    }}
    document.querySelectorAll(".quick-pill[data-id], .dt-bar-row[data-id]").forEach(el => {{
  el.addEventListener("click", () => {{
    const found = ITEMS.find(x => String(x.item_id) === el.dataset.id);
    if (found) {{
      drawDynamicsChart(found);
      document.getElementById("inspectorSection").scrollIntoView({{ behavior: "smooth", block: "nearest" }});
    }}
  }});
}});

renderTable();
  }});
}});

function setActiveView(view, titleText) {{
  currentView = view;
  if (currentView === "signals") {{
    sortKey = "score";
    sortDir = -1;
  }}
  document.querySelectorAll(".nav-btn[data-view]").forEach(x => x.classList.toggle("active", x.dataset.view === view));
  document.querySelectorAll(".prof-tab[data-view]").forEach(x => x.classList.toggle("active", x.dataset.view === view));
  if (titleText) document.getElementById("viewTitle").textContent = titleText;
  renderLimit = 200;
  renderTable();
}}

document.querySelectorAll(".nav-btn[data-view]").forEach(btn => {{
  btn.addEventListener("click", () => setActiveView(btn.dataset.view, btn.querySelector(".nav-left").textContent.trim()));
}});
document.querySelectorAll(".prof-tab[data-view]").forEach(tab => {{
  tab.addEventListener("click", () => setActiveView(tab.dataset.view, tab.textContent.replace(/\d+$/, "").trim()));
}});
(() => {{
  const tabsEl = document.getElementById("profTabs");
  const prevBtn = document.getElementById("tabsPrevBtn");
  const nextBtn = document.getElementById("tabsNextBtn");
  if (!tabsEl || !prevBtn || !nextBtn) return;
  const syncArrows = () => {{
    prevBtn.classList.toggle("hidden", tabsEl.scrollLeft <= 4);
    nextBtn.classList.toggle("hidden", tabsEl.scrollLeft + tabsEl.clientWidth >= tabsEl.scrollWidth - 4);
  }};
  prevBtn.addEventListener("click", () => tabsEl.scrollBy({{ left: -240, behavior: "smooth" }}));
  nextBtn.addEventListener("click", () => tabsEl.scrollBy({{ left: 240, behavior: "smooth" }}));
  tabsEl.addEventListener("scroll", syncArrows, {{ passive: true }});
  tabsEl.addEventListener("wheel", e => {{
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {{
      e.preventDefault();
      tabsEl.scrollLeft += e.deltaY;
    }}
  }}, {{ passive: false }});
  window.addEventListener("resize", syncArrows);
  setTimeout(syncArrows, 50);
}})();
document.getElementById("onlyFavsBtn").addEventListener("click", e => {{
  onlyFavs = !onlyFavs;
  e.currentTarget.classList.toggle("active", onlyFavs);
  renderLimit = 200;
  renderTable();
}});
document.getElementById("toggleReagentsBtn").addEventListener("click", e => {{
  showReagents = !showReagents;
  e.currentTarget.classList.toggle("active", showReagents);
  e.currentTarget.textContent = showReagents ? "Скрыть реагенты" : "Показать реагенты";
  document.getElementById("itemsTableWrap").classList.toggle("hide-reagents", !showReagents);
}});
document.getElementById("exportAddonBtn").addEventListener("click", () => {{
  const source = FAVORITES.size > 0
    ? ITEMS.filter(it => FAVORITES.has(it.item_id) && it.current_min > 0)
    : ITEMS.filter(it => ["СКУПКА", "КРАФТИТЬ"].includes(it.signal) && it.current_min > 0).slice(0, 40);
  const pairs = source.map(it => {{
    const cap = it.signal === "СКУПКА" && it.p25 > 0 ? Math.floor(it.p25 * 0.78) : it.current_min;
    return `${{it.item_id}}=${{Math.max(1, cap)}}`;
  }});
  const payload = `# GoblinBroker:Forever\n` + pairs.join(";");
  navigator.clipboard?.writeText(payload);
  const t = document.getElementById("toast");
  t.textContent = `Скопировано ${{pairs.length}} позиций для Goblin Broker!`;
  t.classList.add("show");
  setTimeout(() => t.classList.remove("show"), 2200);
}});

document.getElementById("loadMoreBtn").addEventListener("click", () => {{ renderLimit += 200; document.querySelectorAll(".quick-pill[data-id], .dt-bar-row[data-id]").forEach(el => {{
  el.addEventListener("click", () => {{
    const found = ITEMS.find(x => String(x.item_id) === el.dataset.id);
    if (found) {{
      drawDynamicsChart(found);
      document.getElementById("inspectorSection").scrollIntoView({{ behavior: "smooth", block: "nearest" }});
    }}
  }});
}});

renderTable(); }});
document.getElementById("onlyCraftableBtn").addEventListener("click", e => {{ onlyCraftable = !onlyCraftable; e.target.classList.toggle("active", onlyCraftable); renderLimit = 200; document.querySelectorAll(".quick-pill[data-id], .dt-bar-row[data-id]").forEach(el => {{
  el.addEventListener("click", () => {{
    const found = ITEMS.find(x => String(x.item_id) === el.dataset.id);
    if (found) {{
      drawDynamicsChart(found);
      document.getElementById("inspectorSection").scrollIntoView({{ behavior: "smooth", block: "nearest" }});
    }}
  }});
}});

renderTable(); }});
document.getElementById("onlySignalsBtn").addEventListener("click", e => {{ onlySignals = !onlySignals; e.target.classList.toggle("active", onlySignals); renderLimit = 200; document.querySelectorAll(".quick-pill[data-id], .dt-bar-row[data-id]").forEach(el => {{
  el.addEventListener("click", () => {{
    const found = ITEMS.find(x => String(x.item_id) === el.dataset.id);
    if (found) {{
      drawDynamicsChart(found);
      document.getElementById("inspectorSection").scrollIntoView({{ behavior: "smooth", block: "nearest" }});
    }}
  }});
}});

renderTable(); }});
document.getElementById("onlyProfitBtn").addEventListener("click", e => {{ onlyProfit = !onlyProfit; e.target.classList.toggle("active", onlyProfit); renderLimit = 200; document.querySelectorAll(".quick-pill[data-id], .dt-bar-row[data-id]").forEach(el => {{
  el.addEventListener("click", () => {{
    const found = ITEMS.find(x => String(x.item_id) === el.dataset.id);
    if (found) {{
      drawDynamicsChart(found);
      document.getElementById("inspectorSection").scrollIntoView({{ behavior: "smooth", block: "nearest" }});
    }}
  }});
}});

renderTable(); }});
document.getElementById("searchBox").addEventListener("input", e => {{ currentQuery = e.target.value.trim().toLowerCase(); renderLimit = 200; document.querySelectorAll(".quick-pill[data-id], .dt-bar-row[data-id]").forEach(el => {{
  el.addEventListener("click", () => {{
    const found = ITEMS.find(x => String(x.item_id) === el.dataset.id);
    if (found) {{
      drawDynamicsChart(found);
      document.getElementById("inspectorSection").scrollIntoView({{ behavior: "smooth", block: "nearest" }});
    }}
  }});
}});

renderTable(); }});
document.addEventListener("keydown", e => {{
  if ((e.key === "/" || (e.ctrlKey && e.key.toLowerCase() === "k")) && document.activeElement !== document.getElementById("searchBox")) {{
    e.preventDefault();
    document.getElementById("searchBox").focus();
  }}
}});
document.querySelectorAll(".quick-pill[data-id], .dt-bar-row[data-id]").forEach(el => {{
  el.addEventListener("click", () => {{
    const found = ITEMS.find(x => String(x.item_id) === el.dataset.id);
    if (found) {{
      drawDynamicsChart(found);
      document.getElementById("inspectorSection").scrollIntoView({{ behavior: "smooth", block: "nearest" }});
    }}
  }});
}});

renderTable();

(function initLiveTelemetryOverlay() {{
  if (!location.protocol.startsWith("http")) return;
  let lastTs = 0;
  const pullLive = async () => {{
    try {{
      const res = await fetch("./live_telemetry.json?_cb=" + Date.now(), {{ cache: "no-store" }});
      if (!res.ok) return;
      const payload = await res.json();
      if (!payload || !payload.items) return;
      if (payload.updated_ts && payload.updated_ts === lastTs) return;
      lastTs = payload.updated_ts || Date.now();

      const liveItems = payload.items || {{}};
      const salesByName = payload.salesByName || {{}};
      let matched = 0;

      for (const it of ITEMS) {{
        const lv = liveItems[String(it.item_id)];
        if (lv) {{
          it._live = lv;
          if (lv.p1 > 0) {{
            if (it._api_min == null) it._api_min = it.current_min;
            it.current_min = lv.p1;
            if (it.is_craftable && it.craft_cost > 0) {{
              const profit = Math.floor(lv.p1 * 0.95) - it.craft_cost;
              it.craft_profit = profit;
              const roi = (profit / it.craft_cost) * 100;
              it.roi = Math.round(roi * 10) / 10;
              it.roi_fmt = (roi >= 0 ? "+" : "") + Math.round(roi) + "%";
            }}
            matched++;
          }}
        }}
        const sale = salesByName[it.name_ru];
        if (sale && sale.avgSellNet > 0) {{
          it._sale = sale;
        }}
      }}

      const badge = document.getElementById("addonLiveBadge");
      if (badge && payload.updated_ts) {{
        const ageMin = Math.max(0, Math.floor((Date.now() / 1000 - payload.updated_ts) / 60));
        const ageTxt = ageMin < 1 ? "только что" : ageMin < 60 ? `${{ageMin}}м назад` : `${{Math.floor(ageMin / 60)}}ч назад`;
        badge.innerHTML = `<span class="live-dot" style="background:#34D399;box-shadow:0 0 8px #34D399;"></span><span class="mono">ADDON LIVE · ${{matched}} поз. · ${{ageTxt}}</span>`;
        badge.style.display = "inline-flex";
      }}

      renderTable();
      if (window._activeInspectorItem) {{
        drawDynamicsChart(window._activeInspectorItem);
      }}
    }} catch (_e) {{}}
  }};
  pullLive();
  setInterval(pullLive, 60000);
}})();

if (location.protocol.startsWith("http")) {{
  const curMeta = document.querySelector('meta[name="app-build"]')?.content || "";
  const checkFresh = async () => {{
    try {{
      const res = await fetch(location.pathname + "?_cb=" + Date.now(), {{ cache: "no-store" }});
      if (!res.ok) return;
      const htmlTxt = await res.text();
      const m = htmlTxt.match(/<meta\s+name="app-build"\s+content="([^"]+)"/i);
      if (m && m[1] && curMeta && m[1] !== curMeta) {{
        const u = new URL(location.href);
        u.searchParams.set("v", m[1].replace(/[^a-zA-Z0-9._-]/g, ""));
        location.replace(u.toString());
      }}
    }} catch (_e) {{}}
  }};
  setTimeout(checkFresh, 2500);
  setInterval(checkFresh, 300000);
}}
</script>
</body>
</html>
"""


def generate_dashboard_file(
    conn: sqlite3.Connection,
    output_path: str | Path = Path("data/dashboard.html"),
    *,
    house_id: int | None = 113,
    hours_back: int = 24,
) -> Path:
    """Build current snapshot analytics and overwrite self-contained HTML dashboard."""
    data = build_dashboard_data(conn, house_id=house_id, hours_back=hours_back)
    html_text = render_dashboard_html(data)
    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html_text, encoding="utf-8")
    return out
