from django.contrib import admin

from apps.session.models import (
    AnswerAttempt,
    FinalAnswer,
    LegacyParticipantAnswer,
    LiveSession,
    Participant,
    SessionCommand,
    SessionParticipant,
    SessionQuestionRun,
)


class HistoryAdmin(admin.ModelAdmin):
    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def get_fields(self, request, obj=None):
        return [field.name for field in self.model._meta.fields if field.name != 'token_digest']

    def get_readonly_fields(self, request, obj=None):
        return self.get_fields(request, obj)


@admin.register(LiveSession)
class LiveSessionAdmin(HistoryAdmin):
    list_display = (
        "id",
        "pin",
        "quiz",
        "status",
        "phase",
        "current_question",
        "revealed_question_id",
        "created_at",
    )
    list_filter = ("status", "phase", "created_at")
    search_fields = ("pin", "quiz_version__title", "host_name")

    @admin.display(description='Викторина', ordering='quiz_version__quiz_id')
    def quiz(self, obj):
        return obj.quiz_version.quiz

    def get_fields(self, request, obj=None):
        fields = [
            field_name
            for field_name in super().get_fields(request, obj)
            if field_name != 'quiz_version'
        ]
        fields.insert(1, 'quiz')
        return fields


@admin.register(Participant)
class ParticipantAdmin(admin.ModelAdmin):
    def get_readonly_fields(self, request, obj=None):
        return ('user',) if obj else ()
    list_display = ("id", "name", "phone", "consent", "consent_given_at", "privacy_policy_version", "personal_data_consent_version", "created_at")
    search_fields = ("name", "phone")


@admin.register(SessionParticipant)
class SessionParticipantAdmin(HistoryAdmin):
    list_display = ("id", "session", "participant", "joined_at")
    list_filter = ("session",)


@admin.register(LegacyParticipantAnswer)
class LegacyParticipantAnswerAdmin(HistoryAdmin):
    list_display = (
        "id",
        "session_participant",
        "question",
        "choice",
        "is_correct",
        "score_points",
        "elapsed_ms",
        "answered_at",
    )
    list_filter = ("is_correct",)


@admin.register(SessionQuestionRun)
class SessionQuestionRunAdmin(HistoryAdmin):
    list_display = ('id', 'session', 'question', 'ordinal', 'answer_deadline_at', 'delivery_deadline_at', 'finalized_at')
    list_filter = ('finalized_at',)


@admin.register(AnswerAttempt)
class AnswerAttemptAdmin(HistoryAdmin):
    list_display = ('id', 'run', 'session_participant', 'choice', 'submission_id', 'ordinal', 'admitted_at')


@admin.register(FinalAnswer)
class FinalAnswerAdmin(HistoryAdmin):
    list_display = ('id', 'run', 'session_participant', 'outcome', 'is_correct', 'ranking_elapsed_ms')
    list_filter = ('outcome', 'is_correct')


@admin.register(SessionCommand)
class SessionCommandAdmin(HistoryAdmin):
    list_display = ('id', 'session', 'kind', 'command_id', 'expected_revision', 'applied_revision', 'created_at')
