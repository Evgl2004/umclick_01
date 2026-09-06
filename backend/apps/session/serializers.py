import base64
import io
import os

import qrcode
from rest_framework import serializers

from apps.quiz.models import Choice, Question, Quiz, QuizVersion
from apps.session.models import LiveSession
from apps.session.realtime import compute_phase_ends_at, compute_question_ends_at, serialize_question_for_participants
from apps.session.results import build_leaderboard as build_result_leaderboard


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
    id = serializers.IntegerField(source='quiz_id', read_only=True)
    questions = SessionQuestionSerializer(many=True)

    class Meta:
        model = QuizVersion
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
    id = serializers.UUIDField(source='join_token', read_only=True)
    quiz = serializers.PrimaryKeyRelatedField(
        queryset=Quiz.objects.none(),
        write_only=True,
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.core.permissions import is_admin
        user = self.context['request'].user
        self.fields['quiz'].queryset = Quiz.objects.all() if is_admin(user) else Quiz.objects.filter(owner=user)

    class Meta:
        model = LiveSession
        fields = ["id", "quiz", "host_name", "status", "pin", "join_token", "created_at"]
        read_only_fields = ["id", "status", "pin", "join_token", "created_at"]

    def create(self, validated_data):
        from apps.session.services import create_live_session

        quiz = validated_data.pop('quiz')
        return create_live_session(
            quiz_id=quiz.pk,
            actor=self.context['request'].user,
            host_name=validated_data.get('host_name', ''),
        )

    def to_representation(self, instance):
        representation = super().to_representation(instance)
        representation['quiz'] = instance.quiz_version.quiz_id
        return representation


class LiveSessionSerializer(serializers.ModelSerializer):
    id = serializers.UUIDField(source='join_token', read_only=True)
    quiz = SessionQuizSerializer(source='quiz_version')
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
            "state_revision",
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


class SessionCommandInputSerializer(serializers.Serializer):
    command_id = serializers.UUIDField()
    state_revision = serializers.IntegerField(min_value=0)
    phase = serializers.ChoiceField(choices=LiveSession.PHASE_CHOICES)
    question_run_id = serializers.IntegerField(min_value=1, required=False, allow_null=True)

    def validate(self, attrs):
        allowed = {'command_id', 'state_revision', 'phase', 'question_run_id'}
        unknown = set(self.initial_data) - allowed
        if unknown:
            raise serializers.ValidationError(
                {'detail': f"Недопустимые поля команды: {', '.join(sorted(unknown))}."}
            )
        return attrs


class SubmitAnswerSerializer(serializers.Serializer):
    question_id = serializers.IntegerField()
    choice_id = serializers.IntegerField()
    submission_id = serializers.UUIDField()

    def validate(self, attrs):
        allowed = {'question_id', 'choice_id', 'submission_id'}
        unknown = set(self.initial_data) - allowed
        if unknown:
            raise serializers.ValidationError(
                {'detail': f"Недопустимые поля запроса: {', '.join(sorted(unknown))}."}
            )
        return attrs

    def create(self, validated_data):
        from apps.session.gameplay import record_answer_attempt
        participation = self.context['participation']
        return record_answer_attempt(
            session_id=participation.session_id,
            participation_id=participation.pk,
            **validated_data,
        )


def build_leaderboard(session: LiveSession):
    return build_result_leaderboard(session, include_phone=True)
