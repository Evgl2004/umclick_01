from django.contrib import admin
from django.db import transaction

from apps.core.errors import Conflict
from apps.quiz.models import Choice, Question, Quiz, QuizVersion
from apps.quiz.services import (
    archive_quiz,
    delete_quiz,
    get_effective_version,
    restore_quiz,
)


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
    actions = ('archive_selected', 'restore_selected', 'delete_unused_selected')

    @admin.display(description='Название')
    def title(self, obj):
        version = get_effective_version(obj)
        return version.title if version is not None else '—'

    def _run_quiz_action(self, request, queryset, operation, success_message):
        try:
            with transaction.atomic():
                quiz_ids = list(queryset.order_by('pk').values_list('pk', flat=True))
                for quiz_id in quiz_ids:
                    operation(quiz_id=quiz_id, actor=request.user)
        except Conflict as exc:
            self.message_user(request, str(exc.detail), level='ERROR')
            return
        self.message_user(request, success_message.format(count=len(quiz_ids)))

    @admin.action(description='Архивировать выбранные викторины')
    def archive_selected(self, request, queryset):
        self._run_quiz_action(
            request,
            queryset,
            archive_quiz,
            'Архивировано викторин: {count}.',
        )

    @admin.action(description='Восстановить выбранные викторины')
    def restore_selected(self, request, queryset):
        self._run_quiz_action(
            request,
            queryset,
            restore_quiz,
            'Восстановлено викторин: {count}.',
        )

    @admin.action(description='Удалить выбранные неиспользованные викторины')
    def delete_unused_selected(self, request, queryset):
        self._run_quiz_action(
            request,
            queryset,
            delete_quiz,
            'Удалено неиспользованных викторин: {count}.',
        )


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
