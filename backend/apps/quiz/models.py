from django.db import models


from django.conf import settings
from django.db import transaction

from apps.core.protection import GuardedModel, HistoryConflict, ensure_unused


class Quiz(GuardedModel):
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name='quizzes', verbose_name='Владелец')
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    question_only_on_display = models.BooleanField(default=False)
    show_choices_on_participant = models.BooleanField(default=True)
    reading_time_sec = models.PositiveIntegerField(default=15)
    results_time_sec = models.PositiveIntegerField(default=10)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        verbose_name = 'викторина'
        verbose_name_plural = 'викторины'

    def __str__(self) -> str:
        return self.title

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        with transaction.atomic(using=using):
            if self.pk:
                previous = Quiz.objects.using(using).select_for_update().get(pk=self.pk)
                ensure_unused(self.pk, using)
                if previous.owner_id != self.owner_id:
                    raise HistoryConflict('Перенос владельца викторины запрещён.')
            return super().save(*args, **kwargs)


class Question(GuardedModel):
    quiz = models.ForeignKey(Quiz, related_name="questions", on_delete=models.CASCADE)
    text = models.TextField()
    order = models.PositiveIntegerField(default=1)
    time_limit_sec = models.PositiveIntegerField(default=20)

    class Meta:
        ordering = ["order", "id"]
        verbose_name = 'вопрос'
        verbose_name_plural = 'вопросы'

    def __str__(self) -> str:
        return f"{self.quiz.title}: {self.text[:40]}"

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        with transaction.atomic(using=using):
            Quiz.objects.using(using).select_for_update().get(pk=self.quiz_id)
            ensure_unused(self.quiz_id, using)
            if self.pk and Question.objects.using(using).filter(pk=self.pk).exclude(quiz_id=self.quiz_id).exists():
                raise HistoryConflict('Перенос вопроса в другую викторину запрещён.')
            return super().save(*args, **kwargs)


class Choice(GuardedModel):
    question = models.ForeignKey(Question, related_name="choices", on_delete=models.CASCADE)
    text = models.CharField(max_length=255)
    is_correct = models.BooleanField(default=False)
    order = models.PositiveIntegerField(default=1)

    class Meta:
        ordering = ["order", "id"]
        verbose_name = 'вариант ответа'
        verbose_name_plural = 'варианты ответов'

    def __str__(self) -> str:
        return f"{self.question_id}:{self.text[:40]}"

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        with transaction.atomic(using=using):
            quiz_id = Question.objects.using(using).values_list('quiz_id', flat=True).get(pk=self.question_id)
            Quiz.objects.using(using).select_for_update().get(pk=quiz_id)
            ensure_unused(quiz_id, using)
            if self.pk and Choice.objects.using(using).filter(pk=self.pk).exclude(question_id=self.question_id).exists():
                raise HistoryConflict('Перенос варианта в другой вопрос запрещён.')
            return super().save(*args, **kwargs)
