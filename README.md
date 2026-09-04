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
- Быстрое анонимное участие по имени; телефон и согласие необязательны.
- Preview сессии до регистрации участника.
- Подключение участника по PIN или token-ссылке.
- WebSocket события live-сессии.
- Версионированные команды сессии: отдельные запуск сессии и викторины, досрочное завершение вопроса, следующий вопрос и остановка.
- Серверные сроки фаз `lobby/reading/answering/delivery/results/final` и восстановление через Celery beat.
- Неизменяемый журнал до 20 попыток, однократный итог и рейтинг по правильности и времени правильных ответов.
- Ролевые WebSocket-снимки, рейтинг и CSV-выгрузка без баллов для новой схемы проведения.
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
- WebSocket: `ws://localhost:8000/ws/sessions/<session_uuid>/`

## Локальные проверки

Исполнители используют готовые команды из корня проекта:

```powershell
.\scripts\check-backend.ps1
.\scripts\check-frontend.ps1
.\scripts\check-all.ps1
```

Серверная проверка использует локальный PostgreSQL и настройки из неотслеживаемого `.env.test.local`. Подготовка и дополнительные параметры описаны в [документации проверок](docs/testing.md).

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
| [docs/block-1-requirements.md](docs/block-1-requirements.md) | Согласованные требования первого блока: три последовательных этапа, критерии приёмки и технические вопросы реализации; не описание готового кода |
| [docs/block-1-stage-a-task.md](docs/block-1-stage-a-task.md) | Задание исполнителю этапа А «Данные и доступ»: границы, проверки и передача результата; реализация только после анализа и отдельного подтверждения |
| [docs/block-1-stage-a-prompt.md](docs/block-1-stage-a-prompt.md) | Расширенный стартовый промт: документация, правила разработки, отчёт анализа и обязательная остановка до разрешения реализации |
| [docs/block-1-stage-b-task.md](docs/block-1-stage-b-task.md) | Задание исполнителю этапа Б «Проведение викторины»: серверные этапы, попытки, время, рейтинг, команды, восстановление и проверки ПР-11–ПР-26 |
| [docs/block-1-stage-b-prompt.md](docs/block-1-stage-b-prompt.md) | Расширенный стартовый промт Б: анализ без изменений, проработка ВОП-02, правила разработки и отдельное разрешение реализации |
| [docs/block-1-stage-b-api.md](docs/block-1-stage-b-api.md) | Фактический серверный контракт этапа Б: фазы, команды, попытки, итоги, время, рейтинг и события |
| [docs/block-1-stage-b-handoff.md](docs/block-1-stage-b-handoff.md) | Передача реализации Б: миграции, ВОП-02, проверки БП-01–БП-16 и граница этапа В |
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

Любая связанная сессия навсегда запрещает изменение/удаление использованной викторины и содержимого; история защищена от прямого и каскадного удаления. Версии и архивирование пока не реализованы. Локальная реализация А не является разрешением развёртывания.

После А преподаватель использует JWT и группу `teacher`, администратор — `is_staff`; каждое действие проверяет владельца. Серверный протокол проведения реализован в Б, но Flutter-клиент ещё требует адаптации В. Подробности: [контракт А](docs/block-1-stage-a-api.md) и [контракт Б](docs/block-1-stage-b-api.md).

- `POST /api/auth/register/`
- `POST /api/auth/token/`
- `POST /api/auth/token/refresh/`
- `GET /api/auth/me/`
- `GET|POST /api/quizzes/`
- `GET|PUT|DELETE /api/quizzes/{id}/`
- `POST /api/sessions/`
- `POST /api/sessions/{uuid}/start/`
- `POST /api/sessions/{uuid}/start-quiz/`
- `POST /api/sessions/{uuid}/end-question/`
- `POST /api/sessions/{uuid}/next-question/`
- `POST /api/sessions/{uuid}/finish/`
- `GET /api/sessions/{uuid}/leaderboard/`
- `GET /api/sessions/{uuid}/results/export/`

Подключение и доступ участника:

- `GET /api/sessions/join/preview/`
- `POST /api/sessions/join/`
- `POST /api/sessions/{uuid}/answer/` — токен участия
- `GET /api/sessions/{uuid}/participation/` — токен участия
- `GET /api/sessions/my-results/` — собственные результаты по JWT
- `POST /api/sessions/{uuid}/display-access/` — выдача показа владельцем
- `GET /api/sessions/{uuid}/display-state/` — отдельный токен показа
- `GET /api/sessions/legal/current/`

Управляющая команда передаёт `command_id`, `state_revision`, `phase` и `question_run_id`. Ответ участника передаёт `question_id`, `choice_id` и уникальный `submission_id`; клиентские `run_id` и отметка времени не принимаются. Маршрут прежнего немедленного раскрытия удалён.

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
