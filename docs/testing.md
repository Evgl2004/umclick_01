# Testing umclick

This document keeps the local quality checks in one place.

## Frontend

Run from `frontend/`:

```bash
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test
flutter build web
```

## Backend

Create a local virtual environment once from the repository root:

```bash
python -m venv backend/.venv
backend/.venv/Scripts/python.exe -m pip install --upgrade pip
backend/.venv/Scripts/python.exe -m pip install -r backend/requirements.txt
```

Run from `backend/`:

```bash
.venv/Scripts/python.exe manage.py test
```

## Current Test Focus

- Frontend pure logic: value parsing, event log formatting, join-link parsing, language selection, quiz draft payload mapping.
- Backend pure logic: legal document version resolution and Kahoot-style scoring helpers.
- Backend API flow: teacher quiz/session creation, public preview, join by PIN/token, consent enforcement, answer submission, duplicate/late-answer rejection, public state safety, leaderboard, CSV export.
- Next layer: widget smoke tests for teacher/participant screens and broader end-to-end checks through Docker/CI.
