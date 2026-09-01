# Проверки umclick

Подготовка Python, локального PostgreSQL и `.env.test.local` описана в [руководстве по локальной разработке](development.md).

Основные команды из корня проекта:

```powershell
.\dev.ps1 test-backend
.\dev.ps1 test-backend -Coverage
.\dev.ps1 test-frontend
.\dev.ps1 test-frontend -SkipBuild
.\dev.ps1 test-all
.\dev.ps1 test-all -SkipFrontendBuild
```

Серверные проверки всегда используют PostgreSQL и `umclick.test_settings`; SQLite не применяется. Клиентская последовательность включает получение зависимостей по существующему `pubspec.lock`, проверку форматирования, анализ, тесты и web-сборку.

Сценарии `scripts/check-backend.ps1`, `scripts/check-frontend.ps1` и `scripts/check-all.ps1` сохранены как совместимые оболочки над `dev.ps1`.
