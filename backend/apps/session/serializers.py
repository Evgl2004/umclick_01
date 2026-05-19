import base64
import io
import os
import uuid
from datetime import timedelta

import qrcode
from django.db.models import Count, Q, Sum
from django.db.models.functions import Coalesce
from django.utils import timezone
from rest_framework import serializers

from apps.quiz.models import Choice, Question, Quiz
from apps.session.legal import get_current_consent_versions
from apps.session.models import LiveSession, Participant, ParticipantAnswer, SessionParticipant
from apps.session.realtime import compute_phase_ends_at, serialize_question_for_participants

MAX_CORRECT_POINTS = 1000
MIN_CORRECT_POINTS = 200
GUEST_PHONE_PREFIX = "guest:"


def make_guest_phone() -> str:
    return f"{GUEST_PHONE_PREFIX}{uuid.uuid4().hex[:26]}"


def display_participant_phone(phone: str) -> str:
    return "" if phone.startswith(GUEST_PHONE_PREFIX) else phone


def build_join_url(session: LiveSession) -> str:
    frontend_join_base = os.getenv("FRONTEND_JOIN_BASE", "http://localhost:3000/join")
    return f"{frontend_join_base}?token={session.join_token}"


def build_qr_base64(data: str) -> str:
    image = qrcode.make(data)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    encoded = base64.b64encode(buffer.getvalue()).decode("utf-8")
    return f"data:image/png;base64,{encoded}"


def compute_question_ends_at(session: LiveSession, question: Question | None):
    if session.question_started_at is None or question is None:
        return None
    return session.question_started_at + timedelta(seconds=question.time_limit_sec)


def score_for_answer(question: Question, elapsed_ms: int, is_correct: bool) -> int:
    if not is_correct:
        return 0

    time_limit_ms = max(question.time_limit_sec * 1000, 1)
    bounded_elapsed = max(0, min(elapsed_ms, time_limit_ms))
    remaining_ratio = max(0.0, 1.0 - (bounded_elapsed / time_limit_ms))
    raw_points = int(round(MAX_CORRECT_POINTS * remaining_ratio))
    return max(MIN_CORRECT_POINTS, raw_points)


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
        fields = [
            "id",
            "title",
            "description",
            "question_only_on_display",
            "show_choices_on_participant",
            "reading_time_sec",
            "results_time_sec",
            "questions",
        ]


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
    current_question = serializers.SerializerMethodField()
    phase_ends_at = serializers.SerializerMethodField()
    question_ends_at = serializers.SerializerMethodField()
    is_answer_revealed = serializers.SerializerMethodField()

    class Meta:
        model = LiveSession
        fields = [
            "id",
            "quiz",
            "host_name",
            "status",
            "phase",
            "pin",
            "join_token",
            "join_url",
            "qr_code_base64",
            "participants_count",
            "current_question",
            "phase_started_at",
            "phase_ends_at",
            "question_started_at",
            "question_ends_at",
            "is_answer_revealed",
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

    def get_current_question(self, obj: LiveSession):
        return serialize_question_for_participants(obj.current_question, obj)

    def get_is_answer_revealed(self, obj: LiveSession) -> bool:
        if obj.current_question_id is None:
            return False
        return obj.revealed_question_id == obj.current_question_id

    def get_question_ends_at(self, obj: LiveSession):
        ends_at = compute_question_ends_at(obj, obj.current_question)
        return ends_at.isoformat() if ends_at else None

    def get_phase_ends_at(self, obj: LiveSession):
        ends_at = compute_phase_ends_at(obj)
        return ends_at.isoformat() if ends_at else None


class ParticipantJoinSerializer(serializers.Serializer):
    pin = serializers.CharField(max_length=6, required=False, allow_blank=True)
    join_token = serializers.UUIDField(required=False)
    phone = serializers.CharField(max_length=32, required=False, allow_blank=True)
    name = serializers.CharField(max_length=255)
    consent = serializers.BooleanField()

    def validate(self, attrs):
        if not attrs["consent"]:
            raise serializers.ValidationError("Consent is required to join quiz sessions.")

        pin = (attrs.get("pin") or "").strip()
        join_token = attrs.get("join_token")
        if not pin and not join_token:
            raise serializers.ValidationError("PIN or join token is required.")

        session_lookup = LiveSession.objects.select_related("quiz", "current_question").prefetch_related(
            "current_question__choices",
            "participants",
        )

        try:
            if join_token is not None:
                session = session_lookup.get(join_token=join_token)
            else:
                session = session_lookup.get(pin=pin)
        except LiveSession.DoesNotExist as exc:
            raise serializers.ValidationError("Session was not found by provided PIN/token.") from exc

        if session.status == LiveSession.STATUS_FINISHED:
            raise serializers.ValidationError("Session is already finished.")
        if session.status == LiveSession.STATUS_ABORTED:
            raise serializers.ValidationError("Session was stopped by teacher.")

        attrs["session"] = session
        return attrs

    def create(self, validated_data):
        phone = (validated_data.get("phone") or "").strip() or make_guest_phone()
        name = validated_data["name"]
        consent = validated_data["consent"]
        session = validated_data["session"]

        privacy_policy_version, personal_data_consent_version = get_current_consent_versions()
        consent_given_at = timezone.now() if consent else None

        participant, created = Participant.objects.get_or_create(
            phone=phone,
            defaults={
                "name": name,
                "consent": consent,
                "consent_given_at": consent_given_at,
                "privacy_policy_version": privacy_policy_version,
                "personal_data_consent_version": personal_data_consent_version,
            },
        )
        if not created:
            participant.name = name
            participant.consent = consent
            participant.consent_given_at = consent_given_at
            participant.privacy_policy_version = privacy_policy_version
            participant.personal_data_consent_version = personal_data_consent_version
            participant.save(
                update_fields=[
                    "name",
                    "consent",
                    "consent_given_at",
                    "privacy_policy_version",
                    "personal_data_consent_version",
                ]
            )

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
            session_participant = SessionParticipant.objects.select_related(
                "session",
                "session__current_question",
            ).get(id=attrs["session_participant_id"])
        except SessionParticipant.DoesNotExist as exc:
            raise serializers.ValidationError("Participant session link was not found.") from exc

        session = session_participant.session
        if session.status != LiveSession.STATUS_LIVE:
            raise serializers.ValidationError("Session is not active.")

        if session.phase != LiveSession.PHASE_ANSWERING:
            raise serializers.ValidationError("Question is not accepting answers right now.")

        if session.current_question_id is None:
            raise serializers.ValidationError("No active question right now. Wait for teacher signal.")

        if session.current_question_id != attrs["question_id"]:
            raise serializers.ValidationError("This question is not active right now.")

        if session.revealed_question_id == attrs["question_id"]:
            raise serializers.ValidationError("Answers for this question are already revealed.")

        if session.question_started_at is None:
            raise serializers.ValidationError("Question timer is not initialized.")

        try:
            question = Question.objects.get(id=attrs["question_id"], quiz_id=session.quiz_id)
        except Question.DoesNotExist as exc:
            raise serializers.ValidationError("Question was not found in this session quiz.") from exc

        try:
            choice = Choice.objects.get(id=attrs["choice_id"], question_id=question.id)
        except Choice.DoesNotExist as exc:
            raise serializers.ValidationError("Choice was not found for this question.") from exc

        question_ends_at = compute_question_ends_at(session, question)
        now = timezone.now()
        if question_ends_at and now > question_ends_at:
            raise serializers.ValidationError("Time is over for this question.")

        if ParticipantAnswer.objects.filter(session_participant=session_participant, question=question).exists():
            raise serializers.ValidationError("Answer for this question has already been submitted.")

        elapsed_ms = int(max(0, (now - session.question_started_at).total_seconds() * 1000))

        attrs["session_participant"] = session_participant
        attrs["question"] = question
        attrs["choice"] = choice
        attrs["elapsed_ms"] = elapsed_ms
        return attrs

    def create(self, validated_data):
        session_participant = validated_data["session_participant"]
        question = validated_data["question"]
        choice = validated_data["choice"]
        elapsed_ms = validated_data["elapsed_ms"]

        points = score_for_answer(question, elapsed_ms, choice.is_correct)

        answer = ParticipantAnswer.objects.create(
            session_participant=session_participant,
            question=question,
            choice=choice,
            is_correct=choice.is_correct,
            score_points=points,
            elapsed_ms=elapsed_ms,
        )

        total_points = (
            ParticipantAnswer.objects.filter(session_participant=session_participant)
            .aggregate(total=Coalesce(Sum("score_points"), 0))
            .get("total", 0)
        )
        correct_answers = ParticipantAnswer.objects.filter(
            session_participant=session_participant,
            is_correct=True,
        ).count()

        return {
            "answer_id": answer.id,
            "is_correct": answer.is_correct,
            "score_points": answer.score_points,
            "elapsed_ms": answer.elapsed_ms,
            "total_points": int(total_points or 0),
            "correct_answers": correct_answers,
        }


class LeaderboardRowSerializer(serializers.Serializer):
    participant_name = serializers.CharField()
    phone = serializers.CharField()
    points = serializers.IntegerField()
    correct_answers = serializers.IntegerField()
    answer_time_ms = serializers.IntegerField()


def build_leaderboard(session: LiveSession):
    rows = (
        SessionParticipant.objects.filter(session=session)
        .select_related("participant")
        .annotate(
            points=Coalesce(Sum("answers__score_points"), 0),
            correct_answers=Count("answers", filter=Q(answers__is_correct=True)),
            answer_time_ms=Coalesce(Sum("answers__elapsed_ms"), 0),
        )
        .order_by("-points", "-correct_answers", "answer_time_ms", "joined_at")
    )
    return [
        {
            "participant_name": row.participant.name,
            "phone": display_participant_phone(row.participant.phone),
            "points": int(row.points or 0),
            "correct_answers": row.correct_answers,
            "answer_time_ms": int(row.answer_time_ms or 0),
        }
        for row in rows
    ]
