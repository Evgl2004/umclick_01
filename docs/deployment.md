# Демо-развёртывание umclick

Документ описывает лёгкое развёртывание для пользовательской проверки MVP. Это не финальная production-схема: здесь нет HTTPS-терминации, автоматического резервного копирования, мониторинга, ротации логов и полноценной политики хранения персональных данных.

## Когда использовать

Этот вариант подходит, если нужно быстро показать текущий MVP проверяющему пользователю:

- преподаватель открывает публичный URL;
- создаёт викторину;
- запускает live-сессию;
- участник подключается по QR, ссылке или PIN;
- преподаватель выгружает CSV с результатами.

## Минимальные ресурсы

Для лёгкой проверки:

- Ubuntu 24.04;
- Docker Engine и Docker Compose plugin;
- 2 vCPU;
- 2 GB RAM;
- 8 GB диска только как нижняя граница.

Лучше для спокойной работы:

- 2 vCPU;
- 4 GB RAM;
- 30-40 GB диска.

Если на сервере доступно около 4 GB свободного места, сборка Docker image может упереться в диск. В таком случае лучше очистить старые Docker images/volumes, проверить `df -h` и не собирать Flutter на сервере.

## Что отличается от dev Docker Compose

Обычный `docker-compose.yml` предназначен для разработки:

- frontend запускается через `flutter run`;
- backend запускается через Django `runserver`;
- исходники монтируются внутрь контейнеров.

Демо-схема в `deploy/docker-compose.demo.yml` ближе к серверному режиму:

- frontend отдаёт `nginx`;
- backend запускается через ASGI-сервер `daphne`;
- WebSocket `/ws/` проксируется через `nginx`;
- API `/api/` проксируется через `nginx`;
- Flutter Web заранее собирается локально и на сервере не требует Flutter SDK;
- миграции выполняются отдельным одноразовым сервисом `migrate`.

## Подготовка локально

Перед отправкой на сервер нужно собрать Flutter Web:

```powershell
.\scripts\check-frontend.ps1
```

После успешной проверки должен появиться каталог:

```text
frontend/build/web
```

Этот каталог не хранится в Git, поэтому при развёртывании через `git clone` его нужно загрузить на сервер отдельно.

## Подготовка сервера

На сервере должны быть установлены Docker и Compose plugin:

```bash
docker --version
docker compose version
```

Проверить место на диске:

```bash
df -h
docker system df
```

Открыть порт, на котором будет доступен стенд. По умолчанию используется `80`.

## Загрузка проекта

Вариант 1: загрузить архивом только нужные для стенда части:

```powershell
Compress-Archive -Force `
  -Path backend,deploy,frontend\build\web,.env.demo.example,README.md,docs `
  -DestinationPath umclick-demo.zip
```

На сервере:

```bash
mkdir -p ~/umclick
unzip umclick-demo.zip -d ~/umclick
cd ~/umclick
```

Вариант 2: использовать Git:

```bash
git clone <repository-url> umclick
cd umclick
git checkout develop-cai
```

После `git clone` отдельно загрузить локально собранный каталог `frontend/build/web`.

## Настройка `.env.demo`

Создать файл окружения:

```bash
cp .env.demo.example .env.demo
nano .env.demo
```

Обязательно заменить:

- `POSTGRES_PASSWORD` на сильный пароль;
- `DJANGO_SECRET_KEY` на случайную строку;
- `DJANGO_ALLOWED_HOSTS` на IP или домен сервера без схемы;
- `CORS_ALLOWED_ORIGINS` на публичный origin со схемой, например `http://203.0.113.10`;
- `FRONTEND_JOIN_BASE` на публичный URL входа участника, например `http://203.0.113.10/join`;
- `PRIVACY_POLICY_URL` на `http://<host>/legal/privacy`;
- `PERSONAL_DATA_CONSENT_URL` на `http://<host>/legal/consent`;
- `TEACHER_SIGNUP_CODE` на код, который можно выдать проверяющему преподавателю.

`TRUSTED_PROXY_CIDRS` нельзя заполнять предполагаемым внешним IP участника. Здесь допускаются только фактически проверенные сети непосредственного reverse proxy перед Django. Пока значение пусто, backend игнорирует входящие `X-Forwarded-For`/`X-Real-IP` и использует адрес непосредственного peer; это безопасно от подмены, но в Compose может объединить клиентов в одну адресную квоту. Точное значение и разделение клиентов должны быть проверены на целевом стенде до публичной приёмки.

Сгенерировать `DJANGO_SECRET_KEY` можно так:

```bash
openssl rand -hex 32
```

Если используется домен и HTTPS за внешним reverse proxy, URL-переменные нужно указывать с `https://`.

## Запуск

Запускать из корня проекта:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml up -d --build
```

Проверить состояние:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml ps
```

Посмотреть логи:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml logs -f
```

Открыть в браузере:

```text
http://<server-ip-or-domain>
```

## Обновление стенда

На локальной машине снова собрать frontend:

```powershell
.\scripts\check-frontend.ps1
```

Загрузить обновлённый код и `frontend/build/web` на сервер, затем выполнить:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml up -d --build
```

### Контролируемое обновление этапа В и очистка игровых данных

Очистка игровых данных не является частью обычного запуска, миграций или сборки. Её можно выполнять только отдельным решением для точно указанного стенда. Учётные записи, роли, сессии входа и история миграций при этом сохраняются. Викторины, вопросы, варианты, live-сессии, участия, доступы показа, команды, попытки и итоговые ответы удаляются.

До остановки сервиса зафиксируйте текущий commit, ожидаемые имя базы и роль из `.env.demo`, свободное место и состав контейнеров. Не выводите значения паролей и секретов в журнал. Соберите новые образы, но пока не запускайте их:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml build
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml ps
```

Остановите все внешние маршруты и процессы, способные писать игровые данные, оставив PostgreSQL запущенным:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml stop frontend backend celery-worker celery-beat
```

Загрузите доверенные значения окружения в текущий административный shell и проверьте защитные условия. Значения `POSTGRES_DB=postgres`, `template0` и `template1` недопустимы:

```bash
set -a
. ./.env.demo
set +a
test -n "$POSTGRES_DB" && test -n "$POSTGRES_USER"
test "$POSTGRES_DB" != postgres && test "$POSTGRES_DB" != template0 && test "$POSTGRES_DB" != template1
```

Инвентаризация не изменяет данные. Для контейнера backend ожидаемый адрес PostgreSQL равен `db`:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml run --rm --no-deps backend \
  python manage.py stage_v_game_data --inventory \
  --expected-database "$POSTGRES_DB" --expected-host db --expected-port 5432 \
  --expected-role "$POSTGRES_USER"
```

Сохраните вывод вместе с идентификатором commit. Затем создайте резервную копию в каталоге доказательств обновления, проверьте её каталог и вычислите контрольную сумму:

```bash
mkdir -p update-evidence
BACKUP="update-evidence/stage-v-before-$(date -u +%Y%m%dT%H%M%SZ).dump"
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml exec -T db \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges > "$BACKUP"
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml exec -T db \
  pg_restore --list < "$BACKUP" > "$BACKUP.list"
BACKUP_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
test "${#BACKUP_SHA}" -eq 64
```

До изменения рабочей базы обязательно восстановите копию в отдельную временную базу того же PostgreSQL. Её имя создаётся в специальном пространстве и проверяется до последующего удаления:

```bash
RESTORE_DB="test_umclick_restore_$(date -u +%Y%m%d%H%M%S)"
case "$RESTORE_DB" in test_umclick_restore_*) ;; *) exit 1 ;; esac
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml exec -T db \
  createdb -U "$POSTGRES_USER" --maintenance-db "$POSTGRES_DB" \
  -O "$POSTGRES_USER" "$RESTORE_DB"
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml exec -T db \
  pg_restore -U "$POSTGRES_USER" -d "$RESTORE_DB" --single-transaction \
  --no-owner --no-privileges < "$BACKUP"
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml run --rm --no-deps \
  -e POSTGRES_DB="$RESTORE_DB" backend python manage.py stage_v_game_data --inventory \
  --expected-database "$RESTORE_DB" --expected-host db --expected-port 5432 \
  --expected-role "$POSTGRES_USER"
```

Сохраните вывод восстановленной инвентаризации и сравните все счётчики с исходными. Только после совпадения временную базу можно удалить:

```bash
case "$RESTORE_DB" in test_umclick_restore_*) ;; *) exit 1 ;; esac
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml exec -T db \
  dropdb -U "$POSTGRES_USER" --maintenance-db "$POSTGRES_DB" "$RESTORE_DB"
```

Проверочный откат выполняет тот же набор блокировок и удалений, но не фиксирует транзакцию. Поля `before` и `after` должны совпасть, а `transaction` должен быть равен `rolled_back`:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml run --rm --no-deps backend \
  python manage.py stage_v_game_data --rollback-test \
  --expected-database "$POSTGRES_DB" --expected-host db --expected-port 5432 \
  --expected-role "$POSTGRES_USER" \
  --confirm "DELETE-STAGE-V-GAME-DATA:$POSTGRES_DB"
```

Фиксация очистки разрешена только после отдельного подтверждения результата резервирования и пробного отката. Она требует одновременно точной переменной-предохранителя, фразы подтверждения и SHA-256 проверенной копии:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml run --rm --no-deps \
  -e UMCLICK_ALLOW_GAME_DATA_CLEANUP="$POSTGRES_DB|db|5432|$POSTGRES_USER|$BACKUP_SHA" backend \
  python manage.py stage_v_game_data --apply \
  --expected-database "$POSTGRES_DB" --expected-host db --expected-port 5432 \
  --expected-role "$POSTGRES_USER" \
  --confirm "DELETE-STAGE-V-GAME-DATA:$POSTGRES_DB" --backup-sha256 "$BACKUP_SHA"
```

После успешной фиксации повторите `--inventory`: все поля `game_data` должны быть равны нулю, а значения `preserved` — совпасть с исходными. Затем примените миграции, запустите сервисы и выполните приёмку через внешний URL:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml run --rm migrate
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml up -d
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml ps
```

Локальная однобазовая репетиция этого перехода выполнена 8 сентября 2026 года только на `127.0.0.1:5433/test_umclick_local` с собственными синтетическими данными. Она подтвердила обе версии команды очистки, копии A/B/C и адресный повтор A2/B2/C2 с отпечатками содержимого всех таблиц, сохранность учётной записи, назначений разрешений, записи `django_session` и прежних времён миграций, а также непустую `QuizVersion` и обратный ход. Отдельно была доказана чистая установка только игровых приложений `quiz`/`session` с нулевой границы в существующей базе при сохранённой подсистеме пользователей; полная установка всего проекта в пустую базу не выполнялась. Репетиция не является обновлением демо-сервера и не разрешает переносить локальные параметры или решение об очистке на стенд.

При ошибке не продолжайте обновление. Прямое `pg_restore --clean` безопасно применять только к структуре, совместимой с архивом. В локальной репетиции попытка восстановить архив новой схемы прямо поверх старой была полностью отклонена внутри `--single-transaction`: архив не содержал команд удаления внешних ключей, существующих только в старой схеме. Перед восстановлением через границу миграций нужен заранее проверенный и отдельно разрешённый путь к совместимой структуре; не используйте `--fake`, ручную правку `django_migrations`, сброс схемы или очистку неизвестных данных.

Когда совместимость структуры подтверждена, процессы приложения остановлены и цель повторно проверена, верните ранее проверенную версию кода и восстановите резервную копию одной транзакцией:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml exec -T db \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
  --single-transaction --no-owner --no-privileges < "$BACKUP"
```

После восстановления повторите инвентаризацию и только затем запускайте прежнюю версию приложения. В доказательствах обновления сохраняются: commit, исходная и восстановленная инвентаризации, каталог копии, её SHA-256, результат пробного отката, результат фиксации, итоговая инвентаризация и результаты внешней приёмки. Сам файл резервной копии должен храниться в защищённом месте отдельно от публичного каталога приложения.

## Остановка

Остановить контейнеры без удаления базы:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml down
```

Полностью удалить данные демо-базы можно только осознанно:

```bash
docker compose --env-file .env.demo -f deploy/docker-compose.demo.yml down -v
```

Команда `down -v` удаляет volume PostgreSQL и все результаты проверок.

## Ограничения демо-стенда

- Нет встроенного HTTPS.
- Нет автоматических backup.
- Нет production-мониторинга.
- Нет отдельной админ-панели управления пользователями.
- Персональные данные участников сохраняются в базе, поэтому для публичного теста лучше использовать тестовые телефоны.
