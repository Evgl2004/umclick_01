import uuid
from datetime import timedelta
from threading import Thread
from unittest.mock import patch

from django.db import close_old_connections
from django.test import TestCase, TransactionTestCase
from rest_framework.test import APIClient

from apps.core.protection import HistoryConflict
from apps.session.advance import advance_session_if_due
from apps.session.gameplay import execute_manual_command
from apps.session.models import AnswerAttempt, FinalAnswer, LiveSession, SessionCommand, SessionQuestionRun
from apps.session.realtime import build_participant_session_state
from apps.session.tests.helpers import command_payload, game, teacher, url


class StageBGameplayTests(TestCase):
    def setUp(self):
        self.owner = teacher()
        self.client = APIClient()
        self.client.force_authenticate(self.owner)
        self.game = game(self.owner)

    def post_command(self, action, payload=None):
        return self.client.post(
            url(self.game.session, action),
            payload or command_payload(self.game.session),
            format='json',
        )

    def start_question(self):
        self.assertEqual(self.post_command('start').status_code, 200)
        self.assertEqual(self.post_command('start-quiz').status_code, 200)
        self.game.session.refresh_from_db()
        return self.game.session.current_run

    def test_session_start_is_separate_and_command_repeat_is_idempotent(self):
        payload = command_payload(self.game.session)
        first = self.post_command('start', payload)
        second = self.post_command('start', payload)
        self.assertEqual(first.status_code, 200, first.data)
        self.assertEqual(second.status_code, 200, second.data)
        self.assertFalse(first.data['repeated'])
        self.assertTrue(second.data['repeated'])
        self.game.session.refresh_from_db()
        self.assertEqual(
            (self.game.session.status, self.game.session.phase, self.game.session.state_revision),
            (LiveSession.STATUS_LIVE, LiveSession.PHASE_LOBBY, 1),
        )
        self.assertIsNone(self.game.session.current_question_id)
        self.assertEqual(SessionCommand.objects.filter(session=self.game.session).count(), 1)

    def test_stale_command_and_reused_identifier_return_conflict_without_transition(self):
        command_id = uuid.uuid4()
        original = command_payload(self.game.session, command_id=command_id)
        self.assertEqual(self.post_command('start', original).status_code, 200)
        reused = {**command_payload(self.game.session), 'command_id': str(command_id)}
        self.assertEqual(self.post_command('start-quiz', reused).status_code, 409)
        stale = {**command_payload(self.game.session), 'state_revision': 0}
        response = self.post_command('start-quiz', stale)
        self.assertEqual(response.status_code, 409)
        rendered = response.json()
        self.assertEqual(rendered['state']['state_revision'], 1)
        self.assertIsInstance(rendered['state']['state_revision'], int)
        self.assertIsNone(rendered['state']['question_id'])
        self.assertIsNone(rendered['state']['question_run_id'])
        self.assertIsNone(rendered['state']['reading_ends_at'])
        self.game.session.refresh_from_db()
        self.assertEqual((self.game.session.phase, self.game.session.state_revision), ('lobby', 1))
        self.assertEqual(SessionCommand.objects.filter(session=self.game.session).count(), 1)

    def test_command_conflict_json_preserves_numeric_identifiers_and_null(self):
        run = self.start_question()
        stale = {**command_payload(self.game.session), 'state_revision': 0}
        response = self.post_command('end-question', stale)
        self.assertEqual(response.status_code, 409)
        state = response.json()['state']
        self.assertIsInstance(state['state_revision'], int)
        self.assertIsInstance(state['question_id'], int)
        self.assertIsInstance(state['question_run_id'], int)
        self.assertEqual(state['question_id'], self.game.question.pk)
        self.assertEqual(state['question_run_id'], run.pk)
        self.assertIsNone(state['results_ends_at'])

    def test_unknown_command_field_is_rejected(self):
        payload = {**command_payload(self.game.session), 'untrusted_context': 'ignored'}
        response = self.post_command('start', payload)
        self.assertEqual(response.status_code, 400)
        self.game.session.refresh_from_db()
        self.assertEqual(self.game.session.state_revision, 0)
        self.assertFalse(SessionCommand.objects.filter(session=self.game.session).exists())

    def test_deadlines_are_saved_once_and_early_finish_keeps_delivery(self):
        run = self.start_question()
        self.assertEqual(run.reading_ends_at - run.reading_started_at, timedelta(seconds=15))
        self.assertEqual(run.planned_answer_deadline_at - run.answering_started_at, timedelta(seconds=30))
        self.assertEqual(run.planned_delivery_deadline_at - run.planned_answer_deadline_at, timedelta(seconds=3))

        _, advanced = advance_session_if_due(self.game.session, now=run.reading_ends_at)
        self.assertTrue(advanced)
        self.game.session.refresh_from_db()
        self.assertEqual(self.game.session.phase, LiveSession.PHASE_ANSWERING)
        _, repeated_advance = advance_session_if_due(self.game.session, now=run.reading_ends_at)
        self.assertFalse(repeated_advance)

        with patch('apps.session.gameplay.database_now', return_value=run.reading_ends_at + timedelta(seconds=1)):
            response = self.post_command('end-question')
        self.assertEqual(response.status_code, 200, response.data)
        run.refresh_from_db()
        self.game.session.refresh_from_db()
        self.assertEqual(self.game.session.phase, LiveSession.PHASE_DELIVERY)
        self.assertLess(run.answer_deadline_at, run.planned_answer_deadline_at)
        self.assertEqual(run.delivery_deadline_at - run.answer_deadline_at, timedelta(seconds=3))
        self.assertEqual(self.post_command('next-question').status_code, 409)
        self.assertEqual(self.client.post(url(self.game.session, 'reveal-answer')).status_code, 404)

    def test_recovery_finalizes_once_and_opens_full_results_period(self):
        run = self.start_question()
        recovery_time = run.delivery_deadline_at + timedelta(seconds=10)
        session, advanced = advance_session_if_due(self.game.session, now=recovery_time)
        self.assertTrue(advanced)
        self.assertEqual(session.phase, LiveSession.PHASE_RESULTS)
        run.refresh_from_db()
        self.assertEqual(run.finalized_at, recovery_time)
        self.assertEqual(run.results_ends_at - run.results_started_at, timedelta(seconds=10))
        self.assertEqual(FinalAnswer.objects.filter(run=run).count(), 1)

        _, second = advance_session_if_due(session, now=recovery_time)
        self.assertFalse(second)
        self.assertEqual(FinalAnswer.objects.filter(run=run).count(), 1)
        self.assertEqual(SessionCommand.objects.filter(session=session, kind='auto_finalize_question').count(), 1)

    def test_natural_cutoff_enters_delivery_and_exact_delivery_boundary_stays_open(self):
        run = self.start_question()
        session, _ = advance_session_if_due(self.game.session, now=run.reading_ends_at)
        session, advanced = advance_session_if_due(session, now=run.answer_deadline_at)
        self.assertTrue(advanced)
        self.assertEqual(session.phase, LiveSession.PHASE_DELIVERY)
        self.assertFalse(FinalAnswer.objects.filter(run=run).exists())
        session, at_boundary = advance_session_if_due(session, now=run.delivery_deadline_at)
        self.assertFalse(at_boundary)
        self.assertEqual(session.phase, LiveSession.PHASE_DELIVERY)
        session, after_boundary = advance_session_if_due(
            session,
            now=run.delivery_deadline_at + timedelta(microseconds=1),
        )
        self.assertTrue(after_boundary)
        self.assertEqual(session.phase, LiveSession.PHASE_RESULTS)

    def test_last_results_finish_naturally_but_stop_is_aborted(self):
        first_run = self.start_question()
        session, _ = advance_session_if_due(
            self.game.session,
            now=first_run.delivery_deadline_at + timedelta(seconds=1),
        )
        self.assertEqual(self.post_command('next-question').status_code, 200)
        self.game.session.refresh_from_db()
        second_run = self.game.session.current_run
        self.assertNotEqual(second_run.pk, first_run.pk)
        session, _ = advance_session_if_due(
            self.game.session,
            now=second_run.delivery_deadline_at + timedelta(seconds=1),
        )
        second_run.refresh_from_db()
        session, advanced = advance_session_if_due(session, now=second_run.results_ends_at)
        self.assertTrue(advanced)
        self.assertEqual((session.status, session.phase), (LiveSession.STATUS_FINISHED, LiveSession.PHASE_FINAL))

        other = game(self.owner)
        payload = command_payload(other.session)
        response = self.client.post(url(other.session, 'finish'), payload, format='json')
        repeat = self.client.post(url(other.session, 'finish'), payload, format='json')
        self.assertEqual((response.status_code, repeat.status_code), (200, 200))
        other.session.refresh_from_db()
        self.assertEqual(other.session.status, LiveSession.STATUS_ABORTED)

    def test_new_sessions_use_stage_b_schema(self):
        self.assertEqual(self.game.session.gameplay_schema, LiveSession.GAMEPLAY_SCHEMA_V2)
        self.assertFalse(SessionQuestionRun.objects.filter(session=self.game.session).exists())

    def test_leaderboard_is_not_available_before_first_finalization(self):
        response = self.client.get(url(self.game.session, 'leaderboard'))
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json(), {'code': 'conflict', 'detail': 'Рейтинг ещё не сформирован.'})
        self.assertNotIn('leaderboard', response.data)


class StageBAnswerTests(TestCase):
    def setUp(self):
        self.owner = teacher()
        self.game = game(self.owner, active=True)
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + self.game.secret)

    def answer(self, choice, *, submission_id=None, question_id=None, extra=None):
        payload = {
            'question_id': question_id or self.game.question.pk,
            'choice_id': choice.pk,
            'submission_id': str(submission_id or uuid.uuid4()),
        }
        payload.update(extra or {})
        return self.client.post(url(self.game.session, 'answer'), payload, format='json')

    def at(self, seconds):
        return self.game.session.current_run.answering_started_at + timedelta(seconds=seconds)

    def test_duplicate_is_idempotent_and_identifier_cannot_change_content(self):
        submission_id = uuid.uuid4()
        with patch('apps.session.gameplay.database_now', return_value=self.at(5)):
            first = self.answer(self.game.correct, submission_id=submission_id)
        saved = AnswerAttempt.objects.get()
        with patch('apps.session.gameplay.database_now', return_value=self.at(8)):
            repeated = self.answer(self.game.correct, submission_id=submission_id)
            conflict = self.answer(self.game.wrong, submission_id=submission_id)
        self.assertEqual((first.status_code, repeated.status_code, conflict.status_code), (200, 200, 409))
        expected = {'accepted': True, 'message': 'Ответ зафиксирован'}
        self.assertEqual(first.data, expected)
        self.assertEqual(repeated.data, expected)
        self.assertEqual(AnswerAttempt.objects.count(), 1)
        self.assertEqual(AnswerAttempt.objects.get().admitted_at, saved.admitted_at)

    def test_twenty_first_unique_attempt_is_neutral_without_new_row(self):
        with (
            patch('apps.session.gameplay.database_now', return_value=self.at(5)),
            patch('apps.session.realtime.broadcast_session_event') as broadcast,
        ):
            responses = [self.answer(self.game.correct) for _ in range(21)]
        self.assertTrue(all(response.status_code == 200 for response in responses))
        self.assertTrue(all(response.data == {'accepted': True, 'message': 'Ответ зафиксирован'} for response in responses))
        self.assertEqual(AnswerAttempt.objects.count(), 20)
        self.assertEqual(list(AnswerAttempt.objects.order_by('ordinal').values_list('ordinal', flat=True)), list(range(1, 21)))
        self.assertEqual(broadcast.call_count, 20)

    def test_run_identifier_is_not_accepted_from_client(self):
        response = self.answer(
            self.game.correct,
            extra={'run_id': self.game.session.current_run_id},
        )
        self.assertEqual(response.status_code, 400)
        self.assertFalse(AnswerAttempt.objects.exists())

    def test_client_time_is_not_accepted(self):
        response = self.answer(
            self.game.correct,
            extra={'client_timestamp': self.at(1).isoformat()},
        )
        self.assertEqual(response.status_code, 400)
        self.assertFalse(AnswerAttempt.objects.exists())

    def test_question_during_reading_is_not_open_for_attempts(self):
        self.game.session.phase = LiveSession.PHASE_READING
        self.game.session.save(update_fields=['phase'])
        response = self.answer(self.game.correct)
        self.assertEqual(response.status_code, 409)
        self.assertFalse(AnswerAttempt.objects.exists())

    def test_consecutive_repeat_keeps_first_timing_attempt(self):
        for seconds in (5, 8):
            with patch('apps.session.gameplay.database_now', return_value=self.at(seconds)):
                self.assertEqual(self.answer(self.game.correct).status_code, 200)
        run = self.game.session.current_run
        advance_session_if_due(self.game.session, now=run.delivery_deadline_at + timedelta(microseconds=1))
        final = FinalAnswer.objects.get(run=run, session_participant=self.game.link)
        attempts = list(AnswerAttempt.objects.order_by('admitted_at', 'id'))
        self.assertEqual(final.selected_attempt_id, attempts[1].pk)
        self.assertEqual(final.timing_attempt_id, attempts[0].pk)
        self.assertEqual((final.actual_elapsed_ms, final.ranking_elapsed_ms), (5000, 5000))

    def test_real_change_resets_timing_and_delivery_time_is_capped(self):
        sequence = ((5, self.game.correct), (6, self.game.wrong), (32, self.game.correct))
        for seconds, choice in sequence:
            with patch('apps.session.gameplay.database_now', return_value=self.at(seconds)):
                self.assertEqual(self.answer(choice).status_code, 200)
        run = self.game.session.current_run
        advance_session_if_due(self.game.session, now=run.delivery_deadline_at + timedelta(microseconds=1))
        final = FinalAnswer.objects.get(run=run, session_participant=self.game.link)
        attempts = list(AnswerAttempt.objects.order_by('admitted_at', 'id'))
        self.assertEqual((final.selected_attempt_id, final.timing_attempt_id), (attempts[2].pk, attempts[2].pk))
        self.assertEqual((final.actual_elapsed_ms, final.ranking_elapsed_ms), (32000, 30000))

    def test_delivery_boundary_is_inclusive_and_later_attempt_does_not_change_final(self):
        run = self.game.session.current_run
        expected = {'accepted': True, 'message': 'Ответ зафиксирован'}
        with patch('apps.session.gameplay.database_now', return_value=run.delivery_deadline_at):
            admitted = self.answer(self.game.correct)
        with patch('apps.session.gameplay.database_now', return_value=run.delivery_deadline_at + timedelta(microseconds=1)):
            late = self.answer(self.game.wrong)
        self.assertEqual(admitted.data, expected)
        self.assertEqual(late.data, expected)
        advance_session_if_due(self.game.session, now=run.delivery_deadline_at + timedelta(seconds=1))
        final = FinalAnswer.objects.get(run=run, session_participant=self.game.link)
        self.assertEqual(final.selected_attempt.choice_id, self.game.correct.pk)
        self.assertTrue(final.is_correct)
        self.assertEqual(AnswerAttempt.objects.filter(run=run).count(), 2)
        with patch('apps.session.gameplay.database_now', return_value=run.delivery_deadline_at + timedelta(seconds=2)):
            after_finalization = self.answer(self.game.wrong)
        self.assertEqual(after_finalization.data, expected)
        state = build_participant_session_state(
            LiveSession.objects.select_related(
                'quiz_version', 'quiz_version__quiz', 'current_question', 'current_run'
            ).get(pk=self.game.session.pk),
            self.game.link.pk,
        )
        self.assertEqual(state['answer']['selected_choice_id'], self.game.correct.pk)
        self.assertEqual(state['answer']['answer_version'], 3)
        self.assertEqual(AnswerAttempt.objects.filter(run=run).count(), 3)
        with self.assertRaises(HistoryConflict):
            final.ranking_elapsed_ms = 1
            final.save()

    def test_early_cutoff_uses_its_own_inclusive_three_second_boundary(self):
        cutoff = self.at(10)
        payload = command_payload(self.game.session)
        payload['command_id'] = uuid.UUID(payload['command_id'])
        with patch('apps.session.gameplay.database_now', return_value=cutoff):
            execute_manual_command(self.game.session.pk, 'end_question', payload)
        run = self.game.session.current_run
        run.refresh_from_db()
        self.assertEqual(run.answer_deadline_at, cutoff)
        self.assertEqual(run.delivery_deadline_at, cutoff + timedelta(seconds=3))

        with patch('apps.session.gameplay.database_now', return_value=run.delivery_deadline_at):
            self.assertEqual(self.answer(self.game.correct).status_code, 200)
        with patch('apps.session.gameplay.database_now', return_value=run.delivery_deadline_at + timedelta(microseconds=1)):
            self.assertEqual(self.answer(self.game.wrong).status_code, 200)
        advance_session_if_due(self.game.session, now=run.delivery_deadline_at + timedelta(seconds=1))
        final = FinalAnswer.objects.get(run=run, session_participant=self.game.link)
        self.assertEqual(final.selected_attempt.choice_id, self.game.correct.pk)
        self.assertEqual((final.actual_elapsed_ms, final.ranking_elapsed_ms), (13000, 10000))


class StageBParticipantSnapshotConcurrencyTests(TransactionTestCase):
    def setUp(self):
        self.owner = teacher('snapshot-teacher')
        self.game = game(self.owner, active=True)
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + self.game.secret)

    def answer(self, choice, *, admitted_at):
        with patch('apps.session.gameplay.database_now', return_value=admitted_at):
            return self.client.post(
                url(self.game.session, 'answer'),
                {
                    'question_id': self.game.question.pk,
                    'choice_id': choice.pk,
                    'submission_id': str(uuid.uuid4()),
                },
                format='json',
            )

    def test_choice_and_version_come_from_the_same_materialized_attempts(self):
        started_at = self.game.session.current_run.answering_started_at
        first = self.answer(
            self.game.correct,
            admitted_at=started_at + timedelta(seconds=1),
        )
        self.assertEqual(first.status_code, 200)

        from apps.session import realtime

        original = realtime._materialize_participant_attempts
        writer_errors = []

        def materialize_then_insert(run_id, participation_id):
            rows = original(run_id, participation_id)

            def insert_later_attempt():
                close_old_connections()
                try:
                    AnswerAttempt.objects.create(
                        run_id=run_id,
                        session_participant_id=participation_id,
                        choice=self.game.wrong,
                        submission_id=uuid.uuid4(),
                        payload_digest='a' * 64,
                        admitted_at=started_at + timedelta(seconds=2),
                        ordinal=2,
                    )
                except Exception as error:  # pragma: no cover - surfaced below
                    writer_errors.append(error)
                finally:
                    close_old_connections()

            writer = Thread(target=insert_later_attempt)
            writer.start()
            writer.join(timeout=5)
            self.assertFalse(writer.is_alive())
            return rows

        session = LiveSession.objects.select_related(
            'quiz_version',
            'quiz_version__quiz',
            'current_question',
            'current_run',
        ).get(pk=self.game.session.pk)
        with patch(
            'apps.session.realtime._materialize_participant_attempts',
            side_effect=materialize_then_insert,
        ):
            concurrent_state = build_participant_session_state(
                session,
                self.game.link.pk,
            )

        self.assertEqual(writer_errors, [])
        self.assertEqual(
            (
                concurrent_state['answer']['selected_choice_id'],
                concurrent_state['answer']['answer_version'],
            ),
            (self.game.correct.pk, 1),
        )
        fresh_state = build_participant_session_state(session, self.game.link.pk)
        self.assertEqual(
            (
                fresh_state['answer']['selected_choice_id'],
                fresh_state['answer']['answer_version'],
            ),
            (self.game.wrong.pk, 2),
        )
