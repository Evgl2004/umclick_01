import secrets
import uuid

from django.conf import settings
from django.db import IntegrityError, models, transaction
from datetime import timedelta
from django.utils import timezone

from apps.quiz.models import Choice, Question, Quiz, QuizVersion
from apps.core.protection import GuardedModel, HistoryConflict


def generate_pin() -> str:
    return ''.join(secrets.choice('0123456789') for _ in range(6))


class LiveSession(GuardedModel):
    STATUS_WAITING = "waiting"
    STATUS_LIVE = "live"
    STATUS_FINISHED = "finished"
    STATUS_ABORTED = "aborted"

    PHASE_LOBBY = "lobby"
    PHASE_READING = "reading"
    PHASE_ANSWERING = "answering"
    PHASE_DELIVERY = "delivery"
    PHASE_RESULTS = "results"
    PHASE_FINAL = "final"

    GAMEPLAY_SCHEMA_LEGACY = "legacy"
    GAMEPLAY_SCHEMA_V2 = "v2"

    STATUS_CHOICES = [
        (STATUS_WAITING, "Waiting"),
        (STATUS_LIVE, "Live"),
        (STATUS_FINISHED, "Finished"),
        (STATUS_ABORTED, "Aborted"),
    ]

    PHASE_CHOICES = [
        (PHASE_LOBBY, "Lobby"),
        (PHASE_READING, "Reading"),
        (PHASE_ANSWERING, "Answering"),
        (PHASE_DELIVERY, "Доставка"),
        (PHASE_RESULTS, "Results"),
        (PHASE_FINAL, "Final"),
    ]

    GAMEPLAY_SCHEMA_CHOICES = [
        (GAMEPLAY_SCHEMA_LEGACY, "Временная схема этапа А"),
        (GAMEPLAY_SCHEMA_V2, "Схема проведения этапа Б"),
    ]

    quiz = models.ForeignKey(Quiz, related_name="sessions", on_delete=models.PROTECT)
    quiz_version = models.ForeignKey(
        QuizVersion,
        related_name='sessions',
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        editable=False,
    )
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, related_name='created_sessions', on_delete=models.PROTECT, verbose_name='Создатель')
    host_name = models.CharField(max_length=255, blank=True)
    pin = models.CharField(max_length=6, db_index=True)
    join_token = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    status = models.CharField(max_length=16, choices=STATUS_CHOICES, default=STATUS_WAITING)
    phase = models.CharField(max_length=16, choices=PHASE_CHOICES, default=PHASE_LOBBY)
    gameplay_schema = models.CharField(
        max_length=16,
        choices=GAMEPLAY_SCHEMA_CHOICES,
        default=GAMEPLAY_SCHEMA_V2,
        editable=False,
    )
    state_revision = models.PositiveBigIntegerField(default=0, editable=False)
    current_question = models.ForeignKey(
        Question,
        related_name="active_sessions",
        on_delete=models.PROTECT,
        null=True,
        blank=True,
    )
    current_run = models.ForeignKey(
        "SessionQuestionRun",
        related_name="current_for_sessions",
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        editable=False,
    )
    revealed_question_id = models.PositiveIntegerField(null=True, blank=True)
    phase_started_at = models.DateTimeField(null=True, blank=True)
    question_started_at = models.DateTimeField(null=True, blank=True)
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        verbose_name = 'сессия'
        verbose_name_plural = 'сессии'
        constraints = [models.UniqueConstraint(fields=['pin'], condition=models.Q(status__in=['waiting', 'live']), name='uniq_open_session_pin')]

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        with transaction.atomic(using=using):
            old = None
            if self.pk is not None:
                old = LiveSession.objects.using(using).select_for_update().filter(pk=self.pk).first()
            if self.current_question_id and not Question.objects.using(using).filter(pk=self.current_question_id, quiz_id=self.quiz_id).exists():
                raise HistoryConflict('Текущий вопрос не принадлежит викторине сессии.')
            if self.current_run_id:
                run_matches = SessionQuestionRun.objects.using(using).filter(
                    pk=self.current_run_id,
                    session_id=self.pk,
                    question_id=self.current_question_id,
                ).exists()
                if not run_matches:
                    raise HistoryConflict('Текущий запуск вопроса не соответствует сессии и текущему вопросу.')
            if old is None:
                quiz = Quiz.objects.using(using).select_for_update().get(pk=self.quiz_id)
                from apps.quiz.validation import validate_quiz_instance
                validate_quiz_instance(quiz)
            else:
                fixed = ['quiz_id', 'created_by_id', 'join_token', 'pin', 'created_at', 'gameplay_schema']
                if old.status in {self.STATUS_FINISHED, self.STATUS_ABORTED}:
                    fixed = [field.attname for field in self._meta.concrete_fields]
                if any(getattr(old, field) != getattr(self, field) for field in fixed):
                    raise HistoryConflict('Перенос связей или изменение завершённой сессии запрещены.')
                if old.status != self.STATUS_WAITING and self.status == self.STATUS_WAITING:
                    raise HistoryConflict('Повторное открытие регистрации запрещено.')
                if old.started_at and self.started_at != old.started_at:
                    raise HistoryConflict('Изменение времени начала сессии запрещено.')
            if self.status == self.STATUS_LIVE and self.started_at is None:
                self.started_at = timezone.now()
                if kwargs.get('update_fields') is not None:
                    kwargs['update_fields'] = set(kwargs['update_fields']) | {'started_at'}
            if self.status in {self.STATUS_FINISHED, self.STATUS_ABORTED} and self.finished_at is None:
                self.finished_at = timezone.now()
                if kwargs.get('update_fields') is not None:
                    kwargs['update_fields'] = set(kwargs['update_fields']) | {'finished_at'}
            generated = not self.pin
            for attempt in range(20):
                if generated:
                    self.pin = generate_pin()
                try:
                    with transaction.atomic(using=using):
                        save_kwargs = {**kwargs}
                        if old is None:
                            save_kwargs.pop('force_update', None)
                            save_kwargs['force_insert'] = True
                        else:
                            save_kwargs.pop('force_insert', None)
                            save_kwargs['force_update'] = True
                        return super().save(*args, **save_kwargs)
                except IntegrityError as exc:
                    if old is None and self.pk is not None and LiveSession.objects.using(using).filter(pk=self.pk).exists():
                        raise HistoryConflict('Сессия с таким идентификатором уже существует.') from exc
                    if not generated or not LiveSession.objects.using(using).filter(pin=self.pin, status__in=['waiting', 'live']).exists():
                        raise
                    if attempt == 19:
                        raise HistoryConflict('Не удалось подобрать свободный PIN. Повторите создание сессии.') from exc

    def __str__(self) -> str:
        return f'Сессия {self.pin} ({self.quiz.title})'


class Participant(GuardedModel):
    user = models.OneToOneField(settings.AUTH_USER_MODEL, null=True, blank=True, related_name='participant_profile', on_delete=models.PROTECT, verbose_name='Учётная запись')
    phone = models.CharField(max_length=32, null=True, blank=True)
    name = models.CharField(max_length=255)
    consent = models.BooleanField(default=False)
    consent_given_at = models.DateTimeField(null=True, blank=True)
    privacy_policy_version = models.CharField(max_length=32, blank=True)
    personal_data_consent_version = models.CharField(max_length=32, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.name} ({self.phone})"

    def save(self, *args, **kwargs):
        if self.pk and Participant.objects.filter(pk=self.pk).exclude(user_id=self.user_id).exists():
            raise HistoryConflict('Перенос участника на другую учётную запись запрещён.')
        self.phone = (self.phone or '').strip() or None
        return super().save(*args, **kwargs)


class SessionParticipant(GuardedModel):
    session = models.ForeignKey(LiveSession, related_name="participants", on_delete=models.PROTECT)
    participant = models.ForeignKey(Participant, related_name="session_links", on_delete=models.PROTECT)
    token_digest = models.CharField(max_length=64, unique=True, editable=False, verbose_name='Отпечаток токена')
    name_snapshot = models.CharField(max_length=255, verbose_name='Имя в сессии')
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["session", "participant"], name="uniq_session_participant"),
        ]

    def __str__(self) -> str:
        return f"{self.participant.name} -> {self.session.pin}"

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        with transaction.atomic(using=using):
            old = None
            if self.pk is not None:
                old = SessionParticipant.objects.using(using).select_for_update().filter(pk=self.pk).first()
            if old is not None:
                raise HistoryConflict('Изменение зарегистрированного участия запрещено.')
            session = LiveSession.objects.using(using).select_for_update().get(pk=self.session_id)
            if session.status != LiveSession.STATUS_WAITING:
                raise HistoryConflict('Регистрация закрыта.')
            if len(self.token_digest) != 64 or not self.name_snapshot.strip():
                raise HistoryConflict('Участию необходимы отпечаток токена и имя.')
            try:
                with transaction.atomic(using=using):
                    return super().save(*args, **{**kwargs, 'force_insert': True})
            except IntegrityError as exc:
                if self.pk is not None and SessionParticipant.objects.using(using).filter(pk=self.pk).exists():
                    raise HistoryConflict('Участие с таким идентификатором уже существует.') from exc
                raise


class LegacyParticipantAnswer(GuardedModel):
    session_participant = models.ForeignKey(
        SessionParticipant,
        related_name="answers",
        on_delete=models.PROTECT,
    )
    question = models.ForeignKey(Question, related_name="session_answers", on_delete=models.PROTECT)
    choice = models.ForeignKey(Choice, related_name="answers", on_delete=models.PROTECT, null=True, blank=True)
    is_correct = models.BooleanField(default=False)
    score_points = models.PositiveIntegerField(default=0)
    elapsed_ms = models.PositiveIntegerField(default=0)
    answered_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["session_participant", "question"],
                name="uniq_answer_per_question",
            ),
        ]

    def __str__(self) -> str:
        return f'Ответ участия {self.session_participant_id} на вопрос {self.question_id}'

    def save(self, *args, **kwargs):
        with transaction.atomic():
            session = LiveSession.objects.select_for_update().get(pk=self.session_participant.session_id)
            if session.status != LiveSession.STATUS_LIVE:
                raise HistoryConflict('Сессия не принимает ответы; история защищена.')
            if self.question.quiz_id != session.quiz_id or (self.choice_id and self.choice.question_id != self.question_id):
                raise HistoryConflict('Ответ не соответствует вопросу этой сессии.')
            if self.pk and LegacyParticipantAnswer.objects.filter(pk=self.pk).exclude(session_participant_id=self.session_participant_id, question_id=self.question_id).exists():
                raise HistoryConflict('Перенос исторического ответа запрещён.')
            return super().save(*args, **kwargs)


class SessionQuestionRun(GuardedModel):
    session = models.ForeignKey(LiveSession, related_name='question_runs', on_delete=models.PROTECT)
    question = models.ForeignKey(Question, related_name='session_runs', on_delete=models.PROTECT)
    ordinal = models.PositiveIntegerField()
    reading_started_at = models.DateTimeField()
    reading_ends_at = models.DateTimeField()
    answering_started_at = models.DateTimeField()
    planned_answer_deadline_at = models.DateTimeField()
    planned_delivery_deadline_at = models.DateTimeField()
    answer_deadline_at = models.DateTimeField()
    delivery_deadline_at = models.DateTimeField()
    finalized_at = models.DateTimeField(null=True, blank=True)
    results_started_at = models.DateTimeField(null=True, blank=True)
    results_ends_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ['session_id', 'ordinal', 'id']
        constraints = [
            models.UniqueConstraint(fields=['session', 'question'], name='uniq_run_session_question'),
            models.UniqueConstraint(fields=['session', 'ordinal'], name='uniq_run_session_ordinal'),
            models.CheckConstraint(
                condition=models.Q(reading_started_at__lte=models.F('reading_ends_at')),
                name='run_reading_dates_ordered',
            ),
            models.CheckConstraint(
                condition=models.Q(reading_ends_at__lte=models.F('answering_started_at')),
                name='run_answering_after_reading',
            ),
            models.CheckConstraint(
                condition=models.Q(answering_started_at__lte=models.F('planned_answer_deadline_at')),
                name='run_planned_answer_ordered',
            ),
            models.CheckConstraint(
                condition=models.Q(
                    planned_delivery_deadline_at=models.F('planned_answer_deadline_at') + timedelta(seconds=3),
                ),
                name='run_planned_delivery_3s',
            ),
            models.CheckConstraint(
                condition=models.Q(answering_started_at__lte=models.F('answer_deadline_at')),
                name='run_answer_deadline_ordered',
            ),
            models.CheckConstraint(
                condition=models.Q(answer_deadline_at__lte=models.F('delivery_deadline_at')),
                name='run_delivery_deadline_ordered',
            ),
            models.CheckConstraint(
                condition=models.Q(delivery_deadline_at=models.F('answer_deadline_at') + timedelta(seconds=3)),
                name='run_delivery_3s',
            ),
            models.CheckConstraint(
                condition=models.Q(answer_deadline_at__lte=models.F('planned_answer_deadline_at')),
                name='run_answer_not_extended',
            ),
            models.CheckConstraint(
                condition=models.Q(delivery_deadline_at__lte=models.F('planned_delivery_deadline_at')),
                name='run_delivery_not_extended',
            ),
            models.CheckConstraint(
                condition=(
                    models.Q(finalized_at__isnull=True, results_started_at__isnull=True, results_ends_at__isnull=True)
                    | models.Q(finalized_at__isnull=False, results_started_at__isnull=False, results_ends_at__isnull=False)
                ),
                name='run_results_dates_complete',
            ),
            models.CheckConstraint(
                condition=(
                    models.Q(results_started_at__isnull=True)
                    | models.Q(results_started_at__lte=models.F('results_ends_at'))
                ),
                name='run_results_dates_ordered',
            ),
        ]

    def __str__(self):
        return f'Запуск {self.ordinal} сессии {self.session_id}'

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        if self.question_id and self.session_id:
            quiz_id = LiveSession.objects.using(using).values_list('quiz_id', flat=True).get(pk=self.session_id)
            if not Question.objects.using(using).filter(pk=self.question_id, quiz_id=quiz_id).exists():
                raise HistoryConflict('Запуск вопроса не соответствует викторине сессии.')
        if self.pk:
            previous = type(self).objects.using(using).get(pk=self.pk)
            fixed = ('session_id', 'question_id', 'ordinal', 'reading_started_at', 'reading_ends_at',
                     'answering_started_at', 'planned_answer_deadline_at', 'planned_delivery_deadline_at')
            if any(getattr(previous, field) != getattr(self, field) for field in fixed):
                raise HistoryConflict('Перенос запуска вопроса и изменение его исходных сроков запрещены.')
            if previous.finalized_at and any(
                getattr(previous, field) != getattr(self, field)
                for field in ('answer_deadline_at', 'delivery_deadline_at', 'finalized_at', 'results_started_at', 'results_ends_at')
            ):
                raise HistoryConflict('Изменение финализированного запуска вопроса запрещено.')
        return super().save(*args, **kwargs)


class AnswerAttempt(GuardedModel):
    run = models.ForeignKey(SessionQuestionRun, related_name='attempts', on_delete=models.PROTECT)
    session_participant = models.ForeignKey(
        SessionParticipant,
        related_name='answer_attempts',
        on_delete=models.PROTECT,
    )
    choice = models.ForeignKey(Choice, related_name='answer_attempts', on_delete=models.PROTECT)
    submission_id = models.UUIDField()
    payload_digest = models.CharField(max_length=64, editable=False)
    admitted_at = models.DateTimeField()
    ordinal = models.PositiveSmallIntegerField()

    class Meta:
        ordering = ['admitted_at', 'id']
        constraints = [
            models.UniqueConstraint(
                fields=['run', 'session_participant', 'submission_id'],
                name='uniq_attempt_submission',
            ),
            models.UniqueConstraint(
                fields=['run', 'session_participant', 'ordinal'],
                name='uniq_attempt_ordinal',
            ),
            models.CheckConstraint(
                condition=models.Q(ordinal__gte=1, ordinal__lte=20),
                name='attempt_ordinal_1_20',
            ),
        ]
        indexes = [
            models.Index(fields=['run', 'session_participant', 'admitted_at'], name='attempt_run_part_time_idx'),
        ]

    def __str__(self):
        return f'Попытка {self.ordinal} участия {self.session_participant_id}'

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        if self.pk:
            raise HistoryConflict('Изменение сохранённой попытки запрещено.')
        run = SessionQuestionRun.objects.using(using).get(pk=self.run_id)
        participant = SessionParticipant.objects.using(using).get(pk=self.session_participant_id)
        if participant.session_id != run.session_id:
            raise HistoryConflict('Попытка не соответствует участию в сессии запуска.')
        if not Choice.objects.using(using).filter(pk=self.choice_id, question_id=run.question_id).exists():
            raise HistoryConflict('Вариант попытки не соответствует вопросу запуска.')
        if len(self.payload_digest) != 64 or not 1 <= self.ordinal <= 20:
            raise HistoryConflict('Попытка содержит недопустимые технические данные.')
        return super().save(*args, **{**kwargs, 'force_insert': True})


class FinalAnswer(GuardedModel):
    OUTCOME_ANSWERED = 'answered'
    OUTCOME_UNANSWERED = 'unanswered'
    OUTCOME_CHOICES = [
        (OUTCOME_ANSWERED, 'Ответ дан'),
        (OUTCOME_UNANSWERED, 'Ответ не дан'),
    ]

    run = models.ForeignKey(SessionQuestionRun, related_name='final_answers', on_delete=models.PROTECT)
    session_participant = models.ForeignKey(
        SessionParticipant,
        related_name='final_answers',
        on_delete=models.PROTECT,
    )
    selected_attempt = models.ForeignKey(
        AnswerAttempt,
        related_name='selected_by_finals',
        on_delete=models.PROTECT,
        null=True,
        blank=True,
    )
    timing_attempt = models.ForeignKey(
        AnswerAttempt,
        related_name='timed_by_finals',
        on_delete=models.PROTECT,
        null=True,
        blank=True,
    )
    outcome = models.CharField(max_length=16, choices=OUTCOME_CHOICES)
    is_correct = models.BooleanField(default=False)
    actual_elapsed_ms = models.PositiveIntegerField(null=True, blank=True)
    ranking_elapsed_ms = models.PositiveIntegerField(null=True, blank=True)
    finalized_at = models.DateTimeField()

    class Meta:
        ordering = ['run_id', 'session_participant_id']
        constraints = [
            models.UniqueConstraint(fields=['run', 'session_participant'], name='uniq_final_run_participant'),
            models.CheckConstraint(
                condition=(
                    models.Q(
                        outcome='answered',
                        selected_attempt__isnull=False,
                        timing_attempt__isnull=False,
                        actual_elapsed_ms__isnull=False,
                        ranking_elapsed_ms__isnull=False,
                    )
                    | models.Q(
                        outcome='unanswered',
                        selected_attempt__isnull=True,
                        timing_attempt__isnull=True,
                        actual_elapsed_ms__isnull=True,
                        ranking_elapsed_ms__isnull=True,
                        is_correct=False,
                    )
                ),
                name='final_outcome_fields_match',
            ),
        ]

    def __str__(self):
        return f'Итог участия {self.session_participant_id} запуска {self.run_id}'

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        if self.pk:
            raise HistoryConflict('Изменение итогового ответа запрещено.')
        participant = SessionParticipant.objects.using(using).get(pk=self.session_participant_id)
        if participant.session_id != self.run.session_id:
            raise HistoryConflict('Итог не соответствует участию в сессии запуска.')
        attempts = [attempt for attempt in (self.selected_attempt, self.timing_attempt) if attempt is not None]
        if any(
            attempt.run_id != self.run_id or attempt.session_participant_id != self.session_participant_id
            for attempt in attempts
        ):
            raise HistoryConflict('Итог ссылается на попытку другого запуска или участия.')
        return super().save(*args, **{**kwargs, 'force_insert': True})


class SessionCommand(GuardedModel):
    session = models.ForeignKey(LiveSession, related_name='commands', on_delete=models.PROTECT)
    command_id = models.UUIDField()
    kind = models.CharField(max_length=32)
    expected_revision = models.PositiveBigIntegerField()
    payload_digest = models.CharField(max_length=64, editable=False)
    applied_revision = models.PositiveBigIntegerField()
    response = models.JSONField(default=dict)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['session_id', 'created_at', 'id']
        constraints = [
            models.UniqueConstraint(fields=['session', 'command_id'], name='uniq_session_command_id'),
            models.CheckConstraint(
                condition=models.Q(applied_revision=models.F('expected_revision') + 1),
                name='command_revision_incremented',
            ),
        ]

    def __str__(self):
        return f'Команда {self.kind} сессии {self.session_id}'

    def save(self, *args, **kwargs):
        if self.pk:
            raise HistoryConflict('Изменение применённой команды запрещено.')
        if len(self.payload_digest) != 64:
            raise HistoryConflict('Команда содержит недопустимый отпечаток запроса.')
        return super().save(*args, **{**kwargs, 'force_insert': True})


class SessionDisplayAccess(GuardedModel):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    session = models.ForeignKey(LiveSession, related_name='display_accesses', on_delete=models.PROTECT)
    token_digest = models.CharField(max_length=64, unique=True, editable=False, verbose_name='Отпечаток токена')
    issued_at = models.DateTimeField(auto_now_add=True, verbose_name='Время выдачи')
    revoked_at = models.DateTimeField(null=True, blank=True, verbose_name='Время отзыва')

    class Meta:
        verbose_name = 'доступ показа'
        verbose_name_plural = 'доступы показа'

    @property
    def is_valid(self):
        end = self.session.finished_at
        if self.session.status in {LiveSession.STATUS_FINISHED, LiveSession.STATUS_ABORTED} and end is None:
            return False
        return self.revoked_at is None and (end is None or timezone.now() < end + timedelta(hours=1))

    def save(self, *args, **kwargs):
        using = kwargs.get('using') or self._state.db or 'default'
        with transaction.atomic(using=using):
            old = None
            if self.pk is not None:
                old = type(self).objects.using(using).select_for_update().filter(pk=self.pk).first()
            if old is not None:
                if (old.session_id, old.token_digest, old.issued_at) != (self.session_id, self.token_digest, self.issued_at) or (old.revoked_at and old.revoked_at != self.revoked_at):
                    raise HistoryConflict('Изменение или восстановление выданного доступа запрещено.')
                save_kwargs = {**kwargs}
                save_kwargs.pop('force_insert', None)
                save_kwargs['force_update'] = True
                return super().save(*args, **save_kwargs)
            try:
                with transaction.atomic(using=using):
                    return super().save(*args, **{**kwargs, 'force_insert': True})
            except IntegrityError as exc:
                if self.pk is not None and type(self).objects.using(using).filter(pk=self.pk).exists():
                    raise HistoryConflict('Доступ показа с таким идентификатором уже существует.') from exc
                raise
