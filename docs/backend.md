# Backend umclick

Backend находится в `backend/` и построен на Django, Django REST Framework, Channels и Celery.

## Назначение

Backend отвечает за:

- регистрацию и JWT-аутентификацию преподавателя;
- CRUD викторин;
- создание и управление live-сессиями;
- подключение участников по PIN или `join_token`;
- прием ответов и расчет очков;
- WebSocket события live-игры;
- автоматическое раскрытие ответов;
- leaderboard и CSV export;
- legal metadata и версии согласий.

## Структура каталогов

```text
backend/
  apps/
    core/
    quiz/
    session/
  umclick/
  manage.py
  requirements.txt
  Dockerfile
```

## `apps.core`

Отвечает за пользователей-преподавателей и права.

Ключевые файлы:

- `serializers.py` - `TeacherRegisterSerializer`, `TeacherSerializer`.
- `views.py` - регистрация преподавателя и `me` endpoint.
- `permissions.py` - `IsTeacher`, требует authenticated user и `is_staff`.
- `urls.py` - auth endpoints проекта.

Teacher registration может быть ограничена переменной `TEACHER_SIGNUP_CODE`.

## `apps.quiz`

Отвечает за структуру викторины.

Модели:

- `Quiz` - title, description, timestamps.
- `Question` - quiz, text, order, time_limit_sec.
- `Choice` - question, text, is_correct, order.

Ключевые файлы:

- `models.py` - модели викторин.
- `serializers.py` - nested serializer для quiz -> questions -> choices.
- `views.py` - `QuizViewSet`, teacher-only CRUD.
- `migrations/0001_initial.py` - initial schema.

## `apps.session`

Самая важная предметная область: live game-flow.

Модели:

- `LiveSession` - quiz, host_name, pin, join_token, status, current_question, timers.
- `Participant` - phone, name, consent, legal versions.
- `SessionParticipant` - связь participant с live session.
- `ParticipantAnswer` - ответ, correctness, score_points.

Ключевые файлы:

- `views.py` - REST endpoints live-сессий, join, answer, export.
- `serializers.py` - session serializers, scoring, join validation, answer validation.
- `realtime.py` - WebSocket payload helpers и broadcast.
- `consumers.py` - Channels consumer.
- `routing.py` - WebSocket routing.
- `autoreveal.py` - атомарное раскрытие ответа.
- `tasks.py` - Celery beat задача auto-reveal.
- `legal.py` - текущие legal versions/links/contact.
- `tests/` - unit, API flow и regression tests.

## REST endpoints

Auth:

- `POST /api/auth/register/`
- `POST /api/auth/token/`
- `POST /api/auth/token/refresh/`
- `GET /api/auth/me/`

Teacher quiz API:

- `GET /api/quizzes/`
- `POST /api/quizzes/`
- `GET /api/quizzes/{id}/`
- `PUT /api/quizzes/{id}/`
- `DELETE /api/quizzes/{id}/`

Teacher session API:

- `POST /api/sessions/`
- `GET /api/sessions/{id}/`
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

## WebSocket

Endpoint:

```text
/ws/sessions/<session_id>/
```

События:

- `session_started`
- `question_started`
- `answer_submitted`
- `answer_revealed`
- `participant_joined`
- `session_finished`
- `session_state`

WebSocket слой не должен сам принимать бизнес-решения. Он передает состояние, подготовленное backend helpers.

## Runtime

Для локальной разработки backend может запускаться через Django `runserver`.

Для демо-стенда и серверного запуска используется ASGI-сервер `daphne`:

```bash
python -m daphne -b 0.0.0.0 -p 8000 umclick.asgi:application
```

Это важно, потому что live-flow использует WebSocket через Django Channels.

## CORS

CORS управляется environment variables:

- `CORS_ALLOW_ALL_ORIGINS` - разрешить все origins, удобно только для локальной разработки;
- `CORS_ALLOWED_ORIGINS` - список разрешённых origins через запятую.

Если `CORS_ALLOW_ALL_ORIGINS` не задан, значение зависит от `DJANGO_DEBUG`: в debug режиме CORS открыт, в server/demo режиме закрыт.

## Scoring

Scoring находится в `apps.session.serializers.score_for_answer`.

Правила:

- неправильный ответ дает `0`;
- быстрый правильный ответ может дать до `1000`;
- медленный правильный ответ не падает ниже `200`;
- elapsed time ограничивается лимитом вопроса.

## Legal metadata

Legal versions берутся из environment variables:

- `PRIVACY_POLICY_VERSION`
- `PRIVACY_POLICY_URL`
- `PERSONAL_DATA_CONSENT_VERSION`
- `PERSONAL_DATA_CONSENT_URL`
- `LEGAL_CONTACT_EMAIL`

При join версии сохраняются в `Participant`.

## Миграции

Проверка актуальности:

```powershell
cd backend
.venv\Scripts\python.exe manage.py makemigrations --check --dry-run
```

Если модель изменилась, миграция должна попасть в тот же логический коммит.

## Тесты

Запуск:

```powershell
cd backend
.venv\Scripts\python.exe manage.py test
```

Или из корня:

```powershell
.\scripts\check-backend.ps1
```

Текущие группы тестов:

- `test_legal.py` - legal metadata.
- `test_scoring.py` - scoring helpers.
- `test_api_flow.py` - happy-path API flow.
- `test_api_regressions.py` - нетиповые и запрещенные сценарии.

## Локальная разработка backend

Первичная установка:

```powershell
python -m venv backend\.venv
backend\.venv\Scripts\python.exe -m pip install --upgrade pip
backend\.venv\Scripts\python.exe -m pip install -r backend\requirements.txt
```

Проверка:

```powershell
.\scripts\check-backend.ps1
```

## Правила изменений backend

- Любой новый endpoint должен иметь API test.
- Любое изменение live-flow должно иметь regression test.
- Любое изменение модели должно иметь migration.
- Teacher-only endpoints должны использовать `IsTeacher`.
- Public endpoints должны явно валидировать входные данные.
- Нельзя полагаться на prefetched cache для критичных счетчиков после записи в БД.
