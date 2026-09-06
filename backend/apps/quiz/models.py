from django.db import models


from django.conf import settings
from apps.core.protection import GuardedModel, HistoryConflict


def _require_content_service():
    from apps.quiz.services import _quiz_content_write_allowed

    if not _quiz_content_write_allowed():
        raise HistoryConflict(
            'Прямая запись содержимого викторины запрещена; используйте прикладной сервис.'
        )


class Quiz(GuardedModel):
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name='quizzes', verbose_name='Владелец')
    archived_at = models.DateTimeField(null=True, blank=True, editable=False)
    content_revision = models.PositiveBigIntegerField(default=1, editable=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        verbose_name = 'викторина'
        verbose_name_plural = 'викторины'

    def __str__(self) -> str:
        return f'Викторина {self.pk}'

    def save(self, *args, **kwargs):
        _require_content_service()
        return super().save(*args, **kwargs)


class QuizVersion(GuardedModel):
    STATUS_DRAFT = 'draft'
    STATUS_FIXED = 'fixed'

    STATUS_CHOICES = [
        (STATUS_DRAFT, 'Черновик'),
        (STATUS_FIXED, 'Зафиксированная версия'),
    ]

    quiz = models.ForeignKey(
        Quiz,
        related_name='versions',
        on_delete=models.CASCADE,
    )
    number = models.PositiveIntegerField()
    status = models.CharField(
        max_length=16,
        choices=STATUS_CHOICES,
        default=STATUS_DRAFT,
    )
    fixed_at = models.DateTimeField(null=True, blank=True)
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    question_only_on_display = models.BooleanField(default=False)
    show_choices_on_participant = models.BooleanField(default=True)
    reading_time_sec = models.PositiveIntegerField(default=15)
    results_time_sec = models.PositiveIntegerField(default=10)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['number', 'id']
        verbose_name = 'версия викторины'
        verbose_name_plural = 'версии викторин'
        constraints = [
            models.UniqueConstraint(
                fields=['quiz', 'number'],
                name='uniq_quiz_version_number',
            ),
            models.UniqueConstraint(
                fields=['quiz'],
                condition=models.Q(status='draft'),
                name='uniq_quiz_draft_version',
            ),
            models.CheckConstraint(
                condition=(
                    models.Q(status='draft', fixed_at__isnull=True)
                    | models.Q(status='fixed', fixed_at__isnull=False)
                ),
                name='quiz_version_status_fixed_at',
            ),
        ]

    def __str__(self) -> str:
        return f'{self.quiz_id}:{self.number}:{self.status}'

    def save(self, *args, **kwargs):
        _require_content_service()
        return super().save(*args, **kwargs)


class Question(GuardedModel):
    quiz_version = models.ForeignKey(
        QuizVersion,
        related_name='questions',
        on_delete=models.CASCADE,
        editable=False,
    )
    text = models.TextField()
    order = models.PositiveIntegerField(default=1)
    time_limit_sec = models.PositiveIntegerField(default=20)

    class Meta:
        ordering = ["order", "id"]
        verbose_name = 'вопрос'
        verbose_name_plural = 'вопросы'
        constraints = [
            models.UniqueConstraint(
                fields=['quiz_version', 'order'],
                name='uniq_question_version_order',
                deferrable=models.Deferrable.DEFERRED,
            ),
        ]

    def __str__(self) -> str:
        return f"{self.quiz_version_id}: {self.text[:40]}"

    def save(self, *args, **kwargs):
        _require_content_service()
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
        constraints = [
            models.UniqueConstraint(
                fields=['question', 'order'],
                name='uniq_choice_question_order',
                deferrable=models.Deferrable.DEFERRED,
            ),
        ]

    def __str__(self) -> str:
        return f"{self.question_id}:{self.text[:40]}"

    def save(self, *args, **kwargs):
        _require_content_service()
        return super().save(*args, **kwargs)
