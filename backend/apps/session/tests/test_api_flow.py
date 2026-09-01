from datetime import timedelta
from django.utils import timezone
from rest_framework.test import APITestCase
from apps.session.access import issue_secret
from apps.session.models import LiveSession, Participant, ParticipantAnswer, SessionDisplayAccess
from apps.session.flow import start_answering_for_current_question
from apps.session.tests.helpers import teacher, game, quiz, participate, url, quiz_payload


class SessionApiFlowTests(APITestCase):
    def setUp(self):
        self.teacher = teacher()

    def authenticate_teacher(self):
        self.client.credentials()
        self.client.force_authenticate(self.teacher)

    def participant_access(self, g):
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + g.secret)

    def display_access(self, g):
        secret, digest = issue_secret('display')
        SessionDisplayAccess.objects.create(session=g.session, token_digest=digest)
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + secret)

    def test_teacher_can_create_quiz_and_live_session(self):
        self.authenticate_teacher()
        response = self.client.post('/api/quizzes/', quiz_payload(), format='json')
        self.assertEqual(response.status_code, 201, response.data)
        session = self.client.post('/api/sessions/', {'quiz': response.data['id']})
        self.assertEqual(session.status_code, 201, session.data)
        self.assertEqual(session.data['status'], 'waiting')
        self.assertEqual(len(session.data['pin']), 6)
        self.assertTrue(session.data['join_token'])

    def test_public_preview_supports_pin_and_token(self):
        g = game(self.teacher)
        for params in ({'pin': g.session.pin}, {'token': str(g.session.join_token)}):
            response = self.client.get('/api/sessions/join/preview/', params)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data['session_uuid'], str(g.session.join_token))
            self.assertTrue(response.data['can_join'])
            self.assertNotIn('current_question', response.data)
            self.assertNotIn('phase', response.data)

    def test_public_preview_marks_finished_session_as_closed(self):
        g = game(self.teacher)
        g.session.status = 'finished'; g.session.save()
        response = self.client.get('/api/sessions/join/preview/', {'token': str(g.session.join_token)})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data['can_join'])

    def test_teacher_finish_marks_live_session_as_aborted(self):
        g = game(self.teacher, active=True)
        self.authenticate_teacher()
        response = self.client.post(url(g.session, 'finish'))
        self.assertEqual(response.status_code, 200, response.data)
        g.session.refresh_from_db()
        self.assertEqual(g.session.status, 'aborted')
        self.assertIsNotNone(g.session.finished_at)

    def test_participant_can_join_by_pin_and_token(self):
        g = game(self.teacher)
        for target in ({'pin': g.session.pin}, {'join_token': str(g.session.join_token)}):
            response = self.client.post('/api/sessions/join/', {**target, 'name': 'Анна'})
            self.assertEqual(response.status_code, 200, response.data)
            self.assertTrue(response.data['participant_token'])

    def test_join_does_not_require_consent(self):
        # Прежнее обязательное согласие отменено согласованным правилом Б1-02.
        g = game(self.teacher)
        response = self.client.post('/api/sessions/join/', {'pin': g.session.pin, 'name': 'Анна'})
        self.assertEqual(response.status_code, 200, response.data)

    def test_participant_can_join_without_phone(self):
        g = game(self.teacher)
        response = self.client.post('/api/sessions/join/', {'pin': g.session.pin, 'name': 'Анна'})
        self.assertEqual(response.status_code, 200)
        self.assertIsNone(Participant.objects.get(session_links__pk=response.data['session_participant_id']).phone)

    def test_live_answer_can_be_changed_before_reveal(self):
        g = game(self.teacher)
        self.authenticate_teacher()
        self.assertEqual(self.client.post(url(g.session, 'start')).status_code, 200)
        self.assertEqual(self.client.post(url(g.session, 'next-question')).status_code, 200)
        g.session.refresh_from_db()
        start_answering_for_current_question(g.session)
        self.participant_access(g)
        for choice in (g.correct, g.wrong):
            response = self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': choice.pk})
            self.assertEqual(response.status_code, 200, response.data)
            self.assertEqual(response.data, {'accepted': True})
        answer = ParticipantAnswer.objects.get(session_participant=g.link, question=g.question)
        self.assertEqual(answer.choice_id, g.wrong.pk)
        self.assertFalse(answer.is_correct)
        self.assertEqual(answer.score_points, 0)

    def test_late_answer_is_rejected_after_question_deadline(self):
        g = game(self.teacher, active=True)
        g.session.question_started_at = timezone.now() - timedelta(seconds=31)
        g.session.save(update_fields=['question_started_at'])
        self.participant_access(g)
        response = self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': g.correct.pk})
        self.assertEqual(response.status_code, 409)
        self.assertFalse(ParticipantAnswer.objects.exists())

    def test_public_session_state_hides_correct_choices(self):
        g = game(self.teacher, active=True)
        self.participant_access(g)
        response = self.client.get(url(g.session, 'participation'))
        self.assertEqual(response.status_code, 200)
        for choice in response.data['state']['current_question']['choices']:
            self.assertNotIn('is_correct', choice)
        self.client.credentials()
        self.assertEqual(self.client.get(url(g.session, 'state')).status_code, 401)

    def test_public_session_state_advances_overdue_answering_phase(self):
        g = game(self.teacher, active=True)
        g.session.question_started_at = timezone.now() - timedelta(seconds=31)
        g.session.save(update_fields=['question_started_at'])
        self.participant_access(g)
        response = self.client.get(url(g.session, 'participation'))
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['state']['phase'], 'results')
        self.assertTrue(response.data['state']['is_answer_revealed'])

    def test_display_state_advances_results_phase_to_next_question(self):
        g = game(self.teacher, active=True)
        g.session.phase = 'results'
        g.session.phase_started_at = timezone.now() - timedelta(seconds=11)
        g.session.save(update_fields=['phase', 'phase_started_at'])
        self.display_access(g)
        response = self.client.get(url(g.session, 'display-state'))
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['phase'], 'reading')
        self.assertEqual(response.data['current_question']['order'], 2)

    def test_display_state_keeps_full_text_when_participant_payload_is_hidden(self):
        g = game(self.teacher, active=True, question_only_on_display=True, show_choices_on_participant=False)
        self.participant_access(g)
        participant = self.client.get(url(g.session, 'participation')).data['state']
        self.assertEqual(participant['current_question']['text'], '')
        self.assertTrue(all(choice['text'] == '' for choice in participant['current_question']['choices']))
        self.display_access(g)
        display = self.client.get(url(g.session, 'display-state')).data
        self.assertEqual(display['display_question']['text'], g.question.text)
        self.assertTrue(all(choice['text'] for choice in display['display_question']['choices']))

    def test_leaderboard_and_csv_export_are_sorted_by_score(self):
        g = game(self.teacher)
        second, _ = participate(g.session, name='Борис')
        g.session.status = 'live'; g.session.save()
        ParticipantAnswer.objects.create(session_participant=g.link, question=g.question, choice=g.wrong, score_points=0)
        ParticipantAnswer.objects.create(session_participant=second, question=g.question, choice=g.correct, is_correct=True, score_points=900)
        self.authenticate_teacher()
        response = self.client.get(url(g.session, 'leaderboard'))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data[0]['participant_name'], 'Борис')
        self.assertEqual(response.data[0]['points'], 900)
        csv = self.client.get(url(g.session, 'results/export'))
        self.assertEqual(csv.status_code, 200)
        self.assertIn('Имя участника,Телефон,Баллы,Правильные ответы', csv.content.decode())
