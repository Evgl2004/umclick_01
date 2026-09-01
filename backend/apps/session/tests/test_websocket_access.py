from datetime import timedelta
from time import monotonic
from channels.db import database_sync_to_async
from channels.testing import WebsocketCommunicator
from django.test import TransactionTestCase
from django.utils import timezone
from rest_framework_simplejwt.tokens import AccessToken, RefreshToken

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
        message = await socket.receive_output(timeout=11)
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
            self.assertEqual((await socket.receive_output())['code'], 4003)
            await socket.disconnect()

    async def test_invalid_foreign_expired_and_refresh_tokens_are_rejected(self):
        expired = AccessToken.for_user(self.owner)
        expired.set_exp(lifetime=timedelta(seconds=-1))
        cases = [('participant', self.foreign.secret), ('participant', self.display_secret),
                 ('account', str(expired)), ('account', str(RefreshToken.for_user(self.owner))),
                 ('display', 'неверный')]
        for kind, token in cases:
            socket = await self.socket()
            await socket.send_json_to({'event': 'auth', 'access_type': kind, 'token': token})
            self.assertEqual((await socket.receive_output())['code'], 4003)
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
        message = await socket.receive_output(timeout=2)
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
