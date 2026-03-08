import csv

from django.http import HttpResponse
from django.utils import timezone
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import IsTeacher
from apps.session.autoreveal import cancel_auto_reveal, schedule_auto_reveal
from apps.session.models import LiveSession, ParticipantAnswer
from apps.session.realtime import (
    broadcast_session_event,
    build_answer_reveal_payload,
    build_public_session_state,
    compute_question_ends_at,
    get_next_question,
    serialize_question_for_participants,
)
from apps.session.serializers import (
    LeaderboardRowSerializer,
    LiveSessionCreateSerializer,
    LiveSessionSerializer,
    ParticipantJoinSerializer,
    SubmitAnswerSerializer,
    build_leaderboard,
)


class LiveSessionViewSet(viewsets.ModelViewSet):
    queryset = (
        LiveSession.objects.select_related("quiz", "current_question")
        .prefetch_related("quiz__questions__choices", "current_question__choices", "participants")
        .all()
    )
    permission_classes = [IsTeacher]

    def get_serializer_class(self):
        if self.action == "create":
            return LiveSessionCreateSerializer
        return LiveSessionSerializer

    @action(detail=True, methods=["post"])
    def start(self, request, pk=None):
        session = self.get_object()
        if session.status == LiveSession.STATUS_FINISHED:
            return Response(
                {"detail": "Session is already finished."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        cancel_auto_reveal(session.id)
        session.status = LiveSession.STATUS_LIVE
        session.current_question = None
        session.question_started_at = None
        session.save(update_fields=["status", "started_at", "current_question", "question_started_at"])

        broadcast_session_event(session.id, "session_started", build_public_session_state(session))
        return Response(LiveSessionSerializer(session).data)

    @action(detail=True, methods=["post"])
    def finish(self, request, pk=None):
        session = self.get_object()
        cancel_auto_reveal(session.id)

        session.status = LiveSession.STATUS_FINISHED
        session.current_question = None
        session.question_started_at = None
        session.save(update_fields=["status", "finished_at", "current_question", "question_started_at"])

        broadcast_session_event(session.id, "session_finished", build_public_session_state(session))
        return Response(LiveSessionSerializer(session).data)

    @action(detail=True, methods=["post"], url_path="next-question")
    def next_question(self, request, pk=None):
        session = self.get_object()
        if session.status != LiveSession.STATUS_LIVE:
            return Response(
                {"detail": "Session must be live to move to the next question."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        cancel_auto_reveal(session.id)
        next_question = get_next_question(session)
        if next_question is None:
            session.status = LiveSession.STATUS_FINISHED
            session.current_question = None
            session.question_started_at = None
            session.save(update_fields=["status", "finished_at", "current_question", "question_started_at"])

            payload = build_public_session_state(session)
            broadcast_session_event(session.id, "session_finished", payload)
            return Response(
                {
                    "detail": "No more questions. Session finished.",
                    "session": LiveSessionSerializer(session).data,
                }
            )

        session.current_question = next_question
        session.question_started_at = timezone.now()
        session.save(update_fields=["current_question", "question_started_at"])

        question_ends_at = compute_question_ends_at(session, next_question)
        payload = {
            "session_id": session.id,
            "status": session.status,
            "question": serialize_question_for_participants(next_question),
            "question_started_at": session.question_started_at.isoformat() if session.question_started_at else None,
            "question_ends_at": question_ends_at.isoformat() if question_ends_at else None,
        }
        broadcast_session_event(session.id, "question_started", payload)

        schedule_auto_reveal(session.id, next_question.id, next_question.time_limit_sec)
        return Response(payload)

    @action(detail=True, methods=["post"], url_path="reveal-answer")
    def reveal_answer(self, request, pk=None):
        session = self.get_object()
        if session.status != LiveSession.STATUS_LIVE:
            return Response(
                {"detail": "Session must be live to reveal answers."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if session.current_question_id is None:
            return Response(
                {"detail": "No active question to reveal."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        cancel_auto_reveal(session.id)
        payload = build_answer_reveal_payload(session)
        payload["revealed_by"] = "teacher"
        payload["auto"] = False
        broadcast_session_event(session.id, "answer_revealed", payload)
        return Response(payload)

    @action(
        detail=True,
        methods=["get"],
        url_path="state",
        permission_classes=[permissions.AllowAny],
    )
    def state(self, request, pk=None):
        session = self.get_object()
        return Response(build_public_session_state(session))

    @action(detail=True, methods=["get"], url_path="results/export")
    def export_results(self, request, pk=None):
        session = self.get_object()
        leaderboard = build_leaderboard(session)

        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = f'attachment; filename="session_{session.pin}_results.csv"'

        writer = csv.writer(response)
        writer.writerow(["participant_name", "phone", "points", "correct_answers"])
        for row in leaderboard:
            writer.writerow([row["participant_name"], row["phone"], row["points"], row["correct_answers"]])

        return response

    @action(detail=True, methods=["get"])
    def leaderboard(self, request, pk=None):
        session = self.get_object()
        leaderboard = build_leaderboard(session)
        serializer = LeaderboardRowSerializer(leaderboard, many=True)
        return Response(serializer.data)


class JoinSessionAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        serializer = ParticipantJoinSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        payload = serializer.save()

        session = payload["session"]
        session_participant = payload["session_participant"]
        participant = payload["participant"]

        session_state = build_public_session_state(session)
        participants_count = session.participants.count()
        broadcast_session_event(
            session.id,
            "participant_joined",
            {
                "session_id": session.id,
                "participant_name": participant.name,
                "participants_count": participants_count,
            },
        )
        broadcast_session_event(session.id, "session_state", session_state)

        return Response(
            {
                "session_id": session.id,
                "session_pin": session.pin,
                "session_status": session.status,
                "session_participant_id": session_participant.id,
                "participants_count": participants_count,
                "participant": {
                    "id": participant.id,
                    "name": participant.name,
                    "phone": participant.phone,
                },
                "quiz": {
                    "id": session.quiz.id,
                    "title": session.quiz.title,
                    "description": session.quiz.description,
                },
                "current_question": session_state.get("current_question"),
                "question_started_at": session_state.get("question_started_at"),
                "question_ends_at": session_state.get("question_ends_at"),
            },
            status=status.HTTP_200_OK,
        )


class SubmitAnswerAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        serializer = SubmitAnswerSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        session_participant = serializer.validated_data["session_participant"]
        question = serializer.validated_data["question"]
        payload = serializer.save()

        answered_count = ParticipantAnswer.objects.filter(
            session_participant__session=session_participant.session,
            question=question,
        ).count()
        broadcast_session_event(
            session_participant.session_id,
            "answer_submitted",
            {
                "session_id": session_participant.session_id,
                "question_id": question.id,
                "answered_count": answered_count,
                "score_points": payload["score_points"],
                "total_points": payload["total_points"],
                "correct_answers": payload["correct_answers"],
            },
        )

        return Response(payload, status=status.HTTP_200_OK)
