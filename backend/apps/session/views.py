import csv

from django.core.exceptions import ValidationError as DjangoValidationError
from django.http import HttpResponse
from django.utils import timezone
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import IsTeacher
from apps.session.autoreveal import (
    cancel_auto_reveal,
    reveal_current_question_once,
    schedule_auto_reveal,
)
from apps.session.legal import get_current_legal_documents
from apps.session.models import LiveSession, ParticipantAnswer, SessionParticipant
from apps.session.realtime import (
    broadcast_session_event,
    build_public_session_state,
    build_public_leaderboard,
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
    display_participant_phone,
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
        session.revealed_question_id = None
        session.question_started_at = None
        session.save(
            update_fields=[
                "status",
                "started_at",
                "current_question",
                "revealed_question_id",
                "question_started_at",
            ]
        )

        broadcast_session_event(session.id, "session_started", build_public_session_state(session))
        return Response(LiveSessionSerializer(session).data)

    @action(detail=True, methods=["post"])
    def finish(self, request, pk=None):
        session = self.get_object()
        cancel_auto_reveal(session.id)

        session.status = LiveSession.STATUS_FINISHED
        session.current_question = None
        session.revealed_question_id = None
        session.question_started_at = None
        session.save(
            update_fields=[
                "status",
                "finished_at",
                "current_question",
                "revealed_question_id",
                "question_started_at",
            ]
        )

        payload = build_public_session_state(session)
        payload["leaderboard"] = build_public_leaderboard(session)
        broadcast_session_event(session.id, "session_finished", payload)
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
            session.revealed_question_id = None
            session.question_started_at = None
            session.save(
                update_fields=[
                    "status",
                    "finished_at",
                    "current_question",
                    "revealed_question_id",
                    "question_started_at",
                ]
            )

            payload = build_public_session_state(session)
            payload["leaderboard"] = build_public_leaderboard(session)
            broadcast_session_event(session.id, "session_finished", payload)
            return Response(
                {
                    "detail": "No more questions. Session finished.",
                    "session": LiveSessionSerializer(session).data,
                }
            )

        session.current_question = next_question
        session.revealed_question_id = None
        session.question_started_at = timezone.now()
        session.save(update_fields=["current_question", "revealed_question_id", "question_started_at"])

        question_ends_at = compute_question_ends_at(session, next_question)
        payload = {
            "session_id": session.id,
            "status": session.status,
            "question": serialize_question_for_participants(next_question),
            "question_started_at": session.question_started_at.isoformat() if session.question_started_at else None,
            "question_ends_at": question_ends_at.isoformat() if question_ends_at else None,
            "is_answer_revealed": False,
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
        payload = reveal_current_question_once(
            session.id,
            expected_question_id=session.current_question_id,
            revealed_by="teacher",
            auto=False,
        )
        if payload is None:
            return Response(
                {"detail": "Answers for this question are already revealed."},
                status=status.HTTP_400_BAD_REQUEST,
            )
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


class CurrentLegalDocumentsAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def get(self, request):
        return Response(get_current_legal_documents())


class JoinSessionPreviewAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def get(self, request):
        pin = (request.query_params.get("pin") or "").strip()
        join_token = (request.query_params.get("token") or request.query_params.get("join_token") or "").strip()
        if not pin and not join_token:
            return Response(
                {"detail": "PIN or join token is required."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        session_lookup = (
            LiveSession.objects.select_related("quiz", "current_question")
            .prefetch_related("current_question__choices", "participants")
        )
        try:
            if join_token:
                session = session_lookup.get(join_token=join_token)
            else:
                session = session_lookup.get(pin=pin)
        except (LiveSession.DoesNotExist, DjangoValidationError, TypeError, ValueError):
            return Response(
                {"detail": "Session was not found by provided PIN/token."},
                status=status.HTTP_404_NOT_FOUND,
            )

        session_state = build_public_session_state(session)
        return Response(
            {
                "session_id": session.id,
                "session_pin": session.pin,
                "session_status": session.status,
                "participants_count": session_state.get("participants_count"),
                "can_join": session.status != LiveSession.STATUS_FINISHED,
                "closed_reason": (
                    "Session is already finished."
                    if session.status == LiveSession.STATUS_FINISHED
                    else None
                ),
                "quiz": {
                    "id": session.quiz.id,
                    "title": session.quiz.title,
                    "description": session.quiz.description,
                },
                "current_question": session_state.get("current_question"),
                "question_started_at": session_state.get("question_started_at"),
                "question_ends_at": session_state.get("question_ends_at"),
                "is_answer_revealed": session_state.get("is_answer_revealed"),
                "legal_documents": get_current_legal_documents(),
            },
            status=status.HTTP_200_OK,
        )


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
        participants_count = SessionParticipant.objects.filter(session=session).count()
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
                    "phone": display_participant_phone(participant.phone),
                    "consent": participant.consent,
                    "consent_given_at": (
                        participant.consent_given_at.isoformat()
                        if participant.consent_given_at
                        else None
                    ),
                    "privacy_policy_version": participant.privacy_policy_version,
                    "personal_data_consent_version": participant.personal_data_consent_version,
                },
                "quiz": {
                    "id": session.quiz.id,
                    "title": session.quiz.title,
                    "description": session.quiz.description,
                },
                "current_question": session_state.get("current_question"),
                "question_started_at": session_state.get("question_started_at"),
                "question_ends_at": session_state.get("question_ends_at"),
                "is_answer_revealed": session_state.get("is_answer_revealed"),
                "legal_documents": get_current_legal_documents(),
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
