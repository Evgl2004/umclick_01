from datetime import timedelta

from django.test import SimpleTestCase
from django.utils import timezone

from apps.quiz.models import Question
from apps.session.models import LiveSession
from apps.session.serializers import (
    MAX_CORRECT_POINTS,
    MIN_CORRECT_POINTS,
    compute_question_ends_at,
    score_for_answer,
)


class ScoringTests(SimpleTestCase):
    def test_incorrect_answer_gets_zero_points(self):
        question = Question(time_limit_sec=20)

        self.assertEqual(score_for_answer(question, elapsed_ms=0, is_correct=False), 0)

    def test_fast_correct_answer_gets_max_points(self):
        question = Question(time_limit_sec=20)

        self.assertEqual(
            score_for_answer(question, elapsed_ms=0, is_correct=True),
            MAX_CORRECT_POINTS,
        )

    def test_slow_correct_answer_never_drops_below_minimum(self):
        question = Question(time_limit_sec=20)

        self.assertEqual(
            score_for_answer(question, elapsed_ms=999_999, is_correct=True),
            MIN_CORRECT_POINTS,
        )

    def test_mid_timer_correct_answer_is_scaled_by_remaining_time(self):
        question = Question(time_limit_sec=10)

        self.assertEqual(
            score_for_answer(question, elapsed_ms=5_000, is_correct=True),
            500,
        )

    def test_question_ends_at_uses_session_start_and_question_limit(self):
        started_at = timezone.now()
        session = LiveSession(question_started_at=started_at)
        question = Question(time_limit_sec=25)

        self.assertEqual(
            compute_question_ends_at(session, question),
            started_at + timedelta(seconds=25),
        )

    def test_question_ends_at_is_empty_without_started_question(self):
        self.assertIsNone(compute_question_ends_at(LiveSession(), Question(time_limit_sec=25)))
        self.assertIsNone(compute_question_ends_at(LiveSession(question_started_at=timezone.now()), None))
