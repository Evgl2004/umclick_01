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

## Что уже реализовано (MVP-0)
- CRUD викторин (вопросы + варианты ответов).
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
2. Поднять сервисы:
```bash
docker compose up --build
```
3. Backend будет доступен на:
- `http://localhost:8000`
4. Frontend будет доступен на:
- `http://localhost:3000`

## Основные API endpoints
Base URL: `http://localhost:8000/api`

### Викторины (преподаватель)
- `GET /quizzes/`
- `POST /quizzes/`
- `GET /quizzes/{id}/`
- `PUT /quizzes/{id}/`
- `DELETE /quizzes/{id}/`

### Сессии (преподаватель)
- `POST /sessions/` - создать сессию
- `GET /sessions/{id}/` - получить сессию (PIN, join URL, QR)
- `POST /sessions/{id}/start/` - старт сессии
- `POST /sessions/{id}/finish/` - завершить сессию
- `GET /sessions/{id}/leaderboard/` - таблица результатов
- `GET /sessions/{id}/results/export/` - экспорт CSV

### Участник
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
- Авторизация преподавателя (JWT/Session).
- Режим реального времени (WebSocket) для синхронного показа вопросов.
- Таймер вопроса и античит-правила.
- Расширенный экспорт (CSV/XLSX, детализация по вопросам).
- Нормальная форма создания викторины во Flutter (без demo-кнопки).
- Юридические страницы privacy/personal data и фиксация версии согласия.
