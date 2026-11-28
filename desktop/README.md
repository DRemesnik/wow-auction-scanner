# Goblin Broker: Desktop (v3.0)

Нативное Windows-приложение (**1 файл `.exe`, ~37 КБ, без установки**) для автоматической синхронизации рыночной телеметрии из аддона **Goblin Broker: Forever** (`ForeverSniper.lua`) в Web-дэшборд.

## Запуск
- Просто запустите **`GoblinBrokerDesktop.exe`** (или ярлык **`Goblin Broker Desktop`** на Рабочем столе).
- Установка, Python, PowerShell или дополнительные библиотеки **не нужны** — работает из коробки на любой Windows 10 / 11 (.NET Framework 4.x уже встроен в ОС).

## Безопасность и 0% риск бана Blizzard ToS
- **Только чтение файла (`FileAccess.Read`, `FileShare.ReadWrite`)**: читает исключительно `SavedVariables\ForeverSniper.lua` после `/reload` или выхода из игры.
- **0 взаимодействий с процессом/памятью WoW**: никаких хуков, макросов или автоматизации.
- **0% нагрузки на CPU в простое**: используется нативный `FileSystemWatcher` ядра Windows (никакого фонового опроса в цикле).
- **Встроенный Privacy Self-Audit**: перед отправкой извлекаются только анонимные рыночные цены/объёмы (`market`, `telemetry.items`, `sales.byItem`). Имена персонажей, аккаунт, золото, пресеты, бинды и логи полностью отбрасываются.

## Как работает у друзей (v3.0)
- **Автопоиск WoW**: приложение само находит `_forever_\WTF\Account\*\SavedVariables\ForeverSniper.lua` на дисках `C:`–`E:` (или можно выбрать файл кнопкой **«Обзор...»**).
- **Два режима синхронизации**:
  1. **GIT · ВЛАДЕЛЕЦ** — автоматически включается рядом с локальным репозиторием `wow-auction-scanner`, отправляет `live_telemetry.json` в ветку `gh-pages`.
  2. **HTTPS · ДЛЯ ДРУЗЕЙ** — при указании HTTPS Endpoint (например, бесплатный Cloudflare Worker) отправляет анонимный JSON по HTTPS `POST`. Друзьям **не нужен Git, GitHub или консоль** — просто скачать `GoblinBrokerDesktop.exe` и запустить.

## Пересборка из исходников
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File desktop\build.ps1 -CreateDesktopShortcut
```
