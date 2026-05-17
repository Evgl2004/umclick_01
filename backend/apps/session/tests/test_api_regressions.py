from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from apps.quiz.models import Choice, Question, Quiz
from apps.session.models import (
    LiveSession,
    Participant,
    ParticipantAnswer,
    SessionParticipant,
)


User = get_user_model()


class SessionApiRegressionTests(APITestCase):
    def setUp(self):
        self.teacher = User.objects.create_user(
            username="teacher",
            password="safe-password-123",
            is_staff=True,
        )
        self.student = User.objects.create_user(
            username="student",
            password="safe-password-123",
            is_staff=False,
        )

    def authenticate_teacher(self):
        self.client.force_authenticate(self.teacher)

    def create_quiz_with_questions(self):
        quiz = Quiz.objects.create(title="Regression quiz")
        first_question = Question.objects.create(
            quiz=quiz,
            text="First question",
            order=1,
            time_limit_sec=30,
        )
        second_question = Question.objects.create(
            quiz=quiz,
            text="Second question",
            order=2,
            time_limit_sec=30,
        )
        first_correct = Choice.objects.create(
            question=first_question,
            text="Correct",
            order=1,
            is_correct=True,
        )
        Choice.objects.create(
            question=first_question,
            text="Wrong",
            order=2,
            is_correct=False,
        )
        second_correct = Choice.objects.create(
            question=second_question,
            text="Second correct",
            order=1,
            is_correct=True,
        )
        return quiz, first_question, first_correct, second_question, second_correct

    def create_live_session(self):
        quiz, first_question, first_correct, second_question, second_correct = (
            self.create_quiz_with_questions()
        )
        session = LiveSession.objects.create(
            quiz=quiz,
            status=LiveSession.STATUS_LIVE,
            current_question=first_question,
            question_started_at=timezone.now(),
        )
        participant = Participant.objects.create(
            phone="+70000000001",
            name="Alice",
            consent=True,
        )
        session_participant = SessionParticipant.objects.create(
            session=session,
            participant=participant,
        )
        return (
            session,
            session_participant,
            first_question,
            first_correct,
            second_question,
            second_correct,
        )

    def test_teacher_api_rejects_unauthenticated_and_non_staff_users(self):
        payload = {
            "title": "Unauthorized quiz",
            "description": "",
            "questions": [
                {
                    "text": "Question?",
                    "order": 1,
                    "time_limit_sec": 20,
                    "choices": [
                        {"text": "A", "order": 1, "is_correct": True},
                        {"text": "B", "order": 2, "is_correct": False},
                    ],
                }
            ],
        }

        anonymous_response = self.client.post("/api/quizzes/", payload, format="json")
        self.client.force_authenticate(self.student)
        non_staff_response = self.client.post("/api/quizzes/", payload, format="json")

        self.assertIn(
            anonymous_response.status_code,
            [status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN],
        )
        self.assertEqual(non_staff_response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(Quiz.objects.count(), 0)

    def test_join_preview_rejects_missing_or_unknown_join_target(self):
        missing_response = self.client.get("/api/sessions/join/preview/")
        unknown_pin_response = self.client.get(
            "/api/sessions/join/preview/",
            {"pin": "000000"},
        )
        invalid_token_response = self.client.get(
            "/api/sessions/join/preview/",
            {"token": "not-a-valid-uuid"},
        )

        self.assertEqual(missing_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(unknown_pin_response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(invalid_token_response.status_code, status.HTTP_404_NOT_FOUND)

    def test_join_rejects_finished_session_and_missing_join_target(self):
        quiz, _, _, _, _ = self.create_quiz_with_questions()
        finished_session = LiveSession.objects.create(
            quiz=quiz,
            status=LiveSession.STATUS_FINISHED,
        )

        missing_target_response = self.client.post(
            "/api/sessions/join/",
            {
                "phone": "+70000000001",
                "name": "Alice",
                "consent": True,
            },
            format="json",
        )
        finished_response = self.client.post(
            "/api/sessions/join/",
            {
                "pin": finished_session.pin,
                "phone": "+70000000001",
                "name": "Alice",
                "consent": True,
            },
            format="json",
        )

        self.assertEqual(
            missing_target_response.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertEqual(finished_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("already finished", str(finished_response.data))
        self.assertEqual(Participant.objects.count(), 0)

    def test_round_controls_reject_invalid_session_states(self):
        quiz, _, _, _, _ = self.create_quiz_with_questions()
        waiting_session = LiveSession.objects.create(
            quiz=quiz,
            status=LiveSession.STATUS_WAITING,
        )
        self.authenticate_teacher()

        next_question_response = self.client.post(
            f"/api/sessions/{waiting_session.id}/next-question/",
        )
        reveal_waiting_response = self.client.post(
            f"/api/sessions/{waiting_session.id}/reveal-answer/",
        )
        start_response = self.client.post(f"/api/sessions/{waiting_session.id}/start/")
        reveal_without_question_response = self.client.post(
            f"/api/sessions/{waiting_session.id}/reveal-answer/",
        )

        self.assertEqual(
            next_question_response.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertEqual(
            reveal_waiting_response.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertEqual(start_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            reveal_without_question_response.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertIn("No active question", str(reveal_without_question_response.data))

    def test_answer_rejects_inactive_session_wrong_question_and_revealed_question(self):
        (
            session,
            session_participant,
            first_question,
            first_correct,
            second_question,
            second_correct,
        ) = self.create_live_session()

        wrong_question_response = self.client.post(
            "/api/sessions/answer/",
            {
                "session_participant_id": session_participant.id,
                "question_id": second_question.id,
                "choice_id": second_correct.id,
            },
            format="json",
        )

        session.revealed_question_id = first_question.id
        session.save(update_fields=["revealed_question_id"])
        revealed_response = self.client.post(
            "/api/sessions/answer/",
            {
                "session_participant_id": session_participant.id,
                "question_id": first_question.id,
                "choice_id": first_correct.id,
            },
            format="json",
        )

        session.revealed_question_id = None
        session.status = LiveSession.STATUS_WAITING
        session.save(update_fields=["revealed_question_id", "status"])
        inactive_response = self.client.post(
            "/api/sessions/answer/",
            {
                "session_participant_id": session_participant.id,
                "question_id": first_question.id,
                "choice_id": first_correct.id,
            },
            format="json",
        )

        self.assertEqual(
            wrong_question_response.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertIn("not active right now", str(wrong_question_response.data))
        self.assertEqual(revealed_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("already revealed", str(revealed_response.data))
        self.assertEqual(inactive_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("Session is not active", str(inactive_response.data))
        self.assertEqual(ParticipantAnswer.objects.count(), 0)
