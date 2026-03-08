import base64
import io
import os

import qrcode
from django.db.models import Count, Q
from rest_framework import serializers

from apps.quiz.models import Choice, Question, Quiz
from apps.session.models import LiveSession, Participant, ParticipantAnswer, SessionParticipant


def build_join_url(session: LiveSession) -> str:
    frontend_join_base = os.getenv("FRONTEND_JOIN_BASE", "http://localhost:3000/join")
    return f"{frontend_join_base}?token={session.join_token}"


def build_qr_base64(data: str) -> str:
    image = qrcode.make(data)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    encoded = base64.b64encode(buffer.getvalue()).decode("utf-8")
    return f"data:image/png;base64,{encoded}"


class SessionChoiceSerializer(serializers.ModelSerializer):
    class Meta:
        model = Choice
        fields = ["id", "text", "order"]


class SessionQuestionSerializer(serializers.ModelSerializer):
    choices = SessionChoiceSerializer(many=True)

    class Meta:
        model = Question
        fields = ["id", "text", "order", "time_limit_sec", "choices"]


class SessionQuizSerializer(serializers.ModelSerializer):
    questions = SessionQuestionSerializer(many=True)

    class Meta:
        model = Quiz
        fields = ["id", "title", "description", "questions"]


class LiveSessionCreateSerializer(serializers.ModelSerializer):
    class Meta:
        model = LiveSession
        fields = ["id", "quiz", "host_name", "status", "pin", "join_token", "created_at"]
        read_only_fields = ["id", "status", "pin", "join_token", "created_at"]


class LiveSessionSerializer(serializers.ModelSerializer):
    quiz = SessionQuizSerializer()
    join_url = serializers.SerializerMethodField()
    qr_code_base64 = serializers.SerializerMethodField()
    participants_count = serializers.SerializerMethodField()

    class Meta:
        model = LiveSession
        fields = [
            "id",
            "quiz",
            "host_name",
            "status",
            "pin",
            "join_token",
            "join_url",
            "qr_code_base64",
            "participants_count",
            "started_at",
            "finished_at",
            "created_at",
        ]

    def get_join_url(self, obj: LiveSession) -> str:
        return build_join_url(obj)

    def get_qr_code_base64(self, obj: LiveSession) -> str:
        return build_qr_base64(self.get_join_url(obj))

    def get_participants_count(self, obj: LiveSession) -> int:
        return obj.participants.count()


class ParticipantJoinSerializer(serializers.Serializer):
    pin = serializers.CharField(max_length=6)
    phone = serializers.CharField(max_length=32)
    name = serializers.CharField(max_length=255)
    consent = serializers.BooleanField()

    def validate(self, attrs):
        if not attrs["consent"]:
            raise serializers.ValidationError("Consent is required to join quiz sessions.")

        try:
            session = LiveSession.objects.select_related("quiz").prefetch_related("quiz__questions__choices").get(
                pin=attrs["pin"]
            )
        except LiveSession.DoesNotExist as exc:
            raise serializers.ValidationError("Session with this PIN was not found.") from exc

        if session.status == LiveSession.STATUS_FINISHED:
            raise serializers.ValidationError("Session is already finished.")

        attrs["session"] = session
        return attrs

    def create(self, validated_data):
        phone = validated_data["phone"]
        name = validated_data["name"]
        consent = validated_data["consent"]
        session = validated_data["session"]

        participant, created = Participant.objects.get_or_create(
            phone=phone,
            defaults={"name": name, "consent": consent},
        )
        if not created:
            participant.name = name
            participant.consent = consent
            participant.save(update_fields=["name", "consent"])

        session_participant, _ = SessionParticipant.objects.get_or_create(
            session=session,
            participant=participant,
        )

        return {
            "session": session,
            "session_participant": session_participant,
            "participant": participant,
        }


class SubmitAnswerSerializer(serializers.Serializer):
    session_participant_id = serializers.IntegerField()
    question_id = serializers.IntegerField()
    choice_id = serializers.IntegerField()

    def validate(self, attrs):
        try:
            session_participant = SessionParticipant.objects.select_related("session").get(
                id=attrs["session_participant_id"]
            )
        except SessionParticipant.DoesNotExist as exc:
            raise serializers.ValidationError("Participant session link was not found.") from exc

        if session_participant.session.status != LiveSession.STATUS_LIVE:
            raise serializers.ValidationError("Session is not active.")

        try:
            question = Question.objects.get(id=attrs["question_id"], quiz_id=session_participant.session.quiz_id)
        except Question.DoesNotExist as exc:
            raise serializers.ValidationError("Question was not found in this session quiz.") from exc

        try:
            choice = Choice.objects.get(id=attrs["choice_id"], question_id=question.id)
        except Choice.DoesNotExist as exc:
            raise serializers.ValidationError("Choice was not found for this question.") from exc

        attrs["session_participant"] = session_participant
        attrs["question"] = question
        attrs["choice"] = choice
        return attrs

    def create(self, validated_data):
        session_participant = validated_data["session_participant"]
        question = validated_data["question"]
        choice = validated_data["choice"]

        answer, _ = ParticipantAnswer.objects.update_or_create(
            session_participant=session_participant,
            question=question,
            defaults={
                "choice": choice,
                "is_correct": choice.is_correct,
            },
        )

        score = ParticipantAnswer.objects.filter(
            session_participant=session_participant,
            is_correct=True,
        ).count()

        return {
            "answer_id": answer.id,
            "is_correct": answer.is_correct,
            "score": score,
        }


class LeaderboardRowSerializer(serializers.Serializer):
    participant_name = serializers.CharField()
    phone = serializers.CharField()
    score = serializers.IntegerField()


def build_leaderboard(session: LiveSession):
    rows = (
        SessionParticipant.objects.filter(session=session)
        .select_related("participant")
        .annotate(score=Count("answers", filter=Q(answers__is_correct=True)))
        .order_by("-score", "joined_at")
    )
    return [
        {
            "participant_name": row.participant.name,
            "phone": row.participant.phone,
            "score": row.score,
        }
        for row in rows
    ]
