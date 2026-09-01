from django.apps import AppConfig


class SessionConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.session"
    verbose_name = 'Проведение'

    def ready(self):
        from django.db.models.signals import pre_delete
        from apps.core.protection import prevent_history_delete
        from apps.quiz.models import Quiz, Question, Choice
        from apps.session.models import LiveSession, SessionParticipant, ParticipantAnswer

        for model in (Quiz, Question, Choice, LiveSession, SessionParticipant, ParticipantAnswer):
            pre_delete.connect(prevent_history_delete, sender=model, dispatch_uid=f'history_guard_{model._meta.label_lower}')
