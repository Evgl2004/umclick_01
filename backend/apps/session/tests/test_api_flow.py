from datetime import timedelta

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from apps.quiz.models import Choice, Question, Quiz
from apps.session.flow import start_answering_for_current_question
from apps.session.models import LiveSession, Participant, ParticipantAnswer, SessionParticipant
from apps.session.serializers import build_leaderboard


User = get_user_model()


class SessionApiFlowTests(APITestCase):
    def setUp(self):
        self.teacher = User.objects.create_user(
            username="teacher",
            password="safe-password-123",
            is_staff=True,
        )

    def authenticate_teacher(self):
        self.client.force_authenticate(self.teacher)

    def create_quiz(self):
        quiz = Quiz.objects.create(
            title="History quiz",
            description="Warm-up",
        )
        question = Question.objects.create(
            quiz=quiz,
            text="When was the first umclick prototype built?",
            order=1,
            time_limit_sec=30,
        )
        correct_choice = Choice.objects.create(
            question=question,
            text="2026",
            order=1,
            is_correct=True,
        )
        wrong_choice = Choice.objects.create(
            question=question,
            text="1999",
            order=2,
            is_correct=False,
        )
        return quiz, question, correct_choice, wrong_choice

    def create_session(self, *, status_value=LiveSession.STATUS_WAITING):
        quiz, question, correct_choice, wrong_choice = self.create_quiz()
        session = LiveSession.objects.create(
            quiz=quiz,
            host_name="Teacher",
            status=status_value,
        )
        return session, question, correct_choice, wrong_choice

    def test_teacher_can_create_quiz_and_live_session(self):
        self.authenticate_teacher()

        quiz_response = self.client.post(
            "/api/quizzes/",
            {
                "title": "Math sprint",
                "description": "Fast round",
                "questions": [
                    {
                        "text": "2 + 2?",
                        "order": 1,
                        "time_limit_sec": 20,
                        "choices": [
                            {"text": "4", "order": 1, "is_correct": True},
                            {"text": "5", "order": 2, "is_correct": False},
                        ],
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(quiz_response.status_code, status.HTTP_201_CREATED)
        quiz_id = quiz_response.data["id"]
        self.assertEqual(Quiz.objects.count(), 1)
        self.assertEqual(Question.objects.count(), 1)
        self.assertEqual(Choice.objects.count(), 2)

        session_response = self.client.post(
            "/api/sessions/",
            {"quiz": quiz_id, "host_name": "Teacher"},
            format="json",
        )

        self.assertEqual(session_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(session_response.data["status"], LiveSession.STATUS_WAITING)
        self.assertEqual(len(session_response.data["pin"]), 6)
        self.assertTrue(session_response.data["join_token"])

    def test_public_preview_supports_pin_and_token(self):
        session, _, _, _ = self.create_session()

        pin_response = self.client.get(
            "/api/sessions/join/preview/",
            {"pin": session.pin},
        )
        token_response = self.client.get(
            "/api/sessions/join/preview/",
            {"token": str(session.join_token)},
        )

        self.assertEqual(pin_response.status_code, status.HTTP_200_OK)
        self.assertEqual(token_response.status_code, status.HTTP_200_OK)
        self.assertEqual(pin_response.data["session_id"], session.id)
        self.assertEqual(token_response.data["session_id"], session.id)
        self.assertTrue(pin_response.data["can_join"])
        self.assertEqual(pin_response.data["quiz"]["title"], "History quiz")
        self.assertIn("legal_documents", pin_response.data)

    def test_public_preview_marks_finished_session_as_closed(self):
        session, _, _, _ = self.create_session(status_value=LiveSession.STATUS_FINISHED)

        response = self.client.get(
            "/api/sessions/join/preview/",
            {"pin": session.pin},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.data["can_join"])
        self.assertEqual(response.data["closed_reason"], "Session is already finished.")

    @override_settings(CHANNEL_LAYERS={"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}})
    def test_teacher_finish_marks_live_session_as_aborted(self):
        self.authenticate_teacher()
        session, _, _, _ = self.create_session(status_value=LiveSession.STATUS_LIVE)

        response = self.client.post(f"/api/sessions/{session.id}/finish/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], LiveSession.STATUS_ABORTED)
        self.assertEqual(response.data["phase"], LiveSession.PHASE_FINAL)

    @override_settings(CHANNEL_LAYERS={"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}})
    def test_participant_can_join_by_pin_and_token(self):
        session, _, _, _ = self.create_session()

        first_response = self.client.post(
            "/api/sessions/join/",
            {
                "pin": session.pin,
                "phone": "+70000000001",
                "name": "Alice",
                "consent": True,
            },
            format="json",
        )
        second_response = self.client.post(
            "/api/sessions/join/",
            {
                "join_token": str(session.join_token),
                "phone": "+70000000002",
                "name": "Bob",
                "consent": True,
            },
            format="json",
        )

        self.assertEqual(first_response.status_code, status.HTTP_200_OK)
        self.assertEqual(second_response.status_code, status.HTTP_200_OK)
        self.assertEqual(first_response.data["participants_count"], 1)
        self.assertEqual(second_response.data["participants_count"], 2)
        self.assertEqual(first_response.data["participant"]["privacy_policy_version"], "2026-01")
        self.assertEqual(
            first_response.data["participant"]["personal_data_consent_version"],
            "2026-01",
        )
        self.assertEqual(Participant.objects.count(), 2)
        self.assertEqual(SessionParticipant.objects.count(), 2)

    def test_join_requires_consent(self):
        session, _, _, _ = self.create_session()

        response = self.client.post(
            "/api/sessions/join/",
            {
                "pin": session.pin,
                "phone": "+70000000001",
                "name": "Alice",
                "consent": False,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("Consent is required", str(response.data))
        self.assertEqual(Participant.objects.count(), 0)

    @override_settings(CHANNEL_LAYERS={"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}})
    def test_participant_can_join_without_phone(self):
        session, _, _, _ = self.create_session()

        response = self.client.post(
            "/api/sessions/join/",
            {
                "pin": session.pin,
                "phone": "",
                "name": "Guest",
                "consent": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        participant = Participant.objects.get()
        self.assertTrue(participant.phone.startswith("guest:"))
        self.assertEqual(response.data["participant"]["phone"], "")
        self.assertEqual(build_leaderboard(session)[0]["phone"], "")

    @override_settings(CHANNEL_LAYERS={"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}})
    def test_live_answer_scores_once_and_blocks_duplicates(self):
        session, question, correct_choice, _ = self.create_session()
        self.authenticate_teacher()

        start_response = self.client.post(f"/api/sessions/{session.id}/start/")
        next_response = self.client.post(f"/api/sessions/{session.id}/next-question/")

        self.assertEqual(start_response.status_code, status.HTTP_200_OK)
        self.assertEqual(next_response.status_code, status.HTTP_200_OK)
        self.assertEqual(next_response.data["current_question"]["id"], question.id)
        self.assertEqual(next_response.data["phase"], LiveSession.PHASE_READING)
        session.refresh_from_db()
        start_answering_for_current_question(session)

        join_response = self.client.post(
            "/api/sessions/join/",
            {
                "pin": session.pin,
                "phone": "+70000000001",
                "name": "Alice",
                "consent": True,
            },
            format="json",
        )
        answer_payload = {
            "session_participant_id": join_response.data["session_participant_id"],
            "question_id": question.id,
            "choice_id": correct_choice.id,
        }

        first_answer = self.client.post("/api/sessions/answer/", answer_payload, format="json")
        second_answer = self.client.post("/api/sessions/answer/", answer_payload, format="json")

        self.assertEqual(join_response.status_code, status.HTTP_200_OK)
        self.assertEqual(first_answer.status_code, status.HTTP_200_OK)
        self.assertTrue(first_answer.data["is_correct"])
        self.assertGreater(first_answer.data["score_points"], 0)
        self.assertEqual(second_answer.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("already been submitted", str(second_answer.data))

    def test_late_answer_is_rejected_after_question_deadline(self):
        session, question, correct_choice, _ = self.create_session(status_value=LiveSession.STATUS_LIVE)
        session.current_question = question
        session.phase = LiveSession.PHASE_ANSWERING
        session.question_started_at = timezone.now() - timedelta(seconds=question.time_limit_sec + 1)
        session.save(update_fields=["current_question", "phase", "question_started_at"])
        participant = Participant.objects.create(
            phone="+70000000001",
            name="Alice",
            consent=True,
        )
        session_participant = SessionParticipant.objects.create(
            session=session,
            participant=participant,
        )

        response = self.client.post(
            "/api/sessions/answer/",
            {
                "session_participant_id": session_participant.id,
                "question_id": question.id,
                "choice_id": correct_choice.id,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("Time is over", str(response.data))
        self.assertEqual(ParticipantAnswer.objects.count(), 0)

    def test_public_session_state_hides_correct_choices(self):
        session, question, _, _ = self.create_session(status_value=LiveSession.STATUS_LIVE)
        session.current_question = question
        session.phase = LiveSession.PHASE_ANSWERING
        session.question_started_at = timezone.now()
        session.save(update_fields=["current_question", "phase", "question_started_at"])

        response = self.client.get(f"/api/sessions/{session.id}/state/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        choice_payload = response.data["current_question"]["choices"][0]
        self.assertIn("text", choice_payload)
        self.assertNotIn("is_correct", choice_payload)

    @override_settings(CHANNEL_LAYERS={"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}})
    def test_public_session_state_advances_overdue_answering_phase(self):
        session, question, _, _ = self.create_session(status_value=LiveSession.STATUS_LIVE)
        session.current_question = question
        session.phase = LiveSession.PHASE_ANSWERING
        session.question_started_at = timezone.now() - timedelta(seconds=question.time_limit_sec + 1)
        session.save(update_fields=["current_question", "phase", "question_started_at"])

        response = self.client.get(f"/api/sessions/{session.id}/state/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["phase"], LiveSession.PHASE_RESULTS)
        self.assertTrue(response.data["is_answer_revealed"])
        self.assertIn("reveal", response.data)
        session.refresh_from_db()
        self.assertEqual(session.phase, LiveSession.PHASE_RESULTS)

    @override_settings(CHANNEL_LAYERS={"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}})
    def test_display_state_advances_results_phase_to_next_question(self):
        self.authenticate_teacher()
        session, first_question, _, _ = self.create_session(status_value=LiveSession.STATUS_LIVE)
        second_question = Question.objects.create(
            quiz=session.quiz,
            text="Second question?",
            order=2,
            time_limit_sec=20,
        )
        Choice.objects.create(question=second_question, text="Yes", order=1, is_correct=True)
        Choice.objects.create(question=second_question, text="No", order=2, is_correct=False)
        session.current_question = first_question
        session.revealed_question_id = first_question.id
        session.phase = LiveSession.PHASE_RESULTS
        session.phase_started_at = timezone.now() - timedelta(seconds=session.quiz.results_time_sec + 1)
        session.save(
            update_fields=[
                "current_question",
                "revealed_question_id",
                "phase",
                "phase_started_at",
            ]
        )

        response = self.client.get(f"/api/sessions/{session.id}/display-state/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["phase"], LiveSession.PHASE_READING)
        self.assertEqual(response.data["display_question"]["id"], second_question.id)
        session.refresh_from_db()
        self.assertEqual(session.current_question_id, second_question.id)

    def test_display_state_keeps_full_text_when_participant_payload_is_hidden(self):
        self.authenticate_teacher()
        quiz, question, correct_choice, _ = self.create_quiz()
        quiz.question_only_on_display = True
        quiz.show_choices_on_participant = False
        quiz.save(update_fields=["question_only_on_display", "show_choices_on_participant"])
        session = LiveSession.objects.create(
            quiz=quiz,
            host_name="Teacher",
            status=LiveSession.STATUS_LIVE,
            phase=LiveSession.PHASE_ANSWERING,
            current_question=question,
            question_started_at=timezone.now(),
        )

        public_response = self.client.get(f"/api/sessions/{session.id}/state/")
        display_response = self.client.get(f"/api/sessions/{session.id}/display-state/")

        self.assertEqual(public_response.status_code, status.HTTP_200_OK)
        self.assertEqual(display_response.status_code, status.HTTP_200_OK)
        self.assertEqual(public_response.data["current_question"]["text"], "")
        self.assertEqual(public_response.data["current_question"]["choices"][0]["text"], "")
        self.assertEqual(display_response.data["display_question"]["text"], question.text)
        display_choice_texts = [
            choice["text"] for choice in display_response.data["display_question"]["choices"]
        ]
        self.assertIn(correct_choice.text, display_choice_texts)

    def test_leaderboard_and_csv_export_are_sorted_by_score(self):
        session, question, correct_choice, wrong_choice = self.create_session()
        alice = Participant.objects.create(phone="+70000000001", name="Alice", consent=True)
        bob = Participant.objects.create(phone="+70000000002", name="Bob", consent=True)
        alice_link = SessionParticipant.objects.create(session=session, participant=alice)
        bob_link = SessionParticipant.objects.create(session=session, participant=bob)
        ParticipantAnswer.objects.create(
            session_participant=alice_link,
            question=question,
            choice=wrong_choice,
            is_correct=False,
            score_points=0,
        )
        ParticipantAnswer.objects.create(
            session_participant=bob_link,
            question=question,
            choice=correct_choice,
            is_correct=True,
            score_points=900,
        )
        self.authenticate_teacher()

        leaderboard_response = self.client.get(f"/api/sessions/{session.id}/leaderboard/")
        export_response = self.client.get(f"/api/sessions/{session.id}/results/export/")

        self.assertEqual(leaderboard_response.status_code, status.HTTP_200_OK)
        self.assertEqual(leaderboard_response.data[0]["participant_name"], "Bob")
        self.assertEqual(leaderboard_response.data[0]["points"], 900)
        self.assertEqual(export_response.status_code, status.HTTP_200_OK)
        self.assertEqual(export_response["Content-Type"], "text/csv")
        csv_body = export_response.content.decode("utf-8")
        self.assertIn("participant_name,phone,points,correct_answers,answer_time_ms", csv_body)
        self.assertLess(csv_body.index("Bob"), csv_body.index("Alice"))
