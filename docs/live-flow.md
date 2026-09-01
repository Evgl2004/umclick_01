# Live-flow umclick

Состояние после локального этапа А: этот документ сохраняет описание прежнего клиентского сценария и эксплуатации. Доступ и маршруты сервера изменены; актуальны [контракт А](block-1-stage-a-api.md) и [отчёт передачи](block-1-stage-a-handoff.md). Совместимость клиента, полное проведение и развёртывание проверяются после Б/В; старые числовые маршруты, JWT для показа и ответ без токена использовать нельзя.

Этот документ описывает основной игровой сценарий: от создания викторины до экспорта результатов.

## Участники flow

- Преподаватель - создает викторины и управляет live-сессией.
- Участник - подключается по PIN/QR/token, регистрируется быстро и отвечает на вопросы.
- Экран демонстрации - отдельное окно `/display`, которое показывает вопрос, варианты, статистику и финальный рейтинг для аудитории.
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
- телефон можно оставить пустым, тогда backend создает внутренний guest-идентификатор без вывода в UI/CSV;
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
- выставляет фазу `lobby`;
- выставляет `started_at`.

WebSocket событие:

- `session_started`.

## 8. Экран демонстрации

Маршрут:

```text
/display?session=<id>&api=<api-base>
```

Экран открывается из панели преподавателя и использует teacher JWT из локального хранилища браузера.

Endpoint состояния:

```text
GET /api/sessions/{id}/display-state/
```

Display state содержит полные тексты вопроса и вариантов даже тогда, когда они скрыты от участника.

## 9. Преподаватель запускает вопрос

Endpoint:

```text
POST /api/sessions/{id}/next-question/
```

Backend:

- выбирает следующий вопрос;
- сохраняет `current_question`;
- выставляет фазу `reading`;
- выставляет `phase_started_at`;
- сбрасывает `question_started_at`;
- сбрасывает `revealed_question_id`;
- рассчитывает `phase_ends_at` по `reading_time_sec`.

WebSocket событие:

- `question_reading_started`.

После окончания времени зачитывания Celery beat автоматически переводит вопрос в фазу ответов:

- `question_started`.

Frontend:

- teacher видит фазу и таймер;
- display показывает вопрос крупно, затем вопрос и варианты;
- participant на фазе `reading` видит просьбу смотреть на экран демонстрации;
- participant на фазе `answering` видит кнопки ответа и таймер.

## 10. Участник отвечает

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
- phase должна быть `answering`;
- current question должен существовать;
- question_id должен совпадать с active question;
- answer нельзя отправить после reveal;
- question timer не должен истечь;
- повторный answer на тот же question запрещен;
- choice должен принадлежать question.

Scoring:

- wrong answer -> 0;
- correct answer -> от 200 до 1000 по скорости.
- `elapsed_ms` сохраняется для tie-break по скорости.

WebSocket событие:

- `answer_submitted`.

## 11. Ответ раскрывается

Ручной endpoint:

```text
POST /api/sessions/{id}/reveal-answer/
```

Автоматический путь:

```text
Celery beat -> auto_reveal_due_sessions -> reveal_current_question_once
```

Backend гарантирует, что reveal происходит один раз на active question.

При reveal session переходит в фазу `results`; `phase_ends_at` рассчитывается по `results_time_sec`.

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

Display показывает гистограмму ответов и правильный вариант. Participant получает подсветку правильной кнопки.

После окончания времени статистики Celery beat автоматически запускает следующий вопрос или завершает сессию.

## 12. Следующий вопрос или завершение

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

Ручное завершение переводит session в `aborted`, чтобы отличать остановленную игру от штатно пройденной.

## 13. Leaderboard, история и CSV export

Endpoints:

```text
GET /api/sessions/
GET /api/sessions/{id}/leaderboard/
GET /api/sessions/{id}/results/export/
```

Leaderboard сортируется:

1. points desc;
2. correct_answers desc;
3. answer_time_ms asc;
4. joined_at asc.

CSV columns:

```text
participant_name,phone,points,correct_answers,answer_time_ms
```

Во frontend кнопка `Экспорт CSV` делает authenticated запрос через `ApiClient` и запускает скачивание файла в браузере. Это важно: endpoint требует JWT преподавателя, поэтому простая публичная ссылка на CSV не подходит.

В панели преподавателя есть блок истории проведенных викторин: список live-сессий, быстрый CSV export и просмотр рейтинга выбранной сессии.

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
