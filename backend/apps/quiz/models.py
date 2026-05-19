from django.db import models


class Quiz(models.Model):
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

    def __str__(self) -> str:
        return self.title


class Question(models.Model):
    quiz = models.ForeignKey(Quiz, related_name="questions", on_delete=models.CASCADE)
    text = models.TextField()
    order = models.PositiveIntegerField(default=1)
    time_limit_sec = models.PositiveIntegerField(default=20)

    class Meta:
        ordering = ["order", "id"]

    def __str__(self) -> str:
        return f"{self.quiz.title}: {self.text[:40]}"


class Choice(models.Model):
    question = models.ForeignKey(Question, related_name="choices", on_delete=models.CASCADE)
    text = models.CharField(max_length=255)
    is_correct = models.BooleanField(default=False)
    order = models.PositiveIntegerField(default=1)

    class Meta:
        ordering = ["order", "id"]

    def __str__(self) -> str:
        return f"{self.question_id}:{self.text[:40]}"
