import csv

from django.http import HttpResponse
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import IsTeacher
from apps.session.models import LiveSession
from apps.session.serializers import (
    LeaderboardRowSerializer,
    LiveSessionCreateSerializer,
    LiveSessionSerializer,
    ParticipantJoinSerializer,
    SubmitAnswerSerializer,
    build_leaderboard,
)


class LiveSessionViewSet(viewsets.ModelViewSet):
    queryset = LiveSession.objects.select_related("quiz").prefetch_related("quiz__questions__choices", "participants")
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
        session.status = LiveSession.STATUS_LIVE
        session.save(update_fields=["status", "started_at"])
        return Response(LiveSessionSerializer(session).data)

    @action(detail=True, methods=["post"])
    def finish(self, request, pk=None):
        session = self.get_object()
        session.status = LiveSession.STATUS_FINISHED
        session.save(update_fields=["status", "finished_at"])
        return Response(LiveSessionSerializer(session).data)

    @action(detail=True, methods=["get"], url_path="results/export")
    def export_results(self, request, pk=None):
        session = self.get_object()
        leaderboard = build_leaderboard(session)

        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = f'attachment; filename="session_{session.pin}_results.csv"'

        writer = csv.writer(response)
        writer.writerow(["participant_name", "phone", "score"])
        for row in leaderboard:
            writer.writerow([row["participant_name"], row["phone"], row["score"]])

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

        return Response(
            {
                "session_id": session.id,
                "session_pin": session.pin,
                "session_status": session.status,
                "session_participant_id": session_participant.id,
                "participant": {
                    "id": participant.id,
                    "name": participant.name,
                    "phone": participant.phone,
                },
                "quiz": {
                    "id": session.quiz.id,
                    "title": session.quiz.title,
                    "description": session.quiz.description,
                    "questions": [
                        {
                            "id": q.id,
                            "text": q.text,
                            "order": q.order,
                            "time_limit_sec": q.time_limit_sec,
                            "choices": [
                                {"id": c.id, "text": c.text, "order": c.order}
                                for c in q.choices.all()
                            ],
                        }
                        for q in session.quiz.questions.all()
                    ],
                },
            },
            status=status.HTTP_200_OK,
        )


class SubmitAnswerAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        serializer = SubmitAnswerSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        payload = serializer.save()
        return Response(payload, status=status.HTTP_200_OK)
