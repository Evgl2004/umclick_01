# umclick

umclick - MVP платформы интерактивных викторин в стиле Kahoot.

Проект строится как публичный, поддерживаемый продукт: backend, frontend, тесты, документация и локальные проверки должны развиваться вместе.

## Текущий стек

- Backend: Django + Django REST Framework + Channels + Celery.
- Frontend: Flutter Web.
- Database: PostgreSQL.
- Messaging/tasks: Redis + Celery worker + Celery beat.
- Local orchestration: Docker Compose.
- Local quality gate: PowerShell scripts in `scripts/`.

## Что уже реализовано

- Регистрация и JWT-вход преподавателя.
- CRUD викторин для преподавателя.
- Конструктор викторин во Flutter Web.
- Live-сессии с PIN, QR и `join_token`.
- Быстрая регистрация участника: телефон, имя, согласие.
- Preview сессии до регистрации участника.
- Подключение участника по PIN или token-ссылке.
- WebSocket события live-сессии.
- Управление раундом: start, next question, reveal answer, finish.
- Таймер вопроса и auto-reveal через Celery beat.
- Kahoot-style scoring по скорости ответа.
- Leaderboard и CSV export результатов.
- Legal metadata, версии согласий и публичные legal screens.
- RU/EN переключение интерфейса, русский по умолчанию.
- Локальные backend/frontend тесты и regression-покрытие.
- Windows scripts для единой локальной проверки проекта.

## Быстрый старт через Docker Compose

Создать `.env` из примера:

```powershell
Copy-Item .env.example .env
```

Запустить инфраструктуру:

```powershell
docker compose up --build
```

Открыть:

- Frontend: `http://localhost:3000`
- Backend API: `http://localhost:8000/api`
- WebSocket: `ws://localhost:8000/ws/sessions/<session_id>/`

## Локальные проверки

Полная проверка проекта:

```powershell
.\scripts\check-all.ps1
```

Только backend:

```powershell
.\scripts\check-backend.ps1
```

Только frontend:

```powershell
.\scripts\check-frontend.ps1
```

Быстрая frontend-проверка без web build:

```powershell
.\scripts\check-frontend.ps1 -SkipBuild
```

## Как посмотреть UI

Самый удобный способ - запустить Flutter Web:

```powershell
cd frontend
C:\Users\admin_eas\flutter\bin\flutter.bat run -d chrome --web-port 3000
```

Полная инструкция: `docs/viewing.md`.

## Демо-стенд для проверки

Для пользовательской проверки подготовлена отдельная server-схема:

- `deploy/docker-compose.demo.yml` - PostgreSQL, Redis, Django ASGI, Celery и nginx;
- `deploy/nginx.demo.conf` - отдача Flutter Web, proxy `/api/` и `/ws/`;
- `.env.demo.example` - пример переменных окружения для стенда.

Техническая инструкция: `docs/deployment.md`.

Сценарий для проверяющего пользователя: `docs/reviewer-guide.md`.

## Документация

| Документ | Назначение |
| --- | --- |
| `docs/architecture.md` | Общая архитектура, границы слоев, компоненты |
| `docs/backend.md` | Backend apps, models, endpoints, WebSocket, tests |
| `docs/frontend.md` | Flutter структура, features, widgets, state, tests |
| `docs/live-flow.md` | Полный игровой сценарий teacher/participant |
| `docs/live-presentation-mode.md` | Задание и критерии очного режима с экраном демонстрации |
| `docs/maintenance.md` | Правила поддержки проекта и документации |
| `docs/deployment.md` | Как развернуть демо-стенд на сервере |
| `docs/reviewer-guide.md` | Пошаговая инструкция для проверяющего пользователя |
| `docs/testing.md` | Локальные проверки и текущая тестовая стратегия |
| `docs/viewing.md` | Как смотреть реализованные экраны |
| `docs/roadmap.md` | Дорожная карта и статус работ |

## Структура репозитория

```text
backend/          Django API, WebSocket, Celery
frontend/         Flutter Web client
docs/             Project documentation
deploy/           Demo deployment compose and nginx config
scripts/          Local Windows quality-gate scripts
infra/            Infrastructure notes/placeholders
docker-compose.yml
```

## Основные API группы

Teacher API требует JWT и `is_staff=True`.

- `POST /api/auth/register/`
- `POST /api/auth/token/`
- `POST /api/auth/token/refresh/`
- `GET /api/auth/me/`
- `GET|POST /api/quizzes/`
- `GET|PUT|DELETE /api/quizzes/{id}/`
- `POST /api/sessions/`
- `POST /api/sessions/{id}/start/`
- `POST /api/sessions/{id}/next-question/`
- `POST /api/sessions/{id}/reveal-answer/`
- `POST /api/sessions/{id}/finish/`
- `GET /api/sessions/{id}/leaderboard/`
- `GET /api/sessions/{id}/results/export/`

Public participant API:

- `GET /api/sessions/join/preview/`
- `POST /api/sessions/join/`
- `POST /api/sessions/answer/`
- `GET /api/sessions/{id}/state/`
- `GET /api/sessions/legal/current/`

## Ветки

- `main` - стабильная ветка.
- `develop-cai` - текущая ветка разработки.

## Правила развития

- Сначала сохраняем рабочий MVP, затем улучшаем архитектуру.
- Один логический шаг - один коммит.
- Новые backend endpoints покрываем API tests.
- Новые live-flow edge cases покрываем regression tests.
- Новые frontend формы покрываем widget interaction tests.
- Изменения архитектуры, API или flow отражаем в `docs/`.
