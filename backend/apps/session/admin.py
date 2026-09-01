from django.contrib import admin

from apps.session.models import LiveSession, Participant, ParticipantAnswer, SessionParticipant


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
    search_fields = ("pin", "quiz__title", "host_name")


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


@admin.register(ParticipantAnswer)
class ParticipantAnswerAdmin(HistoryAdmin):
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
