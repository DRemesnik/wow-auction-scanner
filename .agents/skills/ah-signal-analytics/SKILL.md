---
name: ah-signal-analytics
description: Quantitative decision logic, pros & cons analysis of auction house metrics, and multi-factor signal scoring for WoW: Forever trading.
---

# Auction House Signal Analytics & Decision Logic

## 1. Pros & Cons of Core Market Signals

### A. Price Anchor: `min` vs `p25` (Lower Quartile) vs `median`
| Metric | Pros | Cons | When to Use |
| --- | --- | --- | --- |
| **`min_unit_price`** | Reflects exact instant-buyout price and immediate undercut competition. | Easily distorted by a single 1-unit snipe/bait listing. | Calculating **reagent buy cost** and checking immediate **snipe** opportunities. |
| **`p25_unit_price`** (Lower Quartile) | Robust against 1-unit bait undercuts; represents the real competitive floor of the cheapest 25% of supply. | Slightly slower sell-through if there is a thick wall at `min`. | Estimating realistic **relist price** for `СКУПКА` (snipe/flip) and validating book stability. |
| **`median_unit_price`** | Shows where the bulk of supply sits. | Heavily skewed upward by overpriced dreamers on thin items. | Measuring **book tightness** (`median / p25`). Never price craft revenue at `median`. |

### B. Liquidity: `total_available` vs `sample_size` (Lot Count) vs Velocity
- **`total_available` (Total Units)**
  - *Pros:* Measures raw supply volume on the AH.
  - *Cons:* One seller posting 200 units in a single stack looks "high supply" even if only 1 person trades the item.
- **`sample_size` (Distinct Listings)**
  - *Pros:* Measures actual market participation / number of competing sellers.
  - *Cons:* 50 listings of 1 unit each can inflate `sample_size` for low-value items.
- **Combined Rule (Best Practice):** Require **both** `total_available >= 10` AND `sample_size >= 4` for `КРАФТИТЬ` / `ВЫГОДНО`. Flag `avail < 5` or `sample_size <= 2` (or `price >= 50g` with `avail < 12`) as **`НЕЛИКВИД`**.
- **Snapshot Velocity (`Δ avail` / `Δ price` across snapshots)**
  - *Pros:* Confirms items are actually selling (supply drops or turns over while price holds).
  - *Cons:* Requires ≥ 2 snapshots; restocking by crafters can temporarily mask sales.
- **Oversupply / Dumping & 1-Unit Competition Guard (Critical):**
  - High `total_available` + high `sample_size` on **non-stackable niche items** (e.g. 64 Enchanting bags all posted as 1-unit lots) is **supply saturation**, NOT demand.
  - If `min_unit_price` drops `>= 8%` across snapshots while `avail >= 20` (**price dumping**), OR `sample_size >= 30` with `avail == sample_size` (**30+ single-unit competitors**), downgrade from `КРАФТИТЬ` to **`ОСТОРОЖНО`** and cap score `< 60`.

### C. Margin: `ROI %` vs Absolute Copper Profit
- **`ROI %` (`profit / craft_cost`)**
  - *Pros:* Great for capital efficiency when gold is limited.
  - *Cons:* Traps you into micro-crafts (e.g., `5c` -> `12c` = `+140% ROI` for `6c` profit — not worth AH deposit or bag space).
- **Absolute Profit (`net_after_5pct - craft_cost`)**
  - *Pros:* Shows actual gold earned per click/craft.
  - *Cons:* Ignores capital tied up (`500g` craft for `10g` profit = `2% ROI`, high undercut risk).
- **Combined Rule:** Require minimum absolute profit (`>= 20s` / `2_000c` for `КРАФТИТЬ`, `>= 25s` for `СКУПКА` flips) AND combine `ROI %` + absolute profit into a **0–100 Signal Score**.

### D. Cooldown Opportunity Cost (`23h` / `47h` / `1h`)
- Recipes sharing a `cooldown_pool` (e.g., `arcanite_legionite_47h` for *Arcanite* vs *Legionite*) are mutually exclusive. Always rank by **net profit per cycle**, not ROI %.

## 2. Composite Signal Score (0–100)
1. **Liquidity & Depth (0–35 pts):** `sample_size` + `total_available`
2. **Profit & ROI (0–35 pts):** balanced blend of net copper profit and `ROI %` (micro-profits `< 20s` capped low)
3. **Order-Book Stability (0–15 pts):** `median / p25` tightness (`<= 1.4x` = +15, `<= 2.0x` = +8, `> 2.5x` = 0)
4. **Cross-Snapshot Demand Bonus (0–15 pts):** supply turnover or upward price pressure across recent snapshots
