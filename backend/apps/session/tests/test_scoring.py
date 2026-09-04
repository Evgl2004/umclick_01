import uuid
from datetime import timedelta
from unittest.mock import patch

from django.test import SimpleTestCase, TestCase

from apps.quiz.models import Choice, Question, Quiz
from apps.session.advance import advance_session_if_due
from apps.session.gameplay import record_answer_attempt
from apps.session.models import LiveSession
from apps.session.results import _with_places
from apps.session.results import build_stage_b_leaderboard
from apps.session.tests.helpers import activate_gameplay, participate, teacher


class RankingTests(SimpleTestCase):
    def test_full_equality_gives_shared_place(self):
        rows = [
            {'correct_answers': 2, 'correct_time_ms': 40234},
            {'correct_answers': 2, 'correct_time_ms': 40234},
            {'correct_answers': 1, 'correct_time_ms': 1000},
        ]
        ranked = _with_places(rows)
        self.assertEqual([row['rank'] for row in ranked], [1, 1, 3])

    def test_millisecond_difference_is_not_a_tie(self):
        rows = [
            {'correct_answers': 2, 'correct_time_ms': 40234},
            {'correct_answers': 2, 'correct_time_ms': 40432},
        ]
        ranked = _with_places(rows)
        self.assertEqual([row['rank'] for row in ranked], [1, 2])


class RankingDatabaseTests(TestCase):
    def test_database_rating_uses_exact_correct_milliseconds_and_zero_for_wrong(self):
        owner = teacher()
        content = Quiz.objects.create(
            owner=owner,
            title='Викторина точного рейтинга',
            reading_time_sec=3,
            results_time_sec=3,
        )
        question = Question.objects.create(
            quiz=content,
            text='Вопрос на точность',
            time_limit_sec=60,
        )
        correct = Choice.objects.create(question=question, text='Верно', is_correct=True)
        wrong = Choice.objects.create(question=question, text='Неверно', is_correct=False, order=2)
        session = LiveSession.objects.create(quiz=content, created_by=owner)
        first, _ = participate(session, name='40,234')
        second, _ = participate(session, name='40,432')
        third, _ = participate(session, name='Неверный')
        run = activate_gameplay(session, question)

        for participation, choice, elapsed_ms in (
            (first, correct, 40234),
            (second, correct, 40432),
            (third, wrong, 1000),
        ):
            admitted_at = run.answering_started_at + timedelta(milliseconds=elapsed_ms)
            with patch('apps.session.gameplay.database_now', return_value=admitted_at):
                record_answer_attempt(
                    session_id=session.pk,
                    participation_id=participation.pk,
                    question_id=question.pk,
                    choice_id=choice.pk,
                    submission_id=uuid.uuid4(),
                )
        advance_session_if_due(session, now=run.delivery_deadline_at + timedelta(microseconds=1))
        rows = build_stage_b_leaderboard(session)
        self.assertEqual([row['participant_name'] for row in rows], ['40,234', '40,432', 'Неверный'])
        self.assertEqual([row['rank'] for row in rows], [1, 2, 3])
        self.assertEqual([row['correct_time_ms'] for row in rows], [40234, 40432, 0])
        self.assertTrue(all('points' not in row for row in rows))
