# Live-flow umclick

Этот документ описывает основной игровой сценарий: от создания викторины до экспорта результатов.

## Участники flow

- Преподаватель - создает викторины и управляет live-сессией.
- Участник - подключается по PIN/QR/token, регистрируется быстро и отвечает на вопросы.
- Backend - хранит состояние, валидирует действия, считает очки, рассылает события.
- Frontend - отображает состояние и отправляет действия пользователя.
- Celery beat - автоматически раскрывает ответы после дедлайна вопроса.

## 1. Преподаватель регистрируется или входит

Teacher endpoints:

- `POST /api/auth/register/`
- `POST /api/auth/token/`
- `POST /api/auth/token/refresh/`
- `GET /api/auth/me/`

Frontend:

- `TeacherAuthCard`
- `TeacherAuthSessionStore`
- `ApiClient`

После входа frontend хранит access/refresh token локально и пытается восстановить сессию при перезагрузке.

## 2. Преподаватель создает викторину

Endpoint:

```text
POST /api/quizzes/
```

Payload содержит:

- `title`
- `description`
- `questions[]`
- `choices[]`

Frontend builder:

- `TeacherQuizBuilderCard`
- `TeacherQuizQuestionCard`
- `QuizDraftMapper`

Валидация frontend:

- title обязателен;
- минимум один question;
- у каждого question минимум два непустых choices;
- ровно один correct choice;
- time limit от 5 до 180 секунд.

Backend сохраняет quiz, questions и choices nested serializer-ом.

## 3. Преподаватель создает live-сессию

Endpoint:

```text
POST /api/sessions/
```

Backend создает `LiveSession`:

- генерирует уникальный 6-значный `pin`;
- генерирует `join_token`;
- выставляет `status = waiting`.

Frontend показывает:

- PIN;
- QR;
- join URL;
- WebSocket status;
- participants count.

## 4. Участник открывает join screen

Варианты входа:

```text
/join?pin=123456
/join?token=<uuid>
/join?api=http://localhost:8000/api&token=<uuid>
```

Frontend разбирает ссылку через `ParticipantJoinSource`.

Если есть token, UI включает token mode. Если есть PIN, UI заполняет PIN field.

## 5. Preview сессии

Endpoint:

```text
GET /api/sessions/join/preview/?pin=123456
GET /api/sessions/join/preview/?token=<uuid>
```

Preview возвращает:

- session id;
- session pin;
- session status;
- participants count;
- `can_join`;
- closed reason;
- quiz title/description;
- current question state;
- legal documents.

Frontend показывает preview до регистрации участника.

## 6. Быстрая регистрация участника

Endpoint:

```text
POST /api/sessions/join/
```

Участник отправляет:

- `pin` или `join_token`;
- `phone`;
- `name`;
- `consent = true`.

Backend проверяет:

- согласие обязательно;
- PIN/token должен существовать;
- finished session запрещена;
- legal versions сохраняются в `Participant`;
- `SessionParticipant` создается один раз на session + participant.

После join backend шлет WebSocket события:

- `participant_joined`;
- `session_state`.

## 7. Преподаватель запускает сессию

Endpoint:

```text
POST /api/sessions/{id}/start/
```

Backend:

- переводит `status` в `live`;
- очищает current question;
- сбрасывает reveal state;
- выставляет `started_at`.

WebSocket событие:

- `session_started`.

## 8. Преподаватель запускает вопрос

Endpoint:

```text
POST /api/sessions/{id}/next-question/
```

Backend:

- выбирает следующий вопрос;
- сохраняет `current_question`;
- выставляет `question_started_at`;
- сбрасывает `revealed_question_id`;
- рассчитывает `question_ends_at`.

WebSocket событие:

- `question_started`.

Frontend:

- teacher видит active question, таймер и answered count;
- participant видит вопрос, варианты и таймер.

## 9. Участник отвечает

Endpoint:

```text
POST /api/sessions/answer/
```

Payload:

- `session_participant_id`;
- `question_id`;
- `choice_id`.

Backend проверяет:

- session должна быть `live`;
- current question должен существовать;
- question_id должен совпадать с active question;
- answer нельзя отправить после reveal;
- question timer не должен истечь;
- повторный answer на тот же question запрещен;
- choice должен принадлежать question.

Scoring:

- wrong answer -> 0;
- correct answer -> от 200 до 1000 по скорости.

WebSocket событие:

- `answer_submitted`.

## 10. Ответ раскрывается

Ручной endpoint:

```text
POST /api/sessions/{id}/reveal-answer/
```

Автоматический путь:

```text
Celery beat -> auto_reveal_due_sessions -> reveal_current_question_once
```

Backend гарантирует, что reveal происходит один раз на active question.

WebSocket событие:

- `answer_revealed`.

Payload содержит:

- question;
- choices;
- correct flags;
- answers count;
- points awarded;
- total answers;
- revealed_by;
- auto flag.

## 11. Следующий вопрос или завершение

Если есть следующий вопрос, teacher снова вызывает `next-question`.

Если вопросов больше нет:

- backend переводит session в `finished`;
- очищает active question;
- выставляет `finished_at`;
- отправляет `session_finished`.

Teacher также может завершить вручную:

```text
POST /api/sessions/{id}/finish/
```

## 12. Leaderboard и CSV export

Endpoints:

```text
GET /api/sessions/{id}/leaderboard/
GET /api/sessions/{id}/results/export/
```

Leaderboard сортируется:

1. points desc;
2. correct_answers desc;
3. joined_at asc.

CSV columns:

```text
participant_name,phone,points,correct_answers
```

## Нетиповые сценарии, которые покрыты тестами

- teacher API без авторизации;
- teacher API для non-staff пользователя;
- preview без PIN/token;
- preview с неизвестным PIN;
- preview с некорректным token;
- join в finished session;
- next-question в waiting session;
- reveal без active question;
- answer на неактивный question;
- answer после reveal;
- answer в inactive session;
- duplicate answer на тот же question;
- late answer после дедлайна.

## Где менять flow

- Backend validation: `backend/apps/session/serializers.py`.
- Backend lifecycle endpoints: `backend/apps/session/views.py`.
- WebSocket payload/state: `backend/apps/session/realtime.py`.
- Auto reveal: `backend/apps/session/autoreveal.py`, `backend/apps/session/tasks.py`.
- Teacher UI orchestration: `frontend/lib/features/teacher/teacher_panel.dart`.
- Participant UI orchestration: `frontend/lib/features/participant/participant_panel.dart`.

## Правило поддержки

Любое изменение этого flow должно обновлять:

- backend API/regression tests;
- frontend widget tests, если меняется UI state;
- этот документ, если меняется порядок действий, событие или контракт payload.
