# Goblin Broker: Forever (`v3.0`) — WoW: Forever EU Horde Suite

Экосистема для анализа и торговли на аукционе **World of Warcraft: Forever (EU Орда)** с нулевым риском бана Blizzard ToS:
1. **Web-дэшборд (Live):** [dremesnik.github.io/wow-auction-scanner](https://dremesnik.github.io/wow-auction-scanner/)
2. **Игровой аддон (`addon/ForeverSniper/`):** двухрежимный **Снайпер + Сканер рынка** в стиле Modern Obsidian (`Inter`, `NoSnap` 9-slice, двойные бинды, 3-этапная стат. модель).
3. **Desktop-компаньон (`desktop/GoblinBrokerDesktop.exe`):** нативное Windows-приложение (`46.5 КБ`, без установки, `0% CPU` в простое) для автоматической синхронизации живых цен на общий дэшборд.

## Быстрый старт для друзей (v3.0, 2 минуты)
1. **Аддон:** скопируйте папку `addon/ForeverSniper` в `World of Warcraft\_forever_\Interface\AddOns\ForeverSniper`.
2. **Desktop App:** скачайте и запустите **`GoblinBrokerDesktop.exe`** — установка не нужна, путь к WoW и облачный HTTPS-сервер определяются автоматически.
3. **Готово:** сканируйте рынок в игре — при выходе с персонажа, смене альта или `/reload` анонимные цены автоматически объединяются на общем Web-дэшборде.

---

## Бэкенд и аналитика (Python 3.11+ / SQLite)

## Возможности
- Хранение всех цен строго в целых числах (**медные монеты `int`**), форматирование `g / s / c` только при выводе.
- Коннектор **Blizzard Game Data API** (`dynamic-forever-eu`, OAuth2 `client_credentials`, кэш-заголовки `Last-Modified` / `If-Modified-Since`, поддержка обычных лотов `buyout` и товаров `unit_price`).
- Парсер локальных дампов аддонов **`SavedVariables`** (`PriceLog.lua`, `Auctionator.lua`, универсальные экспорты) с пометкой `partial` / `full`.
- Предзаполненный справочник под **Алхимию 275** (трансмутации `23h`, `47h`, `1h`, ключевые субстанции, кристаллы и слитки).
- Расчёт чистой прибыли с учётом комиссии АХ (по умолчанию 5%), окупаемости рецепта в циклах и днях, сравнения с ценой вендора и исторической дельты за 7/14 дней.

## Установка и запуск

```bash
# Через uv (рекомендуется)
uv sync --extra dev
uv run pytest
```

Или через стандартный `pip`:
```bash
python -m venv .venv
.venv\Scripts\activate
pip install -e ".[dev]"
pytest
```

## Переменные окружения

```powershell
$env:BLIZZARD_CLIENT_ID="your_client_id"
$env:BLIZZARD_CLIENT_SECRET="your_client_secret"
$env:BLIZZARD_REGION="eu"
$env:BLIZZARD_NAMESPACE="dynamic-forever-eu"
$env:BLIZZARD_LOCALE="ru_RU"
$env:SAVED_VARIABLES_PATH="C:\Program Files (x86)\World of Warcraft\_classic_\WTF\Account\YOUR_ACC\SavedVariables\PriceLog.lua"
```

## Примеры команд CLI

```bash
# Инициализация SQLite (data/ah_tracker.sqlite) и загрузка стартового справочника
uv run ah-tracker init-db

# Выгрузка снимка через Blizzard Game Data API
uv run ah-tracker fetch-api --ruleset-id 1 --window prime

# Импорт локального дампа SavedVariables
uv run ah-tracker import-lua path/to/PriceLog.lua --scan-type partial --window morning

# Отчёт по трансмутациям и окупаемости рецептов (окно 14 дней, комиссия 5%)
uv run ah-tracker report --days 14 --fee-rate 0.05

# Быстрый срез по предметам (по item_id или названию)
uv run ah-tracker watch 12363 "Субстанция Земли" Арканит
```
