# umclick

MVP-платформа для интерактивных викторин в стиле Kahoot.

## Текущий стек
- Backend: Django + DRF + Channels (WebSocket)
- Frontend: Flutter Web
- Database: PostgreSQL
- Orchestration: Docker Compose

## Ветки
- `main`
- `develop-cai`

## Что реализовано (MVP-7)
- JWT-аутентификация преподавателя.
- CRUD викторин (teacher-only).
- Создание live-сессий, PIN и QR для подключения.
- Быстрая регистрация участника: `phone + name + consent`.
- Real-time события через WebSocket:
  - `session_started`
  - `question_started`
  - `answer_submitted`
  - `answer_revealed`
  - `participant_joined`
  - `session_finished`
  - `session_state`
- Управление раундом преподавателем:
  - старт сессии
  - следующий вопрос
  - ручное раскрытие правильного ответа
  - завершение сессии
- Таймер вопроса:
  - сервер проверяет дедлайн на отправку ответа
  - клиент показывает обратный отсчёт
  - результаты автоматически раскрываются по истечении таймера
- Скоринговая модель (Kahoot-style):
  - очки за правильный ответ зависят от скорости
  - в leaderboard ранжирование по `points`, затем по `correct_answers`
- Персистентная сессия преподавателя во Flutter:
  - access/refresh токены сохраняются локально в браузере
  - при перезагрузке UI пробует восстановить teacher-сессию автоматически
  - при ответе 401 Unauthorized UI пытается обновить access token через refresh token и повторяет teacher-запрос
- Визуальный конструктор викторин во Flutter:
  - создание/редактирование квиза (title + description)
  - динамическое добавление/удаление вопросов и вариантов
  - валидация: минимум 2 варианта и ровно 1 правильный ответ на вопрос
- Экспорт результатов в CSV (`points`, `correct_answers`).

## Структура
- `backend/` - Django API + WebSocket
- `frontend/` - Flutter Web клиент
- `docker-compose.yml` - локальная инфраструктура

## Быстрый старт
1. Создать `.env`:
```bash
cp .env.example .env
```
2. (Опционально) Ограничить регистрацию преподавателя:
```bash
# в .env
TEACHER_SIGNUP_CODE=my-private-code
```
3. Запуск:
```bash
docker compose up --build
```
4. Доступ:
- Backend API: `http://localhost:8000/api`
- WebSocket: `ws://localhost:8000/ws/sessions/<session_id>/`
- Frontend: `http://localhost:3000`

## Auth API
- `POST /api/auth/register/`
- `POST /api/auth/token/`
- `POST /api/auth/token/refresh/`
- `GET /api/auth/me/`

Для teacher API нужен заголовок:
```text
Authorization: Bearer <access_token>
```

## Teacher API (JWT)
- `GET /api/quizzes/`
- `POST /api/quizzes/`
- `GET /api/quizzes/{id}/`
- `PUT /api/quizzes/{id}/`
- `DELETE /api/quizzes/{id}/`

- `POST /api/sessions/`
- `GET /api/sessions/{id}/`
- `POST /api/sessions/{id}/start/`
- `POST /api/sessions/{id}/next-question/`
- `POST /api/sessions/{id}/reveal-answer/`
- `POST /api/sessions/{id}/finish/`
- `GET /api/sessions/{id}/leaderboard/`
- `GET /api/sessions/{id}/results/export/`

## Participant API (публичные)
- `POST /api/sessions/join/`
- `POST /api/sessions/answer/`
- `GET /api/sessions/{id}/state/`

## Следующая итерация
- Стабильный multi-instance таймер (Redis/Celery beat вместо in-process).
- Privacy/personal data страницы и версионирование согласий.
