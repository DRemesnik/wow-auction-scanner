---
name: wow-forever-ah
description: Rules and verified workflows for the WoW: Forever EU Horde Auction House tracker, static-forever-eu API synchronization, and Windows PowerShell execution.
---

# WoW: Forever Auction Tracker Skill

## 1. Never Guess Item IDs, Localized Names, or Recipes
- **Always** verify item IDs, exact `ru_RU` / `en_US` names, and recipe reagents (`preview_item.recipe.reagents`) against Blizzard's `static-forever-eu` namespace before adding them to `src/tracker/db.py` or `src/tracker/dashboard.py`.
- Use `/data/wow/item/{item_id}?namespace=static-forever-eu&locale=ru_RU` for exact Russian names.
- Use `/data/wow/search/item?name.ru_RU=<query>&namespace=static-forever-eu` to discover WoW: Forever custom item IDs (e.g., Legionite, Reagent Bags, Fel Crystal).
- Use the recipe/pattern item's `preview_item.recipe.reagents` field from `static-forever-eu` to get exact reagent IDs and quantities — never rely on memory or older third-party translations.

## 2. Target Server & Auction House
- Region: `eu`
- Dynamic namespace: `dynamic-forever-eu`
- Static namespace: `static-forever-eu`
- EU PvP Horde Auction House: `ruleset_id = 1`, `house_id = 113` (verified against in-game AH).
- All monetary values in SQLite and analytics must remain strictly integer copper (`int`); convert to `g / s / c` only for display.

## 3. Execution & Editing Discipline
- **Never** run `pytest`, `init-db`, or `dashboard` in parallel with `edit_file` / `write_file` on files they depend on — always finish edits first, then run verification in the next turn.
- On this Windows machine, `.venv\Scripts\python.exe` is blocked by Application Control policy (`os error 4551`). Run Python using:
  `C:\Users\remes\AppData\Roaming\uv\python\cpython-3.11.17-windows-x86_64-none\python.exe` with `$env:PYTHONPATH="src"`.
- In Windows PowerShell 5.1, do not use `&&` or escaped quotes inside `python -c "..."`; use `@' ... '@ | & $PY -` for inline scripts and `; if ($LASTEXITCODE -eq 0) { ... }` for chaining.
