from unittest.mock import patch

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from rest_framework_simplejwt.tokens import AccessToken

from apps.session.access import issue_secret
from apps.session.consumers import SessionConsumer
from apps.session.models import SessionDisplayAccess
from apps.session.tests.helpers import game, teacher


class WebsocketRevalidationQueryTests(TestCase):
    def setUp(self):
        self.owner = teacher()
        self.game = game(self.owner, active=True)
        display_secret, digest = issue_secret('display')
        SessionDisplayAccess.objects.create(session=self.game.session, token_digest=digest)
        self.credentials = {
            'account': str(AccessToken.for_user(self.owner)),
            'participant': self.game.secret,
            'display': display_secret,
        }

    def consumer(self, kind):
        consumer = SessionConsumer()
        consumer.session_uuid = self.game.session.join_token
        consumer.access_type = kind
        consumer.secret = self.credentials[kind]
        return consumer

    def test_light_revalidation_uses_one_query_without_building_state(self):
        counts = {}
        for kind in ('account', 'participant', 'display'):
            consumer = self.consumer(kind)
            self.assertIsNotNone(consumer._state_if_allowed())
            with CaptureQueriesContext(connection) as queries:
                with patch(
                    'apps.session.consumers.build_account_session_state'
                ) as account_state, patch(
                    'apps.session.consumers.build_participant_session_state'
                ) as participant_state, patch(
                    'apps.session.consumers.build_display_session_state'
                ) as display_state:
                    self.assertTrue(consumer._access_is_allowed())
            account_state.assert_not_called()
            participant_state.assert_not_called()
            display_state.assert_not_called()
            counts[kind] = len(queries)

        print(
            'WS_LIGHT_REVALIDATION '
            + ' '.join(f'{kind}_queries={count}' for kind, count in counts.items())
        )
        self.assertEqual(counts, {'account': 1, 'participant': 1, 'display': 1})

    def test_background_interval_is_between_45_and_75_seconds(self):
        consumer = self.consumer('participant')

        delays = [consumer._access_revalidation_delay() for _ in range(100)]

        self.assertTrue(all(45 <= delay <= 75 for delay in delays))
