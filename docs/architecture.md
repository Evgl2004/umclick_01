# Архитектура umclick

umclick - MVP платформы интерактивных викторин в стиле Kahoot. Архитектура пока монолитная по репозиторию, но разделена на независимые слои: backend API, Flutter Web frontend, инфраструктура Docker Compose и локальные quality-gate скрипты.

## Цели архитектуры

- Быстро развивать MVP без микросервисной сложности раньше времени.
- Держать игровой live-flow проверяемым тестами.
- Не смешивать UI, API-клиент, domain helpers и инфраструктурный код.
- Явно версионировать обработку персональных данных и согласий.
- Поддерживать возможность будущего выделения частей в отдельные сервисы.

## Верхнеуровневая схема

```text
Teacher Browser / Participant Browser
               |
               v
        Flutter Web frontend
               |
       HTTP REST + WebSocket
               |
               v
 Django + DRF + Channels backend
       |              |
       v              v
   PostgreSQL       Redis
                      |
                      v
              Celery worker/beat
```

## Основные компоненты

| Компонент | Путь | Ответственность |
| --- | --- | --- |
| Backend | `backend/` | REST API, WebSocket, игровая логика, scoring, CSV export |
| Frontend | `frontend/` | Flutter Web UI преподавателя и участника |
| Infrastructure | `docker-compose.yml`, `infra/` | PostgreSQL, Redis, backend, Celery, Flutter web-server |
| Scripts | `scripts/` | Локальные Windows-проверки проекта |
| Docs | `docs/` | Архитектура, roadmap, тестирование, просмотр UI, поддержка |

## Backend слой

Backend построен на Django + DRF + Channels.

- `apps.core` - регистрация/профиль преподавателя, права доступа.
- `apps.quiz` - модели и CRUD викторин, вопросов и вариантов ответов.
- `apps.session` - live-сессии, участники, ответы, scoring, WebSocket, legal metadata, CSV export.
- `umclick` - настройки Django, URL routing, ASGI/WSGI, Celery app.

Backend остается Django-монолитом, но приложения уже разделены по предметным областям. Это снижает риск случайного смешивания authentication, quiz CRUD и live game-flow.

## Frontend слой

Frontend построен на Flutter Web.

- `lib/main.dart` - вход в приложение, routing entry points, вкладки teacher/participant.
- `lib/api` - HTTP API client.
- `lib/core` - общие helpers: config, countdown, live event log, WebSocket connection, value parsing.
- `lib/l10n` - текущий слой локализации RU/EN.
- `lib/features/teacher` - панель преподавателя, auth session, quiz draft mapper, teacher widgets.
- `lib/features/participant` - экран участника, join source, participant widgets.
- `lib/features/legal` - legal screens и публичные документы.
- `lib/shared` - общие UI surface widgets.

UI декомпозиция уже доведена до разумного уровня. Новые выносы делаем только при явной боли: дублирование, сложный state-flow, тестируемость или заметный рост файла.

## Инфраструктура

Docker Compose поднимает:

- `db` - PostgreSQL 16.
- `redis` - Redis 7.
- `backend` - Django API на `8000`.
- `celery-worker` - Celery worker.
- `celery-beat` - периодический auto-reveal tick.
- `frontend` - Flutter Web на `3000`.

Локально для разработки также используются:

- `backend/.venv` - Python virtual environment.
- `C:\Users\admin_eas\flutter` - локальный Flutter SDK.
- `scripts/check-all.ps1` - единая проверка проекта.

## Данные и состояние

Ключевые сущности backend:

- `Quiz` — викторина с обязательным владельцем; после первой сессии содержимое неизменяемо.
- `Question` - вопрос викторины.
- `Choice` - вариант ответа.
- `LiveSession` — сессия с создателем, публичным UUID `join_token` и PIN, уникальным среди незавершённых сессий.
- `Participant` — участник с необязательной связью с учётной записью; телефон допускает `NULL` и не идентифицирует человека.
- `SessionParticipant` — неизменяемая связь с конкретной сессией, снимок имени и отпечаток токена.
- `SessionDisplayAccess` — отдельная выдача и отзыв доступа показа; срок до часа после завершения.
- `ParticipantAnswer` - ответ участника на вопрос.

Состояния `LiveSession`:

- `waiting` - сессия создана, участники могут подключаться.
- `live` - игра запущена.
- `finished` — сессия завершена; прежнее участие доступно с токеном только для чтения.
- `aborted` — сессия остановлена с той же постоянной защитой истории.

## Real-time слой

WebSocket используется для live-событий внутри сессии:

- `session_started`
- `question_started`
- `answer_submitted`
- `answer_revealed`
- `participant_joined`
- `session_finished`
- `session_state`

Backend формирует payload, frontend применяет его в teacher/participant feature-экранах. Общая техническая логика WebSocket клиента вынесена во frontend `core/live_socket_connection.dart`.

## Auto-reveal и таймер

Таймер вопроса проверяется на backend при отправке ответа. Автоматическое раскрытие результатов выполняет Celery beat через периодическую задачу `apps.session.auto_reveal_due_sessions`.

Ключевой принцип: раскрытие ответа должно быть атомарным и происходить только один раз на вопрос. Для этого используется поле `revealed_question_id` и функция `reveal_current_question_once`.

## API границы

В А преподаватель определяется группой `teacher`, администратор — признаком `is_staff`. Проверки ограничивают каждое действие владельцем викторины. Регистрация не выдаёт административных полномочий.

Публичны только ограниченный предпросмотр, правовые сведения и создание участия при открытой регистрации. Имя достаточно для анонимного входа, телефон и согласие необязательны. Ответы и чтение участия требуют `Participant`, показ — отдельного `Display`; JWT используется для учётной записи. Потеря токена зарегистрированного участия даёт 409 без перевыпуска, но собственные профиль и результаты остаются доступны по JWT.

Все маршруты сессий и соединений используют UUID. До первого подтверждения соединение не получает данных; ожидание ограничено 10 секундами. Группы разделены по доступу, состояние формируется заново для получателя после проверки токена. Прежний клиент ещё не адаптирован: это задача В.

Постоянная защита истории обеспечивается защищёнными связями, проверками моделей/массовых операций и транзакциями. Завершение не разрешает редактирование или удаление использованного содержимого. Версии и архивирование остаются будущей работой. Точный контракт и границы Б/В: [этап А](block-1-stage-a-api.md).

## Тестовые границы

Покрытие сейчас разделено на слои:

- backend unit tests для legal/scoring helpers;
- backend API flow tests для основных сценариев;
- backend API regression tests для нетиповых действий;
- frontend pure logic tests;
- frontend widget smoke tests;
- frontend widget interaction/regression tests.

Единая локальная команда:

```powershell
.\scripts\check-all.ps1
```

## Архитектурные принципы

- Сначала сохраняем рабочий MVP, затем улучшаем архитектуру.
- Маленькие логические коммиты.
- Backend domain-flow должен иметь API/regression tests.
- Frontend state-heavy widgets должны иметь widget tests.
- Персональные данные и согласия версионируются явно.
- Документация обновляется вместе с изменением архитектуры или flow.
