import hashlib
import secrets
from dataclasses import dataclass

from django.contrib.auth.models import AnonymousUser
from rest_framework.authentication import BaseAuthentication, get_authorization_header
from rest_framework.exceptions import AuthenticationFailed, NotFound

from apps.session.models import LiveSession, SessionDisplayAccess, SessionParticipant


def token_digest(kind, secret):
    return hashlib.sha256(f'{kind}:{secret}'.encode('utf-8')).hexdigest()


def issue_secret(kind):
    secret = secrets.token_urlsafe(32)
    return secret, token_digest(kind, secret)


@dataclass(frozen=True)
class ScopedAccess:
    kind: str
    record_id: object
    session_id: int


def resolve_access(kind, secret):
    if not isinstance(secret, str) or not 40 <= len(secret) <= 128:
        raise AuthenticationFailed('Недействительный токен доступа.')
    digest = token_digest(kind, secret)
    if kind == 'participant':
        record = SessionParticipant.objects.filter(token_digest=digest).first()
    elif kind == 'display':
        record = SessionDisplayAccess.objects.select_related('session').filter(token_digest=digest).first()
        if record and not record.is_valid:
            record = None
    else:
        record = None
    if record is None:
        raise AuthenticationFailed('Недействительный или отозванный токен доступа.')
    return ScopedAccess(kind, record.pk, record.session_id)


class ScopedTokenAuthentication(BaseAuthentication):
    def authenticate(self, request):
        parts = get_authorization_header(request).split()
        if not parts or parts[0].lower() not in {b'participant', b'display'}:
            return None
        if len(parts) != 2:
            raise AuthenticationFailed('Неверный формат предъявления токена.')
        try:
            access = resolve_access(parts[0].decode().lower(), parts[1].decode('ascii'))
        except UnicodeError as exc:
            raise AuthenticationFailed('Неверный формат токена.') from exc
        return AnonymousUser(), access

    def authenticate_header(self, request):
        return 'Bearer'


def scoped_session(request, session_uuid, kind):
    access = request.auth
    if not isinstance(access, ScopedAccess) or access.kind != kind:
        raise AuthenticationFailed('Требуется отдельный токен участия.' if kind == 'participant' else 'Требуется отдельный токен показа.')
    session = LiveSession.objects.select_related('quiz', 'current_question').filter(join_token=session_uuid, pk=access.session_id).first()
    if session is None:
        raise NotFound('Сессия недоступна.')
    return session


def resolve_join_session(*, pin=None, join_token=None):
    queryset = LiveSession.objects.select_related('quiz')
    if join_token:
        queryset = queryset.filter(join_token=join_token)
    else:
        queryset = queryset.filter(pin=pin, status__in=['waiting', 'live'])
    session = queryset.first()
    if session is None:
        raise NotFound('Сессия не найдена.')
    return session
