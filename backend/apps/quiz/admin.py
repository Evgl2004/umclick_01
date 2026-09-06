from django.contrib import admin

from apps.quiz.models import Choice, Question, Quiz, QuizVersion
from apps.quiz.services import get_effective_version


class ReadOnlyContentAdmin(admin.ModelAdmin):
    """Разрешает просматривать содержимое, но не обходить прикладные сервисы."""

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def get_readonly_fields(self, request, obj=None):
        return tuple(field.name for field in self.model._meta.fields)


@admin.register(Quiz)
class QuizAdmin(ReadOnlyContentAdmin):
    list_display = ('id', 'title', 'owner', 'content_revision', 'archived_at', 'created_at')
    search_fields = ('versions__title',)
    list_filter = ('archived_at', 'created_at')

    @admin.display(description='Название')
    def title(self, obj):
        version = get_effective_version(obj)
        return version.title if version is not None else '—'


@admin.register(QuizVersion)
class QuizVersionAdmin(ReadOnlyContentAdmin):
    list_display = ('id', 'quiz', 'number', 'status', 'title', 'fixed_at', 'created_at')
    list_filter = ('status', 'created_at')
    search_fields = ('title', 'quiz__id')


@admin.register(Question)
class QuestionAdmin(ReadOnlyContentAdmin):
    list_display = ('id', 'quiz_version', 'order', 'time_limit_sec')
    list_filter = ('quiz_version',)


@admin.register(Choice)
class ChoiceAdmin(ReadOnlyContentAdmin):
    list_display = ('id', 'question', 'order', 'is_correct')
    list_filter = ('is_correct',)
