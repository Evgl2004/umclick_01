from channels.db import database_sync_to_async
import asyncio
from asgiref.sync import sync_to_async
from datetime import UTC, datetime, timedelta
import random
import uuid
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from django.conf import settings
from django.contrib.auth import get_user_model
from django.db.models import Q
from django.utils import timezone
from rest_framework_simplejwt.authentication import JWTAuthentication

from apps.core.errors import AccessAuthenticationFailed
from apps.core.permissions import can_manage_session
from apps.core.rate_limit import LimiterUnavailable
from apps.core.request_identity import websocket_client_address
from apps.core.websocket_limits import LEASE_REFRESH_SECONDS, RedisWebSocketGuard
from apps.session.access import resolve_access, token_digest
from apps.session.models import LiveSession, SessionDisplayAccess, SessionParticipant
from apps.session.realtime import (
    build_account_session_state,
    build_display_session_state,
    build_participant_session_state,
    session_group_name,
)


class SessionConsumer(AsyncJsonWebsocketConsumer):
    auth_timeout = 10
    max_message_bytes = 16 * 1024
    error_messages = {
        'protocol_error': 'Неверный формат сообщения.',
        'auth_timeout': 'Доступ не подтверждён вовремя.',
        'access_malformed': 'Неверный формат доступа.',
        'access_scope_mismatch': 'Доступ не разрешает это соединение.',
        'access_invalid': 'Доступ недействителен.',
        'access_revoked': 'Доступ отозван.',
        'access_expired': 'Срок доступа истёк.',
        'rate_limited': 'Слишком много запросов соединения.',
        'connection_limit': 'Превышено допустимое число соединений.',
        'message_too_large': 'Сообщение превышает допустимый размер.',
        'limiter_unavailable': 'Сервис соединений временно недоступен.',
    }

    async def connect(self):
        try:
            self.session_uuid = uuid.UUID(str(self.scope['url_route']['kwargs']['session_uuid']))
        except (ValueError, KeyError, TypeError):
            await self.close(code=4000)
            return
        self.authorized = False
        self.closing = False
        self.open_lease_acquired = False
        self.access_subject = None
        await self.accept()
        self.accepted = True
        if getattr(settings, 'WS_LIMITS_ENABLED', True):
            self.client_address = websocket_client_address(self.scope)
            self.lease_id = str(uuid.uuid4())
            self.ws_guard = RedisWebSocketGuard()
            try:
                decision = await sync_to_async(
                    self.ws_guard.open,
                    thread_sensitive=False,
                )(self.client_address, self.lease_id)
            except LimiterUnavailable:
                await self._close_with_error(4503, 'limiter_unavailable', 3)
                return
            if not decision.allowed:
                await self._close_with_error(
                    4429,
                    decision.reason or 'rate_limited',
                    decision.retry_after or 1,
                )
                return
            self.open_lease_acquired = True
        self.deadline_task = asyncio.create_task(self._wait_for_auth())

    async def _wait_for_auth(self):
        await asyncio.sleep(self.auth_timeout)
        if not self.authorized:
            await self._close_with_error(4001, 'auth_timeout')

    async def _release_lease(self):
        if not self.open_lease_acquired:
            return
        self.open_lease_acquired = False
        try:
            await sync_to_async(self.ws_guard.release, thread_sensitive=False)(
                self.client_address,
                self.access_subject,
                self.lease_id,
            )
        except LimiterUnavailable:
            pass

    async def _close_with_error(self, close_code, reason, retry_after=None):
        if self.closing:
            return
        self.closing = True
        payload = {
            'event': 'connection_error',
            'code': reason,
            'message': self.error_messages[reason],
        }
        if retry_after is not None:
            payload['retry_after'] = retry_after
        await self.send_json(payload)
        await self._release_lease()
        await self.close(code=close_code)

    def _access_revalidation_delay(self):
        return random.uniform(45, 75)

    async def _watch_access(self):
        while True:
            await asyncio.sleep(self._access_revalidation_delay())
            if not await database_sync_to_async(self._access_is_allowed)():
                await self._close_with_error(
                    4003,
                    getattr(self, 'access_failure_reason', 'access_invalid'),
                )
                return

    async def _expire_access(self, expected_expiry):
        delay = max(0, (expected_expiry - timezone.now()).total_seconds())
        await asyncio.sleep(delay)
        if self.authorized and self.access_expires_at == expected_expiry:
            await self._close_with_error(4003, 'access_expired')

    async def _heartbeat_lease(self):
        while True:
            await asyncio.sleep(LEASE_REFRESH_SECONDS)
            try:
                decision = await sync_to_async(
                    self.ws_guard.heartbeat,
                    thread_sensitive=False,
                )(self.client_address, self.access_subject, self.lease_id)
            except LimiterUnavailable:
                await self._close_with_error(4503, 'limiter_unavailable', 3)
                return
            if not decision.allowed:
                await self._close_with_error(4503, 'limiter_unavailable', 3)
                return

    def _reschedule_access_expiry(self):
        task = getattr(self, 'expiry_task', None)
        if task and task is not asyncio.current_task():
            task.cancel()
        if self.access_expires_at is not None:
            self.expiry_task = asyncio.create_task(
                self._expire_access(self.access_expires_at)
            )
        else:
            self.expiry_task = None

    async def disconnect(self, close_code):
        for name in ('deadline_task', 'access_task', 'expiry_task', 'lease_task'):
            task = getattr(self, name, None)
            if task and task is not asyncio.current_task():
                task.cancel()
        if hasattr(self, 'group_name'):
            await self.channel_layer.group_discard(self.group_name, self.channel_name)
        await self._release_lease()

    async def receive(self, text_data=None, bytes_data=None, **kwargs):
        size = len(bytes_data) if bytes_data is not None else len((text_data or '').encode('utf-8'))
        if size > self.max_message_bytes:
            await self._close_with_error(1009, 'message_too_large')
            return
        if getattr(settings, 'WS_LIMITS_ENABLED', True):
            try:
                decision = await sync_to_async(
                    self.ws_guard.check_message,
                    thread_sensitive=False,
                )(self.lease_id)
            except LimiterUnavailable:
                await self._close_with_error(4503, 'limiter_unavailable', 3)
                return
            if not decision.allowed:
                await self._close_with_error(
                    4429,
                    'rate_limited',
                    decision.retry_after or 1,
                )
                return
        try:
            await super().receive(text_data=text_data, bytes_data=bytes_data, **kwargs)
        except (ValueError, TypeError):
            await self._close_with_error(4000, 'protocol_error')

    async def receive_json(self, content, **kwargs):
        if self.authorized:
            await self._close_with_error(4003, 'access_scope_mismatch')
            return
        if not isinstance(content, dict) or content.get('event') != 'auth':
            await self._close_with_error(4000, 'protocol_error')
            return
        self.access_type = content.get('access_type')
        self.secret = content.get('token')
        if self.access_type not in {'account', 'participant', 'display'}:
            await self._close_with_error(4003, 'access_scope_mismatch')
            return
        if not isinstance(self.secret, str):
            await self._close_with_error(4003, 'access_malformed')
            return
        state = await database_sync_to_async(self._state_if_allowed)()
        if state is None:
            await self._close_with_error(4003, self.access_failure_reason)
            return
        if self.deadline_task.done():
            await self._close_with_error(4001, 'auth_timeout')
            return
        self.access_subject = f'{self.access_type}:{self.access_record_id}'
        if getattr(settings, 'WS_LIMITS_ENABLED', True):
            try:
                decision = await sync_to_async(
                    self.ws_guard.acquire_access,
                    thread_sensitive=False,
                )(self.client_address, self.access_subject, self.lease_id)
            except LimiterUnavailable:
                await self._close_with_error(4503, 'limiter_unavailable', 3)
                return
            if not decision.allowed:
                close_code = 4503 if decision.reason == 'limiter_unavailable' else 4429
                await self._close_with_error(
                    close_code,
                    decision.reason or 'limiter_unavailable',
                    decision.retry_after or 1,
                )
                return
        self.authorized = True
        self.deadline_task.cancel()
        self.group_name = session_group_name(self.session_id, self.access_type)
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        # После подписки перечитываем состояние, чтобы не потерять переход в промежутке.
        state = await database_sync_to_async(self._state_if_allowed)()
        if state is None:
            await self._close_with_error(4003, self.access_failure_reason)
            return
        self._reschedule_access_expiry()
        await self.send_json({'event': 'session_state', 'schema_version': 2, 'payload': state})
        self.access_task = asyncio.create_task(self._watch_access())
        if getattr(settings, 'WS_LIMITS_ENABLED', True):
            self.lease_task = asyncio.create_task(self._heartbeat_lease())

    async def session_event(self, event):
        state = await database_sync_to_async(self._state_if_allowed)()
        if state is None:
            await self._close_with_error(4003, self.access_failure_reason)
            return
        self._reschedule_access_expiry()
        await self.send_json({
            'event': event['event'],
            'schema_version': event.get('schema_version', 2),
            'payload': state,
        })

    def _state_if_allowed(self):
        from rest_framework.exceptions import APIException
        self.access_failure_reason = 'access_invalid'
        session = LiveSession.objects.select_related('quiz', 'current_question').filter(join_token=self.session_uuid).first()
        if session is None:
            self.access_failure_reason = 'access_scope_mismatch'
            return None
        try:
            if self.access_type == 'account':
                auth = JWTAuthentication()
                token = auth.get_validated_token(self.secret)
                user = auth.get_user(token)
                if not can_manage_session(user, session):
                    self.access_failure_reason = 'access_scope_mismatch'
                    return None
                self.access_record_id = user.pk
                self.access_expires_at = datetime.fromtimestamp(int(token['exp']), tz=UTC)
            else:
                access = resolve_access(self.access_type, self.secret)
                if access.session_id != session.pk:
                    self.access_failure_reason = 'access_scope_mismatch'
                    return None
                self.access_record_id = access.record_id
                self.access_expires_at = (
                    session.finished_at + timedelta(hours=1)
                    if self.access_type == 'display' and session.finished_at
                    else None
                )
        except AccessAuthenticationFailed as exc:
            self.access_failure_reason = exc.response_data['code']
            return None
        except (APIException, ValueError, TypeError):
            return None
        self.session_id = session.pk
        if self.access_type == 'display':
            return build_display_session_state(session)
        if self.access_type == 'participant':
            return build_participant_session_state(session, access.record_id)
        return build_account_session_state(session)

    def _access_is_allowed(self):
        from rest_framework.exceptions import APIException

        try:
            if self.access_type == 'account':
                JWTAuthentication().get_validated_token(self.secret)
                allowed = get_user_model().objects.filter(
                    pk=self.access_record_id,
                    is_active=True,
                ).filter(
                    Q(is_staff=True)
                    | Q(
                        groups__name='teacher',
                        quizzes__sessions__pk=self.session_id,
                    )
                ).exists()
                self.access_failure_reason = (
                    'access_scope_mismatch' if not allowed else self.access_failure_reason
                )
                return allowed

            digest = token_digest(self.access_type, self.secret)
            if self.access_type == 'participant':
                allowed = SessionParticipant.objects.filter(
                    pk=self.access_record_id,
                    session_id=self.session_id,
                    token_digest=digest,
                ).exists()
                self.access_failure_reason = 'access_invalid' if not allowed else self.access_failure_reason
                return allowed
            if self.access_type == 'display':
                record = SessionDisplayAccess.objects.filter(
                    pk=self.access_record_id,
                    session_id=self.session_id,
                    token_digest=digest,
                ).values('revoked_at', 'session__status', 'session__finished_at').first()
                if record is None:
                    self.access_failure_reason = 'access_invalid'
                    return False
                if record['revoked_at'] is not None:
                    self.access_failure_reason = 'access_revoked'
                    return False
                finished_at = record['session__finished_at']
                if (
                    record['session__status'] not in [
                        LiveSession.STATUS_WAITING,
                        LiveSession.STATUS_LIVE,
                    ]
                    and (
                        finished_at is None
                        or timezone.now() >= finished_at + timedelta(hours=1)
                    )
                ):
                    self.access_failure_reason = 'access_expired'
                    return False
                return True
        except (APIException, ValueError, TypeError):
            self.access_failure_reason = 'access_invalid'
            return False
        return False
