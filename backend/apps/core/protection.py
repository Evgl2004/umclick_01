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
        from apps.quiz.services import _quiz_content_write_allowed

        with transaction.atomic(using=self.db):
            if _quiz_content_write_allowed():
                return super().delete()
            paths = {
                'quiz.quiz': 'pk',
                'quiz.quizversion': 'quiz_id',
                'quiz.question': 'quiz_version__quiz_id',
                'quiz.choice': 'question__quiz_version__quiz_id',
            }
            path = paths.get(self.model._meta.label_lower)
            if path:
                if self.model._meta.label_lower != 'quiz.quiz':
                    raise HistoryConflict(
                        'Прямое удаление содержимого викторины запрещено.'
                    )
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

    session = LiveSession.objects.using(using).filter(
        quiz_version__quiz_id=quiz_id
    ).only('join_token').first()
    if session:
        error = HistoryConflict('Викторина уже использована. Изменение и удаление её содержимого запрещены.')
        error.blocking_session_uuid = session.join_token
        raise error


def prevent_history_delete(sender, instance, using, origin=None, **kwargs):
    from apps.quiz.models import Quiz
    from apps.quiz.services import _quiz_content_write_allowed

    label = sender._meta.label_lower
    if label in {
        'session.livesession',
        'session.sessionparticipant',
        'session.legacyparticipantanswer',
        'session.sessionquestionrun',
        'session.answerattempt',
        'session.finalanswer',
        'session.sessioncommand',
    }:
        raise HistoryConflict('Удаление игровой истории запрещено.')
    if label.startswith('quiz.'):
        if _quiz_content_write_allowed():
            return
        root_model = getattr(origin, 'model', None)
        cascade_from_quiz = isinstance(origin, Quiz) or root_model is Quiz
        if label != 'quiz.quiz' and not cascade_from_quiz:
            raise HistoryConflict('Прямое удаление содержимого викторины запрещено.')
        if label == 'quiz.quiz':
            quiz_id = instance.pk
        elif label == 'quiz.quizversion':
            quiz_id = instance.quiz_id
        elif label == 'quiz.question':
            quiz_id = instance.quiz_version.quiz_id
        else:
            quiz_id = instance.question.quiz_version.quiz_id
        Quiz.objects.using(using).select_for_update().get(pk=quiz_id)
        ensure_unused(quiz_id, using)
