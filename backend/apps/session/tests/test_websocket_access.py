from datetime import timedelta
from time import monotonic
from unittest.mock import patch
from channels.db import database_sync_to_async
from channels.testing import WebsocketCommunicator
from django.test import TransactionTestCase, override_settings
from django.utils import timezone
from rest_framework_simplejwt.tokens import AccessToken, RefreshToken

from apps.core.rate_limit import LimitDecision, LimiterUnavailable
from apps.core.websocket_limits import WebSocketLimitDecision
from apps.session.access import issue_secret
from apps.session.models import SessionDisplayAccess
from apps.session.realtime import broadcast_session_event
from apps.session.tests.helpers import teacher, game
from umclick.asgi import application


class WebsocketAccessTests(TransactionTestCase):
    def setUp(self):
        self.owner = teacher()
        self.g = game(self.owner, active=True)
        self.foreign = game(teacher('foreign'), active=True)
        self.jwt = str(AccessToken.for_user(self.owner))
        self.display_secret, digest = issue_secret('display')
        self.grant = SessionDisplayAccess.objects.create(session=self.g.session, token_digest=digest)

    async def socket(self):
        communicator = WebsocketCommunicator(application, f'/ws/sessions/{self.g.session.join_token}/')
        connected, _ = await communicator.connect()
        self.assertTrue(connected)
        return communicator

    async def test_no_data_before_auth_and_close_after_ten_seconds(self):
        socket = await self.socket()
        started = monotonic()
        self.assertTrue(await socket.receive_nothing(timeout=0.1))
        error = await socket.receive_json_from(timeout=11)
        message = await socket.receive_output()
        self.assertEqual(error['code'], 'auth_timeout')
        self.assertEqual(message, {'type': 'websocket.close', 'code': 4001})
        self.assertGreaterEqual(monotonic() - started, 9.8)
        await socket.disconnect()

    async def test_each_access_type_authenticates_without_secret_in_state(self):
        for kind, token in [('account', self.jwt), ('participant', self.g.secret), ('display', self.display_secret)]:
            socket = await self.socket()
            await socket.send_json_to({'event': 'auth', 'access_type': kind, 'token': token})
            message = await socket.receive_json_from()
            self.assertEqual(message['event'], 'session_state')
            self.assertNotIn(token, str(message))
            self.assertNotIn('phone', str(message))
            await socket.send_json_to({'event': 'auth', 'access_type': 'account', 'token': self.jwt})
            self.assertEqual((await socket.receive_json_from())['code'], 'access_scope_mismatch')
            self.assertEqual((await socket.receive_output())['code'], 4003)
            await socket.disconnect()

    async def test_invalid_foreign_expired_and_refresh_tokens_are_rejected(self):
        expired = AccessToken.for_user(self.owner)
        expired.set_exp(lifetime=timedelta(seconds=-1))
        cases = [
            ('participant', self.foreign.secret, 'access_scope_mismatch'),
            ('participant', self.display_secret, 'access_invalid'),
            ('account', str(expired), 'access_invalid'),
            ('account', str(RefreshToken.for_user(self.owner)), 'access_invalid'),
            ('display', 'неверный', 'access_invalid'),
        ]
        for kind, token, reason in cases:
            socket = await self.socket()
            await socket.send_json_to({'event': 'auth', 'access_type': kind, 'token': token})
            error = await socket.receive_json_from()
            self.assertEqual(error['code'], reason)
            self.assertNotIn(token, str(error))
            self.assertEqual((await socket.receive_output())['code'], 4003)
            await socket.disconnect()

    async def test_open_account_connection_closes_at_jwt_expiry(self):
        short_token = AccessToken.for_user(self.owner)
        short_token.set_exp(lifetime=timedelta(seconds=2))
        socket = await self.socket()
        await socket.send_json_to(
            {'event': 'auth', 'access_type': 'account', 'token': str(short_token)}
        )
        self.assertEqual((await socket.receive_json_from())['event'], 'session_state')

        error = await socket.receive_json_from(timeout=3)
        message = await socket.receive_output()

        self.assertEqual(error['code'], 'access_expired')
        self.assertEqual(message, {'type': 'websocket.close', 'code': 4003})
        await socket.disconnect()

    async def test_open_display_connection_closes_at_display_expiry(self):
        def finish_near_expiry():
            self.g.session.status = 'finished'
            self.g.session.finished_at = timezone.now() - timedelta(hours=1) + timedelta(seconds=2)
            self.g.session.save(update_fields=['status', 'finished_at'])

        await database_sync_to_async(finish_near_expiry)()
        socket = await self.socket()
        await socket.send_json_to(
            {'event': 'auth', 'access_type': 'display', 'token': self.display_secret}
        )
        self.assertEqual((await socket.receive_json_from())['event'], 'session_state')

        error = await socket.receive_json_from(timeout=3)
        message = await socket.receive_output()

        self.assertEqual(error['code'], 'access_expired')
        self.assertEqual(message, {'type': 'websocket.close', 'code': 4003})
        await socket.disconnect()

    async def test_revocation_terminates_open_display_without_leaking_event_payload(self):
        socket = await self.socket()
        await socket.send_json_to({'event': 'auth', 'access_type': 'display', 'token': self.display_secret})
        await socket.receive_json_from()
        def revoke():
            self.grant.revoked_at = timezone.now()
            self.grant.save(update_fields=['revoked_at'])
            broadcast_session_event(self.g.session.pk, 'answer_submitted', {'phone': 'закрыто', 'token': 'закрыто'})
        await database_sync_to_async(revoke)()
        error = await socket.receive_json_from(timeout=2)
        message = await socket.receive_output()
        self.assertEqual(error['code'], 'access_revoked')
        self.assertEqual(message['type'], 'websocket.close')
        self.assertEqual(message['code'], 4003)
        await socket.disconnect()

    async def test_events_are_rebuilt_for_role_instead_of_forwarding_raw_payload(self):
        socket = await self.socket()
        await socket.send_json_to({'event': 'auth', 'access_type': 'participant', 'token': self.g.secret})
        await socket.receive_json_from()
        await database_sync_to_async(broadcast_session_event)(self.g.session.pk, 'answer_submitted', {'phone': 'закрыто', 'score_points': 777, 'token': 'закрыто'})
        message = await socket.receive_json_from()
        self.assertEqual(message['event'], 'answer_submitted')
        self.assertNotIn('закрыто', str(message))
        self.assertNotIn('score_points', message['payload'])
        self.assertTrue(all('is_correct' not in choice for choice in message['payload']['current_question']['choices']))
        await socket.disconnect()

    async def test_message_over_16_kib_has_safe_error_and_1009(self):
        socket = await self.socket()

        await socket.send_to(text_data='я' * 8193)

        error = await socket.receive_json_from()
        close = await socket.receive_output()
        self.assertEqual(error['event'], 'connection_error')
        self.assertEqual(error['code'], 'message_too_large')
        self.assertNotIn('retry_after', error)
        self.assertEqual(close['code'], 1009)
        await socket.disconnect()

    async def test_malformed_json_has_protocol_error_and_4000(self):
        socket = await self.socket()

        await socket.send_to(text_data='{')

        error = await socket.receive_json_from()
        close = await socket.receive_output()
        self.assertEqual(error['code'], 'protocol_error')
        self.assertEqual(close['code'], 4000)
        await socket.disconnect()

    async def test_invalid_access_has_structured_error_and_4003(self):
        socket = await self.socket()

        await socket.send_json_to(
            {'event': 'auth', 'access_type': 'participant', 'token': 'x' * 43}
        )

        error = await socket.receive_json_from()
        close = await socket.receive_output()
        self.assertEqual(error['code'], 'access_invalid')
        self.assertEqual(close['code'], 4003)
        await socket.disconnect()

    @override_settings(WS_LIMITS_ENABLED=True)
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.release')
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.open')
    async def test_open_rate_limit_has_retry_after_and_4429(self, open_lease, release):
        open_lease.return_value = WebSocketLimitDecision(
            allowed=False,
            reason='rate_limited',
            retry_after=2,
        )
        socket = WebsocketCommunicator(
            application,
            f'/ws/sessions/{self.g.session.join_token}/',
        )

        connected, _ = await socket.connect()
        error = await socket.receive_json_from()
        close = await socket.receive_output()

        self.assertTrue(connected)
        self.assertEqual(error['code'], 'rate_limited')
        self.assertEqual(error['retry_after'], 2)
        self.assertEqual(close['code'], 4429)
        release.assert_not_called()
        await socket.disconnect()

    @override_settings(WS_LIMITS_ENABLED=True)
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.release')
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.open')
    async def test_open_redis_failure_has_retry_after_and_4503(self, open_lease, release):
        open_lease.side_effect = LimiterUnavailable('test failure')
        socket = WebsocketCommunicator(
            application,
            f'/ws/sessions/{self.g.session.join_token}/',
        )

        connected, _ = await socket.connect()
        error = await socket.receive_json_from()
        close = await socket.receive_output()

        self.assertTrue(connected)
        self.assertEqual(error['code'], 'limiter_unavailable')
        self.assertEqual(error['retry_after'], 3)
        self.assertEqual(close['code'], 4503)
        release.assert_not_called()
        await socket.disconnect()

    @override_settings(WS_LIMITS_ENABLED=True)
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.release')
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.check_message')
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.open')
    async def test_message_rate_limit_has_retry_after_and_4429(
        self,
        open_lease,
        check_message,
        release,
    ):
        open_lease.return_value = WebSocketLimitDecision(allowed=True)
        check_message.return_value = LimitDecision(allowed=False, retry_after=2)
        socket = WebsocketCommunicator(
            application,
            f'/ws/sessions/{self.g.session.join_token}/',
        )
        connected, _ = await socket.connect()

        await socket.send_json_to(
            {'event': 'auth', 'access_type': 'participant', 'token': self.g.secret}
        )

        error = await socket.receive_json_from()
        close = await socket.receive_output()
        self.assertTrue(connected)
        self.assertEqual(error['code'], 'rate_limited')
        self.assertEqual(error['retry_after'], 2)
        self.assertEqual(close['code'], 4429)
        release.assert_called_once()
        await socket.disconnect()

    @override_settings(WS_LIMITS_ENABLED=True)
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.release')
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.acquire_access')
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.check_message')
    @patch('apps.core.websocket_limits.RedisWebSocketGuard.open')
    async def test_access_connection_limit_closes_new_connection(
        self,
        open_lease,
        check_message,
        acquire_access,
        release,
    ):
        open_lease.return_value = WebSocketLimitDecision(allowed=True)
        check_message.return_value = LimitDecision(allowed=True)
        acquire_access.return_value = WebSocketLimitDecision(
            allowed=False,
            reason='connection_limit',
            retry_after=5,
        )
        socket = WebsocketCommunicator(
            application,
            f'/ws/sessions/{self.g.session.join_token}/',
        )
        connected, _ = await socket.connect()

        await socket.send_json_to(
            {'event': 'auth', 'access_type': 'participant', 'token': self.g.secret}
        )

        error = await socket.receive_json_from()
        close = await socket.receive_output()
        self.assertTrue(connected)
        self.assertEqual(error['code'], 'connection_limit')
        self.assertEqual(error['retry_after'], 5)
        self.assertEqual(close['code'], 4429)
        release.assert_called_once()
        await socket.disconnect()
