# Демо-развёртывание umclick

Документ описывает лёгкое развёртывание для пользовательской проверки MVP. Это не финальная production-схема: здесь нет HTTPS-терминации, резервного копирования, мониторинга, ротации логов и полноценной политики хранения персональных данных.

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
