import uuid
import secrets

from django.conf import settings
from django.db import IntegrityError, models, transaction
from datetime import timedelta
from django.utils import timezone

from apps.quiz.models import Choice, Question, Quiz
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
    PHASE_RESULTS = "results"
    PHASE_FINAL = "final"

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
        (PHASE_RESULTS, "Results"),
        (PHASE_FINAL, "Final"),
    ]

    quiz = models.ForeignKey(Quiz, related_name="sessions", on_delete=models.PROTECT)
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, related_name='created_sessions', on_delete=models.PROTECT, verbose_name='Создатель')
    host_name = models.CharField(max_length=255, blank=True)
    pin = models.CharField(max_length=6, db_index=True)
    join_token = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    status = models.CharField(max_length=16, choices=STATUS_CHOICES, default=STATUS_WAITING)
    phase = models.CharField(max_length=16, choices=PHASE_CHOICES, default=PHASE_LOBBY)
    current_question = models.ForeignKey(
        Question,
        related_name="active_sessions",
        on_delete=models.PROTECT,
        null=True,
        blank=True,
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
            if old is None:
                quiz = Quiz.objects.using(using).select_for_update().get(pk=self.quiz_id)
                from apps.quiz.validation import validate_quiz_instance
                validate_quiz_instance(quiz)
            else:
                fixed = ['quiz_id', 'created_by_id', 'join_token', 'pin', 'created_at']
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


class ParticipantAnswer(GuardedModel):
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
            if self.pk and ParticipantAnswer.objects.filter(pk=self.pk).exclude(session_participant_id=self.session_participant_id, question_id=self.question_id).exists():
                raise HistoryConflict('Перенос исторического ответа запрещён.')
            return super().save(*args, **kwargs)


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
