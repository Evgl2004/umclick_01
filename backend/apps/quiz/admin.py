from django.contrib import admin

from apps.quiz.models import Choice, Question, Quiz


class ChoiceInline(admin.TabularInline):
    model = Choice
    extra = 0


class QuestionInline(admin.StackedInline):
    model = Question
    extra = 0


@admin.register(Quiz)
class QuizAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "title",
        "question_only_on_display",
        "show_choices_on_participant",
        "reading_time_sec",
        "results_time_sec",
        "created_at",
    )
    search_fields = ("title",)


@admin.register(Question)
class QuestionAdmin(admin.ModelAdmin):
    list_display = ("id", "quiz", "order", "time_limit_sec")
    list_filter = ("quiz",)
    inlines = [ChoiceInline]


@admin.register(Choice)
class ChoiceAdmin(admin.ModelAdmin):
    list_display = ("id", "question", "order", "is_correct")
    list_filter = ("is_correct",)
