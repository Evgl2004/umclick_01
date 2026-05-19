from django.contrib import admin

from apps.session.models import LiveSession, Participant, ParticipantAnswer, SessionParticipant


@admin.register(LiveSession)
class LiveSessionAdmin(admin.ModelAdmin):
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
    search_fields = ("pin", "quiz__title", "host_name")


@admin.register(Participant)
class ParticipantAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "phone", "consent", "consent_given_at", "privacy_policy_version", "personal_data_consent_version", "created_at")
    search_fields = ("name", "phone")


@admin.register(SessionParticipant)
class SessionParticipantAdmin(admin.ModelAdmin):
    list_display = ("id", "session", "participant", "joined_at")
    list_filter = ("session",)


@admin.register(ParticipantAnswer)
class ParticipantAnswerAdmin(admin.ModelAdmin):
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
