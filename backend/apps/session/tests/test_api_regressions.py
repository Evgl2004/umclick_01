from django.contrib.auth import get_user_model
import uuid
from rest_framework.test import APITestCase
from apps.session.advance import advance_session_if_due
from apps.session.gameplay import record_answer_attempt
from apps.session.models import AnswerAttempt
from apps.session.realtime import build_public_leaderboard
from apps.session.tests.helpers import activate_gameplay, command_payload, teacher, game, participate, url, quiz_payload
from datetime import timedelta
from unittest.mock import patch


class SessionApiRegressionTests(APITestCase):
    def setUp(self):
        self.teacher = teacher()
        self.student = get_user_model().objects.create_user(username='student', password='test-password-123')

    def test_teacher_api_rejects_unauthenticated_and_non_teacher_users(self):
        self.assertEqual(self.client.post('/api/quizzes/', quiz_payload(), format='json').status_code, 401)
        self.client.force_authenticate(self.student)
        self.assertEqual(self.client.post('/api/quizzes/', quiz_payload(), format='json').status_code, 403)
        self.client.force_authenticate(self.teacher)
        self.assertEqual(self.client.post('/api/quizzes/', quiz_payload(), format='json').status_code, 201)

    def test_join_preview_rejects_missing_or_unknown_join_target(self):
        self.assertEqual(self.client.get('/api/sessions/join/preview/').status_code, 400)
        self.assertEqual(self.client.get('/api/sessions/join/preview/', {'pin': '000000'}).status_code, 404)
        self.assertEqual(self.client.get('/api/sessions/join/preview/', {'token': 'не UUID'}).status_code, 400)

    def test_join_rejects_finished_session_and_missing_join_target(self):
        g = game(self.teacher)
        g.session.status = 'finished'; g.session.save()
        self.assertEqual(self.client.post('/api/sessions/join/', {'join_token': str(g.session.join_token), 'name': 'Имя'}).status_code, 409)
        self.assertEqual(self.client.post('/api/sessions/join/', {'name': 'Имя'}).status_code, 400)

    def test_round_controls_reject_invalid_session_states(self):
        g = game(self.teacher)
        self.client.force_authenticate(self.teacher)
        self.assertEqual(
            self.client.post(url(g.session, 'next-question'), command_payload(g.session), format='json').status_code,
            409,
        )
        self.assertEqual(self.client.post(url(g.session, 'reveal-answer')).status_code, 404)
        first = command_payload(g.session)
        self.assertEqual(self.client.post(url(g.session, 'start'), first, format='json').status_code, 200)
        self.assertEqual(self.client.post(url(g.session, 'start'), first, format='json').status_code, 200)
        self.assertEqual(self.client.post(url(g.session, 'start'), command_payload(g.session), format='json').status_code, 409)
        self.assertEqual(self.client.post(url(g.session, 'reveal-answer')).status_code, 404)
        self.assertEqual(self.client.patch(url(g.session, '').replace('//', '/'), {'status': 'waiting'}).status_code, 405)

    def test_answer_rejects_inactive_session_wrong_question_and_revealed_question(self):
        g = game(self.teacher, active=True)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + g.secret)
        other = g.version.questions.last()
        self.assertEqual(self.client.post(url(g.session, 'answer'), {'question_id': other.pk, 'choice_id': other.choices.first().pk, 'submission_id': str(uuid.uuid4())}).status_code, 409)
        self.assertEqual(self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': other.choices.first().pk, 'submission_id': str(uuid.uuid4())}).status_code, 400)
        g.session.revealed_question_id = g.question.pk
        g.session.save(update_fields=['revealed_question_id'])
        self.assertEqual(self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': g.correct.pk, 'submission_id': str(uuid.uuid4())}).status_code, 200)
        g.session.status = 'finished'; g.session.save()
        self.assertEqual(self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': g.correct.pk, 'submission_id': str(uuid.uuid4())}).status_code, 409)
        self.assertEqual(AnswerAttempt.objects.count(), 1)

    def test_public_leaderboard_has_places_without_phone_numbers(self):
        g = game(self.teacher)
        second, _ = participate(g.session, name='Борис')
        run = activate_gameplay(g.session, g.question)
        for participation in (g.link, second):
            with patch('apps.session.gameplay.database_now', return_value=run.answering_started_at + timedelta(seconds=5)):
                record_answer_attempt(session_id=g.session.pk, participation_id=participation.pk,
                                      question_id=g.question.pk, choice_id=g.correct.pk, submission_id=uuid.uuid4())
        advance_session_if_due(g.session, now=run.delivery_deadline_at + timedelta(seconds=1))
        rows = build_public_leaderboard(g.session)
        self.assertEqual([row['rank'] for row in rows], [1, 1])
        self.assertEqual([row['correct_time_ms'] for row in rows], [5000, 5000])
        self.assertTrue(all('points' not in row for row in rows))
        self.assertTrue(all('phone' not in row for row in rows))
