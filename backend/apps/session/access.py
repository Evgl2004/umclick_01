import hashlib
import secrets
from dataclasses import dataclass
from datetime import timedelta

from django.contrib.auth.models import AnonymousUser
from django.utils import timezone
from rest_framework.authentication import BaseAuthentication, get_authorization_header
from rest_framework.exceptions import NotFound

from apps.core.errors import AccessAuthenticationFailed
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
        raise AccessAuthenticationFailed('Недействительный токен доступа.', 'access_invalid')
    digest = token_digest(kind, secret)
    if kind == 'participant':
        record = SessionParticipant.objects.filter(token_digest=digest).first()
    elif kind == 'display':
        record = SessionDisplayAccess.objects.select_related('session').filter(token_digest=digest).first()
    else:
        record = None
    if record is None:
        raise AccessAuthenticationFailed('Недействительный токен доступа.', 'access_invalid')
    if kind == 'display':
        if record.revoked_at is not None:
            raise AccessAuthenticationFailed('Доступ показа отозван.', 'access_revoked')
        finished_at = record.session.finished_at
        terminal_without_time = (
            record.session.status in {LiveSession.STATUS_FINISHED, LiveSession.STATUS_ABORTED}
            and finished_at is None
        )
        if terminal_without_time or (
            finished_at is not None and timezone.now() >= finished_at + timedelta(hours=1)
        ):
            raise AccessAuthenticationFailed('Срок доступа показа истёк.', 'access_expired')
    return ScopedAccess(kind, record.pk, record.session_id)


class ScopedTokenAuthentication(BaseAuthentication):
    def authenticate(self, request):
        parts = get_authorization_header(request).split()
        if not parts or parts[0].lower() not in {b'participant', b'display'}:
            return None
        if len(parts) != 2:
            raise AccessAuthenticationFailed('Неверный формат предъявления токена.', 'access_malformed')
        try:
            access = resolve_access(parts[0].decode().lower(), parts[1].decode('ascii'))
        except UnicodeError as exc:
            raise AccessAuthenticationFailed('Неверный формат токена.', 'access_malformed') from exc
        return AnonymousUser(), access

    def authenticate_header(self, request):
        return 'Bearer'


def scoped_session(request, session_uuid, kind):
    access = request.auth
    if not isinstance(access, ScopedAccess):
        raise AccessAuthenticationFailed(
            'Требуется отдельный токен участия.' if kind == 'participant' else 'Требуется отдельный токен показа.',
            'access_required' if access is None else 'access_scope_mismatch',
        )
    if access.kind != kind:
        raise AccessAuthenticationFailed(
            'Токен не предназначен для этой операции.',
            'access_scope_mismatch',
        )
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
