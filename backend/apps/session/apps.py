from django.apps import AppConfig


class SessionConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.session"
    verbose_name = 'Проведение'

    def ready(self):
        from django.db.models.signals import pre_delete
        from apps.core.protection import prevent_history_delete
        from apps.quiz.models import Quiz, QuizVersion, Question, Choice
        from apps.session.models import (
            AnswerAttempt,
            FinalAnswer,
            LegacyParticipantAnswer,
            LiveSession,
            SessionCommand,
            SessionDisplayAccess,
            SessionParticipant,
            SessionQuestionRun,
        )

        for model in (
            Quiz,
            QuizVersion,
            Question,
            Choice,
            LiveSession,
            SessionParticipant,
            LegacyParticipantAnswer,
            SessionQuestionRun,
            AnswerAttempt,
            FinalAnswer,
            SessionCommand,
            SessionDisplayAccess,
        ):
            pre_delete.connect(prevent_history_delete, sender=model, dispatch_uid=f'history_guard_{model._meta.label_lower}')
