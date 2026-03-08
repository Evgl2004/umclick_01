# umclick

MVP-платформа для интерактивных викторин в стиле Kahoot.

## Текущий стек
- Backend: Django + DRF
- Frontend: Flutter Web
- Database: PostgreSQL
- Orchestration: Docker Compose

## Ветка разработки
- Основная: `main`
- Рабочая: `develop-cai`

## Что уже реализовано (MVP-1)
- JWT-аутентификация преподавателя.
- Регистрация преподавателя (`/api/auth/register/`) с опциональным `TEACHER_SIGNUP_CODE`.
- Личный профиль преподавателя (`/api/auth/me/`).
- CRUD викторин (вопросы + варианты ответов) с teacher-доступом.
- Создание live-сессии преподавателем.
- PIN-код подключения участников.
- Join URL и QR-данные для подключения.
- Быстрая регистрация участника: `phone + name + consent`.
- Отправка ответов участником.
- Подсчёт score (количество правильных ответов).
- Leaderboard по сессии.
- Экспорт результатов в CSV.
- Минимальный Flutter Web клиент (Teacher / Participant).

## Структура проекта
- `backend/` - Django + DRF API
- `frontend/` - Flutter Web клиент
- `docker-compose.yml` - инфраструктура сервисов

## Быстрый старт
1. Создать `.env`:
```bash
cp .env.example .env
```
2. Опционально ограничить регистрацию преподавателя:
```bash
# в .env
TEACHER_SIGNUP_CODE=my-private-code
```
3. Поднять сервисы:
```bash
docker compose up --build
```
4. Backend будет доступен на:
- `http://localhost:8000`
5. Frontend будет доступен на:
- `http://localhost:3000`

## Auth API
Base URL: `http://localhost:8000/api`

- `POST /auth/register/`
- `POST /auth/token/`
- `POST /auth/token/refresh/`
- `GET /auth/me/`

### Пример логина
```json
{
  "username": "teacher1",
  "password": "strong-password"
}
```

Ответ содержит `access` и `refresh`. Для teacher API использовать заголовок:
```text
Authorization: Bearer <access_token>
```

## Основные API endpoints

### Teacher (нужен JWT)
- `GET /quizzes/`
- `POST /quizzes/`
- `GET /quizzes/{id}/`
- `PUT /quizzes/{id}/`
- `DELETE /quizzes/{id}/`
- `POST /sessions/` - создать сессию
- `GET /sessions/{id}/` - получить сессию (PIN, join URL, QR)
- `POST /sessions/{id}/start/` - старт сессии
- `POST /sessions/{id}/finish/` - завершить сессию
- `GET /sessions/{id}/leaderboard/` - таблица результатов
- `GET /sessions/{id}/results/export/` - экспорт CSV

### Participant (публичные)
- `POST /sessions/join/`
- `POST /sessions/answer/`

## Пример payload для создания викторины
```json
{
  "title": "Math quiz",
  "description": "Simple arithmetic",
  "questions": [
    {
      "text": "2 + 2 = ?",
      "order": 1,
      "time_limit_sec": 20,
      "choices": [
        {"text": "3", "order": 1, "is_correct": false},
        {"text": "4", "order": 2, "is_correct": true},
        {"text": "5", "order": 3, "is_correct": false}
      ]
    }
  ]
}
```

## Что планируем в следующей итерации
- Режим реального времени (WebSocket) для синхронного показа вопросов.
- Таймер вопроса и античит-правила.
- Расширенный экспорт (CSV/XLSX, детализация по вопросам).
- Нормальная форма создания викторины во Flutter (без demo-кнопки).
- Юридические страницы privacy/personal data и фиксация версии согласия.
