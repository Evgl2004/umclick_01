import uuid
from datetime import timedelta
from unittest.mock import patch

from django.test import TestCase, TransactionTestCase
from rest_framework.test import APIClient

from apps.session.advance import advance_session_if_due
from apps.session.gameplay import record_answer_attempt
from apps.session.models import AnswerAttempt, FinalAnswer, LiveSession
from apps.session.realtime import (
    broadcast_session_event,
    build_account_session_state,
    build_display_session_state,
    build_participant_session_state,
)
from apps.session.tests.helpers import activate_gameplay, game, participate, teacher, url


class StageBRoleSafetyTests(TestCase):
    def setUp(self):
        self.owner = teacher()
        self.game = game(self.owner)
        self.second, _ = participate(self.game.session, name='Второй')
        self.run = activate_gameplay(self.game.session, self.game.question)
        with patch(
            'apps.session.gameplay.database_now',
            return_value=self.run.answering_started_at + timedelta(seconds=5),
        ):
            record_answer_attempt(
                session_id=self.game.session.pk,
                participation_id=self.game.link.pk,
                question_id=self.game.question.pk,
                choice_id=self.game.correct.pk,
                submission_id=uuid.uuid4(),
            )
        self.game.session.refresh_from_db()

    def test_pre_result_snapshots_do_not_reveal_correctness_or_other_choice(self):
        account = build_account_session_state(self.game.session)
        participant = build_participant_session_state(self.game.session, self.game.link.pk)
        other = build_participant_session_state(self.game.session, self.second.pk)
        display = build_display_session_state(self.game.session)

        self.assertNotIn('choices', account['current_question'])
        self.assertEqual(account['answered_participants_count'], 1)
        self.assertNotIn('reveal', account)
        self.assertEqual(participant['answer']['selected_choice_id'], self.game.correct.pk)
        self.assertNotIn('final', participant['answer'])
        self.assertEqual(other['answer'], {'has_answer': False, 'selected_choice_id': None})
        self.assertNotIn('reveal', participant)
        self.assertNotIn('leaderboard', participant)
        self.assertTrue(all('is_correct' not in choice for choice in participant['current_question']['choices']))
        self.assertNotIn('reveal', display)
        self.assertTrue(all('is_correct' not in choice for choice in display['display_question']['choices']))

    def test_post_finalization_snapshots_use_saved_final_only(self):
        advance_session_if_due(
            self.game.session,
            now=self.run.delivery_deadline_at + timedelta(microseconds=1),
        )
        self.game.session.refresh_from_db()
        participant = build_participant_session_state(self.game.session, self.game.link.pk)
        account = build_account_session_state(self.game.session)
        display = build_display_session_state(self.game.session)
        self.assertTrue(participant['answer']['final']['is_correct'])
        self.assertEqual(participant['answer']['final']['ranking_elapsed_ms'], 5000)
        self.assertIn('reveal', participant)
        self.assertIn('reveal', account)
        self.assertIn('reveal', display)
        self.assertTrue(any(choice['is_correct'] for choice in display['reveal']['choices']))
        self.assertTrue(all('points' not in row for row in participant['reveal']['leaderboard']))

    def test_late_audit_attempt_does_not_change_closed_aggregates(self):
        advance_session_if_due(
            self.game.session,
            now=self.run.delivery_deadline_at + timedelta(microseconds=1),
        )
        self.game.session.refresh_from_db()
        before_account = build_account_session_state(self.game.session)
        before_display = build_display_session_state(self.game.session)
        second_final = FinalAnswer.objects.get(run=self.run, session_participant=self.second)
        self.assertEqual(second_final.outcome, FinalAnswer.OUTCOME_UNANSWERED)

        with patch(
            'apps.session.gameplay.database_now',
            return_value=self.run.delivery_deadline_at + timedelta(seconds=1),
        ):
            attempt, repeated = record_answer_attempt(
                session_id=self.game.session.pk,
                participation_id=self.second.pk,
                question_id=self.game.question.pk,
                choice_id=self.game.wrong.pk,
                submission_id=uuid.uuid4(),
            )

        self.assertIsNotNone(attempt)
        self.assertFalse(repeated)
        second_final.refresh_from_db()
        self.assertEqual(second_final.outcome, FinalAnswer.OUTCOME_UNANSWERED)
        self.assertIsNone(second_final.selected_attempt_id)
        after_account = build_account_session_state(self.game.session)
        after_display = build_display_session_state(self.game.session)
        self.assertEqual(after_account['answered_participants_count'], 1)
        self.assertEqual(after_account['reveal'], before_account['reveal'])
        self.assertEqual(after_display['reveal'], before_display['reveal'])

    def test_finalization_failure_rolls_back_every_partial_row_and_state(self):
        original_save = FinalAnswer.save
        calls = []

        def fail_second(final, *args, **kwargs):
            calls.append(final.session_participant_id)
            if len(calls) == 2:
                raise RuntimeError('Искусственный сбой второго итога.')
            return original_save(final, *args, **kwargs)

        with patch.object(FinalAnswer, 'save', fail_second), self.assertRaises(RuntimeError):
            advance_session_if_due(
                self.game.session,
                now=self.run.delivery_deadline_at + timedelta(microseconds=1),
            )
        self.game.session.refresh_from_db()
        self.run.refresh_from_db()
        self.assertEqual(self.game.session.phase, LiveSession.PHASE_ANSWERING)
        self.assertIsNone(self.run.finalized_at)
        self.assertFalse(FinalAnswer.objects.filter(run=self.run).exists())
        self.assertEqual(AnswerAttempt.objects.filter(run=self.run).count(), 1)


class StageBCommitEventTests(TransactionTestCase):
    def test_event_is_sent_only_after_commit(self):
        sent = []

        class Layer:
            def group_send(self, group, message):
                sent.append((group, message))

        with (
            patch('apps.session.realtime.get_channel_layer', return_value=Layer()),
            patch('apps.session.realtime.async_to_sync', side_effect=lambda function: function),
        ):
            from django.db import transaction
            with transaction.atomic():
                broadcast_session_event(321, 'question_answering_started', {'secret': 'не отправлять'})
                self.assertEqual(sent, [])
            self.assertEqual(
                [group for group, _ in sent],
                ['session_321_account', 'session_321_participant', 'session_321_display'],
            )
            self.assertTrue(all('secret' not in message for _, message in sent))

    def test_attempt_event_is_sent_only_to_account_and_not_for_repeat(self):
        owner = teacher()
        g = game(owner, active=True)
        sent = []

        class Layer:
            def group_send(self, group, message):
                sent.append((group, message))

        submission_id = uuid.uuid4()
        with (
            patch('apps.session.realtime.get_channel_layer', return_value=Layer()),
            patch('apps.session.realtime.async_to_sync', side_effect=lambda function: function),
        ):
            record_answer_attempt(
                session_id=g.session.pk,
                participation_id=g.link.pk,
                question_id=g.question.pk,
                choice_id=g.correct.pk,
                submission_id=submission_id,
            )
            record_answer_attempt(
                session_id=g.session.pk,
                participation_id=g.link.pk,
                question_id=g.question.pk,
                choice_id=g.correct.pk,
                submission_id=submission_id,
            )

        self.assertEqual([group for group, _ in sent], [f'session_{g.session.pk}_account'])
        self.assertEqual(sent[0][1]['event'], 'answer_state_changed')
        self.assertNotIn('choice_id', sent[0][1])
        self.assertNotIn('submission_id', sent[0][1])

    def test_notification_failure_does_not_roll_back_or_duplicate_final(self):
        owner = teacher()
        g = game(owner, active=True)
        run = g.session.current_run

        attempted_groups = []

        class Layer:
            def group_send(self, group, message):
                attempted_groups.append(group)
                if group.endswith('_account'):
                    raise RuntimeError('секретный-токен-из-ошибки')

        with self.assertLogs('apps.session.realtime', level='ERROR') as captured:
            with (
                patch('apps.session.realtime.get_channel_layer', return_value=Layer()),
                patch('apps.session.realtime.async_to_sync', side_effect=lambda function: function),
            ):
                advance_session_if_due(g.session, now=run.delivery_deadline_at + timedelta(microseconds=1))

        run.refresh_from_db()
        g.session.refresh_from_db()
        self.assertIsNotNone(run.finalized_at)
        self.assertEqual(g.session.phase, LiveSession.PHASE_RESULTS)
        self.assertEqual(FinalAnswer.objects.filter(run=run).count(), 1)
        self.assertEqual(
            attempted_groups,
            [
                f'session_{g.session.pk}_account',
                f'session_{g.session.pk}_participant',
                f'session_{g.session.pk}_display',
            ],
        )
        log_text = '\n'.join(captured.output)
        self.assertIn('Не удалось отправить событие сессии', log_text)
        self.assertNotIn('секретный-токен-из-ошибки', log_text)
        _, repeated = advance_session_if_due(g.session, now=run.delivery_deadline_at + timedelta(seconds=1))
        self.assertFalse(repeated)
        self.assertEqual(FinalAnswer.objects.filter(run=run).count(), 1)

    def test_transport_failure_does_not_turn_saved_attempt_into_http_error(self):
        owner = teacher()
        g = game(owner, active=True)

        class Layer:
            def group_send(self, group, message):
                raise RuntimeError('секретный-токен-из-ошибки')

        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION='Participant ' + g.secret)
        with self.assertLogs('apps.session.realtime', level='ERROR') as captured:
            with (
                patch('apps.session.realtime.get_channel_layer', return_value=Layer()),
                patch('apps.session.realtime.async_to_sync', side_effect=lambda function: function),
            ):
                response = client.post(
                    url(g.session, 'answer'),
                    {
                        'question_id': g.question.pk,
                        'choice_id': g.correct.pk,
                        'submission_id': str(uuid.uuid4()),
                    },
                    format='json',
                )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(AnswerAttempt.objects.filter(run=g.session.current_run).count(), 1)
        self.assertNotIn('секретный-токен-из-ошибки', '\n'.join(captured.output))
