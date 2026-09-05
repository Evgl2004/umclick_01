from datetime import timedelta

from django.utils import timezone
from rest_framework.test import APITestCase

from apps.session.access import issue_secret
from apps.session.models import LiveSession, SessionDisplayAccess
from apps.session.tests.helpers import command_payload, game, teacher, url


class StageVErrorContractTests(APITestCase):
    def setUp(self):
        self.owner = teacher()
        self.game = game(self.owner)

    def test_state_conflict_contains_code_and_current_state(self):
        self.client.force_authenticate(self.owner)

        response = self.client.post(
            url(self.game.session, 'next-question'),
            command_payload(self.game.session),
            format='json',
        )

        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.data['code'], 'state_conflict')
        self.assertEqual(response.data['state']['schema_version'], 2)
        self.assertEqual(response.data['state']['session_id'], str(self.game.session.join_token))
        self.assertEqual(response.data['state']['state_revision'], self.game.session.state_revision)

    def test_ordinary_conflict_contains_code_without_state(self):
        self.client.force_authenticate(self.owner)

        response = self.client.get(url(self.game.session, 'leaderboard'))

        self.assertEqual(response.status_code, 409)
        self.assertEqual(
            response.data,
            {'code': 'conflict', 'detail': 'Рейтинг ещё не сформирован.'},
        )
        self.assertNotIn('state', response.data)

    def test_access_required_malformed_scope_and_invalid_are_distinct(self):
        endpoint = url(self.game.session, 'participation')

        missing = self.client.get(endpoint)
        self.client.credentials(HTTP_AUTHORIZATION='Participant')
        malformed = self.client.get(endpoint)

        display_secret, digest = issue_secret('display')
        SessionDisplayAccess.objects.create(session=self.game.session, token_digest=digest)
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + display_secret)
        wrong_scope = self.client.get(endpoint)

        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + ('x' * 43))
        invalid = self.client.get(endpoint)

        self.assertEqual((missing.status_code, malformed.status_code, wrong_scope.status_code, invalid.status_code), (401, 401, 401, 401))
        self.assertEqual(missing.data['code'], 'access_required')
        self.assertEqual(malformed.data['code'], 'access_malformed')
        self.assertEqual(wrong_scope.data['code'], 'access_scope_mismatch')
        self.assertEqual(invalid.data['code'], 'access_invalid')

    def test_revoked_and_expired_display_access_are_distinct(self):
        revoked_secret, revoked_digest = issue_secret('display')
        revoked = SessionDisplayAccess.objects.create(
            session=self.game.session,
            token_digest=revoked_digest,
        )
        revoked.revoked_at = timezone.now()
        revoked.save(update_fields=['revoked_at'])

        expired_game = game(self.owner)
        expired_game.session.status = LiveSession.STATUS_FINISHED
        expired_game.session.phase = LiveSession.PHASE_FINAL
        expired_game.session.finished_at = timezone.now() - timedelta(hours=1)
        expired_game.session.save()
        expired_secret, expired_digest = issue_secret('display')
        SessionDisplayAccess.objects.create(
            session=expired_game.session,
            token_digest=expired_digest,
        )

        self.client.credentials(HTTP_AUTHORIZATION='Display ' + revoked_secret)
        revoked_response = self.client.get(url(self.game.session, 'display-state'))
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + expired_secret)
        expired_response = self.client.get(url(expired_game.session, 'display-state'))

        self.assertEqual((revoked_response.status_code, expired_response.status_code), (401, 401))
        self.assertEqual(revoked_response.data['code'], 'access_revoked')
        self.assertEqual(expired_response.data['code'], 'access_expired')
