from unittest.mock import patch

from django.test import override_settings
from rest_framework.test import APITestCase

from apps.core.rate_limit import LimitDecision, LimiterUnavailable
from apps.session.access import issue_secret
from apps.session.models import AnswerAttempt, SessionDisplayAccess, SessionParticipant
from apps.session.tests.helpers import game, teacher, url


@override_settings(
    RATE_LIMITS_ENABLED=True,
    RATE_LIMIT_NAMESPACE='umclick:test:http',
    RATE_LIMIT_HMAC_SECRET='test-only-secret',
)
class StageVHttpRateLimitTests(APITestCase):
    def setUp(self):
        self.owner = teacher()
        self.game = game(self.owner, active=True)

    @staticmethod
    def signature(mock):
        limits = mock.call_args.args[0]
        return [
            (
                item.operation,
                item.refill_units_per_ms,
                item.capacity_operations,
            )
            for item in limits
        ]

    @patch('apps.core.rate_limit.RedisRateLimiter.check')
    def test_login_uses_normalized_name_and_ip_atomically_and_returns_429(self, check):
        check.return_value = LimitDecision(allowed=False, retry_after=2)

        response = self.client.post(
            '/api/auth/token/',
            {'username': 'Ｔｅａｃｈｅｒ', 'password': 'irrelevant'},
            format='json',
            REMOTE_ADDR='203.0.113.10',
        )

        self.assertEqual(response.status_code, 429)
        self.assertEqual(response['Retry-After'], '2')
        self.assertEqual(response.data['code'], 'rate_limited')
        self.assertEqual(response.data['retry_after'], 2)
        self.assertEqual(
            self.signature(check),
            [('login_name', 10, 10), ('login_ip', 60, 30)],
        )
        limits = check.call_args.args[0]
        self.assertEqual(limits[0].subject, 'Teacher')
        self.assertEqual(limits[1].subject, '203.0.113.10')

    @patch('apps.core.rate_limit.RedisRateLimiter.check')
    def test_join_pin_and_creation_are_one_decision(self, check):
        check.return_value = LimitDecision(allowed=False, retry_after=1)
        before = SessionParticipant.objects.count()

        response = self.client.post(
            '/api/sessions/join/',
            {'pin': self.game.session.pin, 'name': 'Новый участник'},
            format='json',
            REMOTE_ADDR='203.0.113.11',
        )

        self.assertEqual(response.status_code, 429)
        self.assertEqual(
            self.signature(check),
            [('join_pin', 60, 120), ('join_create', 60, 60)],
        )
        self.assertEqual(SessionParticipant.objects.count(), before)

    @patch('apps.core.rate_limit.RedisRateLimiter.check')
    def test_join_restore_uses_pin_and_confirmed_state_but_not_creation(self, check):
        check.return_value = LimitDecision(allowed=False, retry_after=1)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + self.game.secret)

        response = self.client.post(
            '/api/sessions/join/',
            {'pin': self.game.session.pin},
            format='json',
            REMOTE_ADDR='203.0.113.12',
        )

        self.assertEqual(response.status_code, 429)
        self.assertEqual(
            self.signature(check),
            [('join_pin', 60, 120), ('state', 300, 20)],
        )

    @patch('apps.core.rate_limit.RedisRateLimiter.check')
    def test_preview_by_pin_is_limited_but_preview_by_uuid_is_not(self, check):
        check.return_value = LimitDecision(allowed=False, retry_after=1)

        pin_response = self.client.get(
            '/api/sessions/join/preview/',
            {'pin': self.game.session.pin},
            REMOTE_ADDR='203.0.113.13',
        )

        self.assertEqual(pin_response.status_code, 429)
        self.assertEqual(self.signature(check), [('join_pin', 60, 120)])

        check.reset_mock()
        uuid_response = self.client.get(
            '/api/sessions/join/preview/',
            {'join_token': str(self.game.session.join_token)},
            REMOTE_ADDR='203.0.113.13',
        )
        self.assertEqual(uuid_response.status_code, 200)
        check.assert_not_called()

    @patch('apps.core.rate_limit.RedisRateLimiter.check')
    def test_all_teacher_commands_use_the_command_quota(self, check):
        check.return_value = LimitDecision(allowed=False, retry_after=1)
        self.client.force_authenticate(self.owner)

        for action in ('start', 'start-quiz', 'end-question', 'finish', 'next-question'):
            with self.subTest(action=action):
                response = self.client.post(url(self.game.session, action), {}, format='json')
                self.assertEqual(response.status_code, 429)
                self.assertEqual(self.signature(check), [('command', 120, 10)])
                check.reset_mock()

    @patch('apps.core.rate_limit.RedisRateLimiter.check')
    def test_each_confirmed_state_route_uses_the_state_quota(self, check):
        check.return_value = LimitDecision(allowed=False, retry_after=1)

        self.client.force_authenticate(self.owner)
        account = self.client.get(url(self.game.session, 'state'))
        self.assertEqual(account.status_code, 429)
        self.assertEqual(self.signature(check), [('state', 300, 20)])

        check.reset_mock()
        self.client.force_authenticate(user=None)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + self.game.secret)
        participant = self.client.get(url(self.game.session, 'participation'))
        self.assertEqual(participant.status_code, 429)
        self.assertEqual(self.signature(check), [('state', 300, 20)])

        check.reset_mock()
        display_secret, digest = issue_secret('display')
        SessionDisplayAccess.objects.create(session=self.game.session, token_digest=digest)
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + display_secret)
        display = self.client.get(url(self.game.session, 'display-state'))
        self.assertEqual(display.status_code, 429)
        self.assertEqual(self.signature(check), [('state', 300, 20)])

    @patch('apps.core.rate_limit.RedisRateLimiter.check')
    def test_answer_fails_closed_with_structured_503_before_writing(self, check):
        check.side_effect = LimiterUnavailable('test failure')
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + self.game.secret)

        response = self.client.post(url(self.game.session, 'answer'), {}, format='json')

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response['Retry-After'], '3')
        self.assertEqual(response.data['code'], 'limiter_unavailable')
        self.assertEqual(response.data['retry_after'], 3)
        self.assertEqual(self.signature(check), [('answer', 600, 40)])
        self.assertEqual(AnswerAttempt.objects.count(), 0)
