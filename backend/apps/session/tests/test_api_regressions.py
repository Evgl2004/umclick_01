from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase
from apps.session.models import ParticipantAnswer
from apps.session.realtime import build_public_leaderboard
from apps.session.tests.helpers import teacher, game, participate, url, quiz_payload


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
        for action in ('next-question', 'reveal-answer'):
            self.assertEqual(self.client.post(url(g.session, action)).status_code, 409)
        self.assertEqual(self.client.post(url(g.session, 'start')).status_code, 200)
        self.assertEqual(self.client.post(url(g.session, 'start')).status_code, 409)
        self.assertEqual(self.client.post(url(g.session, 'reveal-answer')).status_code, 409)
        self.assertEqual(self.client.patch(url(g.session, '').replace('//', '/'), {'status': 'waiting'}).status_code, 405)

    def test_answer_rejects_inactive_session_wrong_question_and_revealed_question(self):
        g = game(self.teacher, active=True)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + g.secret)
        other = g.quiz.questions.last()
        self.assertEqual(self.client.post(url(g.session, 'answer'), {'question_id': other.pk, 'choice_id': other.choices.first().pk}).status_code, 409)
        self.assertEqual(self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': other.choices.first().pk}).status_code, 400)
        g.session.revealed_question_id = g.question.pk
        g.session.save(update_fields=['revealed_question_id'])
        self.assertEqual(self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': g.correct.pk}).status_code, 409)
        g.session.status = 'finished'; g.session.save()
        self.assertEqual(self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': g.correct.pk}).status_code, 409)
        self.assertFalse(ParticipantAnswer.objects.exists())

    def test_public_leaderboard_has_places_without_phone_numbers(self):
        g = game(self.teacher)
        second, _ = participate(g.session, name='Борис')
        g.session.status = 'live'; g.session.save()
        ParticipantAnswer.objects.create(session_participant=g.link, question=g.question, choice=g.correct, is_correct=True, score_points=900)
        ParticipantAnswer.objects.create(session_participant=second, question=g.question, choice=g.correct, is_correct=True, score_points=700)
        rows = build_public_leaderboard(g.session)
        self.assertEqual([row['rank'] for row in rows], [1, 2])
        self.assertEqual([row['points'] for row in rows], [900, 700])
        self.assertTrue(all('phone' not in row for row in rows))
