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

Run from `backend/` after installing `requirements.txt` into a Python environment:

```bash
python manage.py test
```

## Current Test Focus

- Frontend pure logic: value parsing, event log formatting, join-link parsing, language selection, quiz draft payload mapping.
- Backend pure logic: legal document version resolution and Kahoot-style scoring helpers.
- Next layer: API tests for join/answer/export flows and widget smoke tests for teacher/participant screens.
