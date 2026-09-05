from datetime import timedelta
from unittest.mock import AsyncMock, patch
import uuid
from django.utils import timezone
from rest_framework.test import APITestCase
from apps.session.access import issue_secret
from apps.session.gameplay import record_answer_attempt
from apps.session.models import AnswerAttempt, LiveSession, Participant, SessionDisplayAccess
from apps.session.advance import advance_session_if_due
from apps.session.tests.helpers import activate_gameplay, command_payload, teacher, game, quiz, participate, url, quiz_payload


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
        response = self.client.post(url(g.session, 'finish'), command_payload(g.session), format='json')
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
            self.assertEqual(response.data['state']['schema_version'], 2)
            self.assertEqual(response.data['state']['session_id'], str(g.session.join_token))
            self.assertEqual(response.data['state']['phase'], 'lobby')

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

    def test_live_answers_are_saved_as_immutable_attempts(self):
        g = game(self.teacher)
        self.authenticate_teacher()
        self.assertEqual(self.client.post(url(g.session, 'start'), command_payload(g.session), format='json').status_code, 200)
        self.assertEqual(self.client.post(url(g.session, 'start-quiz'), command_payload(g.session), format='json').status_code, 200)
        g.session.refresh_from_db()
        advance_session_if_due(g.session, now=g.session.current_run.reading_ends_at)
        self.participant_access(g)
        for choice in (g.correct, g.wrong):
            response = self.client.post(
                url(g.session, 'answer'),
                {'question_id': g.question.pk, 'choice_id': choice.pk, 'submission_id': str(uuid.uuid4())},
            )
            self.assertEqual(response.status_code, 200, response.data)
            self.assertEqual(response.data, {'accepted': True, 'message': 'Ответ зафиксирован'})
        attempts = list(AnswerAttempt.objects.filter(session_participant=g.link).order_by('ordinal'))
        self.assertEqual([item.choice_id for item in attempts], [g.correct.pk, g.wrong.pk])
        self.assertEqual([item.ordinal for item in attempts], [1, 2])

    def test_late_answer_is_neutral_and_saved_for_audit(self):
        g = game(self.teacher, active=True)
        self.participant_access(g)
        with patch('apps.session.gameplay.database_now', return_value=g.session.current_run.delivery_deadline_at + timedelta(microseconds=1)):
            response = self.client.post(
                url(g.session, 'answer'),
                {'question_id': g.question.pk, 'choice_id': g.correct.pk, 'submission_id': str(uuid.uuid4())},
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(AnswerAttempt.objects.filter(session_participant=g.link).count(), 1)

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
        self.participant_access(g)
        with patch('apps.session.gameplay.database_now', return_value=g.session.current_run.delivery_deadline_at + timedelta(seconds=1)):
            response = self.client.get(url(g.session, 'participation'))
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['state']['phase'], 'results')
        self.assertTrue(response.data['state']['is_answer_revealed'])

    def test_display_state_advances_results_phase_to_next_question(self):
        g = game(self.teacher, active=True)
        advance_session_if_due(g.session, now=g.session.current_run.delivery_deadline_at + timedelta(seconds=1))
        g.session.refresh_from_db()
        g.session.current_run.refresh_from_db()
        self.display_access(g)
        with patch('apps.session.gameplay.database_now', return_value=g.session.current_run.results_ends_at):
            response = self.client.get(url(g.session, 'display-state'))
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['phase'], 'reading')
        self.assertEqual(response.data['display_question']['order'], 2)

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

    def test_new_display_grant_revokes_previous_and_delete_is_idempotent(self):
        g = game(self.teacher)
        self.authenticate_teacher()
        first = self.client.post(url(g.session, 'display-access'))
        second = self.client.post(url(g.session, 'display-access'))

        self.assertEqual((first.status_code, second.status_code), (201, 201))
        first_grant = SessionDisplayAccess.objects.get(pk=first.data['id'])
        second_grant = SessionDisplayAccess.objects.get(pk=second.data['id'])
        self.assertIsNotNone(first_grant.revoked_at)
        self.assertIsNone(second_grant.revoked_at)

        first_delete = self.client.delete(
            url(g.session, f'display-access/{first_grant.pk}'),
        )
        repeated_delete = self.client.delete(
            url(g.session, f'display-access/{first_grant.pk}'),
        )
        self.assertEqual(
            (first_delete.status_code, repeated_delete.status_code),
            (204, 204),
        )
        second_grant.refresh_from_db()
        self.assertIsNone(second_grant.revoked_at)

    def test_display_replacement_broadcast_is_deferred_until_commit(self):
        g = game(self.teacher)
        self.authenticate_teacher()
        self.assertEqual(
            self.client.post(url(g.session, 'display-access')).status_code,
            201,
        )
        layer = type('Layer', (), {'group_send': AsyncMock()})()

        with patch('apps.session.realtime.get_channel_layer', return_value=layer):
            with self.captureOnCommitCallbacks(execute=True) as callbacks:
                replacement = self.client.post(url(g.session, 'display-access'))
                self.assertEqual(replacement.status_code, 201)
                self.assertEqual(layer.group_send.await_count, 0)

            self.assertEqual(len(callbacks), 1)
            self.assertEqual(layer.group_send.await_count, 3)

    def test_leaderboard_and_csv_export_use_correct_finals_without_points(self):
        g = game(self.teacher)
        second, _ = participate(g.session, name='Борис')
        run = activate_gameplay(g.session, g.question)
        with patch('apps.session.gameplay.database_now', return_value=run.answering_started_at + timedelta(seconds=2)):
            record_answer_attempt(session_id=g.session.pk, participation_id=g.link.pk, question_id=g.question.pk,
                                  choice_id=g.wrong.pk, submission_id=uuid.uuid4())
        with patch('apps.session.gameplay.database_now', return_value=run.answering_started_at + timedelta(seconds=5)):
            record_answer_attempt(session_id=g.session.pk, participation_id=second.pk, question_id=g.question.pk,
                                  choice_id=g.correct.pk, submission_id=uuid.uuid4())
        advance_session_if_due(g.session, now=run.delivery_deadline_at + timedelta(seconds=1))
        self.authenticate_teacher()
        response = self.client.get(url(g.session, 'leaderboard'))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data[0]['participant_name'], 'Борис')
        self.assertEqual(response.data[0]['correct_answers'], 1)
        self.assertEqual(response.data[0]['correct_time_ms'], 5000)
        self.assertNotIn('points', response.data[0])
        csv = self.client.get(url(g.session, 'results/export'))
        self.assertEqual(csv.status_code, 200)
        csv_text = csv.content.decode()
        self.assertIn('Сумма времени правильных ответов, мс', csv_text)
        self.assertNotIn('Баллы', csv_text)
