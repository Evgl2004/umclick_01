from django.core.exceptions import ValidationError
from django.db import models, transaction


class HistoryConflict(ValidationError):
    """Операция нарушает сохранность истории."""


class GuardedQuerySet(models.QuerySet):
    def update(self, **kwargs):
        raise HistoryConflict('Массовое изменение защищённых записей запрещено.')

    def bulk_update(self, objs, fields, batch_size=None):
        raise HistoryConflict('Массовое изменение защищённых записей запрещено.')

    def bulk_create(self, objs, **kwargs):
        raise HistoryConflict('Массовое создание защищённых записей запрещено.')

    def delete(self):
        from apps.quiz.models import Quiz

        with transaction.atomic(using=self.db):
            paths = {'quiz.quiz': 'pk', 'quiz.question': 'quiz_id', 'quiz.choice': 'question__quiz_id'}
            path = paths.get(self.model._meta.label_lower)
            if path:
                ids = self.values_list(path, flat=True)
                for quiz in Quiz.objects.using(self.db).select_for_update().filter(pk__in=ids).order_by('pk'):
                    ensure_unused(quiz.pk, self.db)
            return super().delete()


class GuardedModel(models.Model):
    objects = GuardedQuerySet.as_manager()

    class Meta:
        abstract = True

    def delete(self, using=None, keep_parents=False):
        return type(self).objects.using(using or self._state.db or 'default').filter(pk=self.pk).delete()


def ensure_unused(quiz_id, using='default'):
    from apps.session.models import LiveSession

    session = LiveSession.objects.using(using).filter(quiz_id=quiz_id).only('join_token').first()
    if session:
        error = HistoryConflict('Викторина уже использована. Изменение и удаление её содержимого запрещены.')
        error.blocking_session_uuid = session.join_token
        raise error


def prevent_history_delete(sender, instance, using, **kwargs):
    from apps.quiz.models import Quiz

    label = sender._meta.label_lower
    if label in {'session.livesession', 'session.sessionparticipant', 'session.participantanswer'}:
        raise HistoryConflict('Удаление игровой истории запрещено.')
    if label.startswith('quiz.'):
        quiz_id = instance.pk if label == 'quiz.quiz' else (
            instance.quiz_id if label == 'quiz.question' else instance.question.quiz_id
        )
        Quiz.objects.using(using).select_for_update().get(pk=quiz_id)
        ensure_unused(quiz_id, using)
