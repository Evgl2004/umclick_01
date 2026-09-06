# Frontend umclick

Состояние после локальной реализации этапа В: Flutter использует публичный строковый UUID, схему состояния 2 и раздельные `Bearer`/`Participant`/`Display`. Фактический договор ошибок, повторов и хранения приведён в [контракте В](block-1-stage-v-api.md). Старые числовые маршруты, JWT для показа и ответ без токена не используются.

Frontend находится в `frontend/` и построен на Flutter Web.

## Назначение

Frontend отвечает за:

- панель преподавателя;
- конструктор викторин;
- создание и ведение live-сессии;
- QR/join ссылку для участников;
- отдельный экран демонстрации для очной игры;
- экран участника;
- быструю регистрацию участника;
- прохождение раунда;
- отображение результатов и live-событий;
- legal screens;
- RU/EN переключение интерфейса.

## Структура каталогов

```text
frontend/lib/
  api/
  core/
  features/
    display/
    legal/
    participant/
    teacher/
  l10n/
  shared/
  main.dart
```

## `main.dart`

Отвечает за:

- запуск `UmclickApp`;
- загрузку сохраненного языка;
- MaterialApp и theme;
- entry points;
- `HomePage` с вкладками teacher/participant.

Entry point helpers:

- `resolveEntryPoint` - определяет home/legal/display route.
- `resolveInitialHomeTab` - `/join` открывает вкладку участника.
- `resolvePublicLegalApiBase` - берет API base URL из query или default.

## `lib/api`

`api_client.dart` - единый HTTP-клиент frontend.

Отвечает за:

- teacher auth;
- quiz CRUD;
- session lifecycle;
- session history;
- display state;
- join preview;
- participant join;
- submit answer;
- leaderboard;
- CSV export результатов;
- legal metadata;
- WebSocket URL generation.

Если backend endpoint меняется, сначала обновляем `ApiClient`, затем feature layer.

`ApiClient` поддерживает абсолютный API URL для локальной разработки и относительный `/api` для серверного same-origin развёртывания через nginx.

## `lib/core`

Общие технические helpers:

- `app_config.dart` - constants и default URLs.
- `csv_download.dart` - условная web-реализация скачивания CSV-файла.
- `display_window.dart` - условная web-реализация открытия окна демонстрации.
- `value_utils.dart` - безопасный разбор map/int/datetime, форматирование времени.
- `countdown_ticker.dart` - общий countdown timer.
- `live_event_log.dart` - форматирование и ограничение event log.
- `live_socket_connection.dart` - техническое WebSocket-подключение и разбор JSON.
- `live_socket_supervisor.dart` - ограниченные повторы по коду закрытия и сетевому разрыву, а для истёкшего JWT преподавателя — однократное совместно используемое обновление доступа перед новым соединением.
- `role_access_token_store.dart` - хранение уже полученных ролевых токенов по роли, UUID и доверенному origin; Display дополнительно разделён по UUID выдачи.
- `session_state_reducer.dart` - принятие только схемы 2, защита от устаревшей ревизии и монотонное объединение счётчиков.
- `session_command_controller.dart` - идемпотентные команды и ограниченные повторы одного `command_id`.
- `participant_answer_controller.dart` - последовательные намерения ответа и повторы одного `submission_id`.
- `ranking_format.dart` - единое отображение времени рейтинга с точностью до миллисекунд.

Правило: `core` не должен знать про конкретные экраны teacher/participant.

## `lib/l10n`

Текущий простой слой локализации.

- `app_language.dart` - `UiLanguage`, controller, persistence, language switcher.
- `app_strings.dart` - enum ключей и RU/EN строки.

Русский язык используется по умолчанию. В будущем можно перейти на стандартный Flutter `l10n`/ARB, но текущий слой удобен для MVP и тестируется.

## `features/teacher`

Главный файл:

- `teacher_panel.dart` - stateful orchestration панели преподавателя.

Поддерживающие файлы:

- `teacher_auth_session.dart` - хранение access/refresh token и API base URL.
- `quiz_draft.dart` - контроллеры и модели черновика викторины.
- `quiz_draft_mapper.dart` - API payload <-> draft mapping и validation.

Редактор сохраняет полученные идентификаторы вопросов и вариантов вместе с `content_revision`. При `PUT` они возвращаются серверу; успешный ответ немедленно становится достоверным состоянием формы. Следующее вспомогательное обновление списка не заменяет его даже старой карточкой, а при отказе показывает отдельное сообщение «викторина сохранена, но список не обновлён». Конфликт `quiz_revision_conflict` (`409`) завершает загрузку, показывает локализованное сообщение и оставляет введённые значения, настройки, идентификаторы и исходную редакцию; поле ошибки `current_content_revision` в форму не переносится, автоматического повтора нет. Технические идентификаторы и номера `QuizVersion` интерфейсу не передаются.

Ручное действие «Следующий вопрос» определяется только упорядоченными `session.quiz.questions` из подробного снимка текущей сессии. Редактируемый `_quizzes` не используется как источник игровых вопросов или запасной вариант: создание нового черновика, обновление, пустой результат либо ошибка списка не меняют управление уже загруженной сессией. Очередные HTTP- и WebSocket-состояния накладываются на подробную `_session` и сохраняют вложенный снимок версии; при отсутствии такого снимка переход безопасно остаётся недоступным. Статус, фаза и последний вопрос по-прежнему отдельно ограничивают кнопку в `TeacherLiveSessionCard`.

Widgets:

- `teacher_auth_card.dart` - регистрация/вход/профиль/выход.
- `teacher_quiz_builder_card.dart` - конструктор викторины.
- `teacher_quiz_question_card.dart` - редактирование вопроса.
- `teacher_session_setup_card.dart` - создание live-сессии.
- `teacher_live_session_card.dart` - оболочка live-сессии.
- `teacher_live_session_header.dart` - PIN, QR, статусы.
- `teacher_round_controls.dart` - старт, next, reveal, finish, display, leaderboard, export.
- `teacher_reveal_results_card.dart` - результаты раскрытого ответа.
- `teacher_live_events_card.dart` - live event log.

## `features/participant`

Главный файл:

- `participant_panel.dart` - stateful orchestration экрана участника.

Models:

- `models/join_source.dart` - разбор публичных `/join?token=<uuid>` и `/join?pin=...`; query-параметр `api` игнорируется.

Widgets:

- `participant_hero.dart` - верхний game hero.
- `join_connection_card.dart` - API/PIN/token/preview.
- `profile_card.dart` - имя, телефон, согласие, legal actions, join.
- `question_card.dart` - вопрос и варианты ответа.
- `live_session_widgets.dart` - live status, reveal results, events.

## `features/display`

- `display_session_page.dart` - полноэкранный экран демонстрации `/display`.

Экран демонстрации восстанавливает собственный Display-токен и запрашивает `GET /api/sessions/{uuid}/display-state/`. Короткий JWT преподавателя экрану не передаётся.

Преподаватель хранит UUID текущей Display-выдачи. Повторное открытие использует ту же сохранённую выдачу, а отдельное действие отзыва адресовано этому UUID и безопасно повторяется. Новая серверная выдача отзывает прежние активные выдачи; потерянный до локального сохранения ответ с новым секретом восстановить нельзя.

Он отображает фазы:

- ожидание участников;
- зачитывание вопроса;
- прием ответов;
- статистика с гистограммой;
- финальный подиум.

## `features/legal`

- `legal_documents.dart` - экран текущих legal versions и публичные legal pages.

Legal UI использует metadata backend, но имеет fallback values из `app_config.dart`.

## `shared/widgets`

- `app_surfaces.dart` - общие карточки и status chips.

Shared widgets должны быть независимыми от предметной логики quiz/session.

## State management

На текущем MVP используется локальный `StatefulWidget` state без внешнего state manager.

Это осознанно нормально, пока:

- нет сложного shared state между экранами;
- state-flow покрывается widget tests;
- feature files не становятся трудно поддерживаемыми.

Если появится сложная координация между teacher/participant/legal или offline state, можно рассмотреть Riverpod/BLoC, но сейчас это преждевременно.

Сетевое состояние сессии вынесено из виджетов в небольшие контроллеры. Обычный HTTP-запрос ограничен 10 секундами целиком, CSV — 30 секундами. Команда и ответ повторяются не более трёх раз с тем же идентификатором; при `503` каждый повтор соблюдает полученный `Retry-After` (для текущего серверного договора — 3 секунды), а WebSocket имеет отдельный ограниченный supervisor. Новый выбор, новая команда, новая фаза/ревизия/запуск или закрытие экрана отменяют ожидание и активную HTTP-передачу; поздний результат отменённого намерения интерфейс не меняет.

Снимки одной ревизии не откатывают выбранный ответ или счётчики. Серверное `answer_version` задаёт монотонный порядок состояния собственного ответа поверх общей `state_revision`, а локальный выбор сохраняется до снимка не ниже ожидаемой версии. После снятия локального выбора запоздавшая меньшая версия того же запуска также не заменяет подтверждённый блок: `has_answer`, `selected_choice_id` и `answer_version` сохраняются вместе, тогда как остальные допустимые поля снимка продолжают обновляться. Окончательный серверный ответ имеет приоритет, а новый `question_run_id` немедленно очищает прежний ответ и допускает исходную версию 0.

Доступность вариантов определяется фазой независимо от таймера: в `answering` выбор открыт до истечения основного времени, в `delivery` первый и последующие такты обратного отсчёта не могут снова включить нажатия. Пьедестал включает всех участников с рассчитанным местом не больше трёх, включая ничьи.

## Тесты

Запуск:

```powershell
cd frontend
C:\Users\admin_eas\flutter\bin\flutter.bat test
```

Или из корня:

```powershell
.\scripts\check-frontend.ps1
```

Покрытие:

- pure logic tests для `api`, `core`, `l10n`, `join_source`, `quiz_draft_mapper`;
- widget smoke tests для app shell и основных вкладок;
- widget interaction/regression tests для форм и edge states.

## Просмотр UI

См. `docs/viewing.md`.

Быстрый запуск:

```powershell
cd frontend
C:\Users\admin_eas\flutter\bin\flutter.bat run -d chrome --web-port 3000
```

## Правила изменений frontend

- Новая бизнес-логика сначала по возможности выносится в тестируемый helper/model.
- Крупный widget выносится только при явной пользе.
- Любая новая форма должна иметь loading/error/success states.
- Любой новый пользовательский flow должен иметь хотя бы widget smoke или interaction test.
- Новые строки UI добавляются через `app_strings.dart`, а не hardcode в разных местах.
- API-запросы проходят через `ApiClient`.
