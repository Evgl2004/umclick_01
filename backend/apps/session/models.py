import random
import uuid

from django.db import models
from django.utils import timezone

from apps.quiz.models import Choice, Question, Quiz


def generate_pin() -> str:
    return "".join(random.choices("0123456789", k=6))


class LiveSession(models.Model):
    STATUS_WAITING = "waiting"
    STATUS_LIVE = "live"
    STATUS_FINISHED = "finished"

    STATUS_CHOICES = [
        (STATUS_WAITING, "Waiting"),
        (STATUS_LIVE, "Live"),
        (STATUS_FINISHED, "Finished"),
    ]

    quiz = models.ForeignKey(Quiz, related_name="sessions", on_delete=models.CASCADE)
    host_name = models.CharField(max_length=255, blank=True)
    pin = models.CharField(max_length=6, unique=True, db_index=True)
    join_token = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    status = models.CharField(max_length=16, choices=STATUS_CHOICES, default=STATUS_WAITING)
    current_question = models.ForeignKey(
        Question,
        related_name="active_sessions",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
    )
    revealed_question_id = models.PositiveIntegerField(null=True, blank=True)
    question_started_at = models.DateTimeField(null=True, blank=True)
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def save(self, *args, **kwargs):
        if not self.pin:
            pin = generate_pin()
            while LiveSession.objects.filter(pin=pin).exists():
                pin = generate_pin()
            self.pin = pin
        if self.status == self.STATUS_LIVE and self.started_at is None:
            self.started_at = timezone.now()
        if self.status == self.STATUS_FINISHED and self.finished_at is None:
            self.finished_at = timezone.now()
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"Session {self.pin} ({self.quiz.title})"


class Participant(models.Model):
    phone = models.CharField(max_length=32, unique=True)
    name = models.CharField(max_length=255)
    consent = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.name} ({self.phone})"


class SessionParticipant(models.Model):
    session = models.ForeignKey(LiveSession, related_name="participants", on_delete=models.CASCADE)
    participant = models.ForeignKey(Participant, related_name="session_links", on_delete=models.CASCADE)
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["session", "participant"], name="uniq_session_participant"),
        ]

    def __str__(self) -> str:
        return f"{self.participant.name} -> {self.session.pin}"


class ParticipantAnswer(models.Model):
    session_participant = models.ForeignKey(
        SessionParticipant,
        related_name="answers",
        on_delete=models.CASCADE,
    )
    question = models.ForeignKey(Question, related_name="session_answers", on_delete=models.CASCADE)
    choice = models.ForeignKey(Choice, related_name="answers", on_delete=models.SET_NULL, null=True, blank=True)
    is_correct = models.BooleanField(default=False)
    score_points = models.PositiveIntegerField(default=0)
    answered_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["session_participant", "question"],
                name="uniq_answer_per_question",
            ),
        ]

    def __str__(self) -> str:
        return f"Answer sp={self.session_participant_id} q={self.question_id}"
