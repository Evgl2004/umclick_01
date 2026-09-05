# Viewing umclick UI

Состояние после локального этапа А: этот документ сохраняет описание прежнего клиентского сценария и эксплуатации. Доступ и маршруты сервера изменены; актуальны [контракт А](block-1-stage-a-api.md) и [отчёт передачи](block-1-stage-a-handoff.md). Совместимость клиента, полное проведение и развёртывание проверяются после Б/В; старые числовые маршруты, JWT для показа и ответ без токена использовать нельзя.

The fastest way to inspect implemented screens is to run Flutter Web. A manual static HTML rewrite is not recommended because it would not preserve Flutter layout, navigation, form states, language switching, or widget behavior.

## Option 1: Live Flutter Web

Run from the repository root:

```powershell
cd frontend
C:\Users\admin_eas\flutter\bin\flutter.bat run -d chrome --web-port 3000
```

Open:

- `http://localhost:3000` - teacher tab by default.
- `http://localhost:3000/#/` - same app shell if the browser adds hash routing.
- `http://localhost:3000/join?pin=123456` - participant entry point with PIN prefilled by URL intent.
- `http://localhost:3000/join?token=123e4567-e89b-42d3-a456-426614174000` - participant entry point with public session UUID.
- `http://localhost:3000/legal/privacy` - public privacy policy screen.
- `http://localhost:3000/legal/consent` - public personal data consent screen.

This mode is best while developing because it gives hot reload and real Flutter widgets.

## Option 2: Generated Static Web Build

Build first:

```powershell
.\scripts\check-frontend.ps1
```

Then serve generated static assets:

```powershell
cd frontend\build\web
python -m http.server 3000
```

Open `http://localhost:3000`.

This is not a hand-written HTML mock. It is the real Flutter Web output (`index.html`, JavaScript, assets) generated from the current application.

## Implemented UI Areas

- Teacher home: API base URL, teacher auth, quiz builder, session setup.
- Teacher live session: PIN/QR area, round controls, reveal results, event log, export URL helper.
- Participant join: game hero, API/PIN/token connection card, preview state, profile form, consent controls.
- Participant live round: question card, answer buttons, timer state, answer lock, reveal results, event log.
- Legal screens: privacy policy, personal data consent, current versions/contact metadata.

## Full Product Flow

For a full live flow, the backend must also be running. The simplest complete environment is still Docker Compose:

```powershell
docker compose up --build
```

Then open `http://localhost:3000`.

If Docker is not available, Flutter Web can still be used to inspect UI templates and form states, but API-dependent actions will show connection errors until a backend is running at `http://localhost:8000/api`.
