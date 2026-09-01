from django.contrib import admin

from apps.quiz.models import Choice, Question, Quiz
from django import forms
from django.core.exceptions import ValidationError
from django.db import transaction
from apps.core.protection import ensure_unused
from apps.quiz.validation import quiz_data, validate_quiz_data


class ProtectedContentAdmin(admin.ModelAdmin):
    def _quiz_id(self, obj):
        if isinstance(obj, Quiz):
            return obj.pk
        return obj.quiz_id if isinstance(obj, Question) else obj.question.quiz_id

    def has_change_permission(self, request, obj=None):
        allowed = super().has_change_permission(request, obj)
        return allowed and (obj is None or not Quiz.objects.get(pk=self._quiz_id(obj)).sessions.exists())

    def has_delete_permission(self, request, obj=None):
        return super().has_delete_permission(request, obj) and self.has_change_permission(request, obj)

    def changeform_view(self, request, object_id=None, form_url='', extra_context=None):
        with transaction.atomic():
            if request.method == 'POST' and object_id:
                obj = self.get_object(request, object_id)
                if obj:
                    quiz_id = self._quiz_id(obj)
                    Quiz.objects.select_for_update().get(pk=quiz_id)
                    ensure_unused(quiz_id)
            return super().changeform_view(request, object_id, form_url, extra_context)


class QuizForm(forms.ModelForm):
    class Meta:
        model = Quiz
        fields = '__all__'

    def clean(self):
        data = super().clean()
        if self.instance.pk:
            merged = {**quiz_data(self.instance), **data}
            try:
                validate_quiz_data(merged)
            except ValidationError as exc:
                self.add_error(None, ' '.join(exc.messages))
        for field, low, high in [('reading_time_sec', 3, 120), ('results_time_sec', 3, 60)]:
            if field in data and not low <= data[field] <= high:
                self.add_error(field, f'Допустимое время: от {low} до {high} секунд.')
        return data


class QuestionForm(forms.ModelForm):
    class Meta:
        model = Question
        fields = '__all__'

    def clean_time_limit_sec(self):
        value = self.cleaned_data['time_limit_sec']
        if not 5 <= value <= 180:
            raise ValidationError('Допустимое время: от 5 до 180 секунд.')
        return value


class ChoiceFormSet(forms.BaseInlineFormSet):
    def clean(self):
        super().clean()
        if any(self.errors):
            return
        choices = [form.cleaned_data for form in self.forms if form.cleaned_data and not form.cleaned_data.get('DELETE')]
        if len(choices) < 2 or sum(bool(choice.get('is_correct')) for choice in choices) != 1:
            raise ValidationError('Нужны как минимум два варианта и ровно один правильный.')


class ChoiceInline(admin.TabularInline):
    model = Choice
    formset = ChoiceFormSet
    extra = 0


class QuestionInline(admin.StackedInline):
    model = Question
    extra = 0


@admin.register(Quiz)
class QuizAdmin(ProtectedContentAdmin):
    form = QuizForm
    readonly_fields = ('owner',)

    def has_add_permission(self, request):
        # Полную вложенную викторину создаёт проверяемый программный интерфейс.
        return False

    def save_model(self, request, obj, form, change):
        if not change:
            obj.owner = request.user
        super().save_model(request, obj, form, change)
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
class QuestionAdmin(ProtectedContentAdmin):
    form = QuestionForm
    list_display = ("id", "quiz", "order", "time_limit_sec")
    list_filter = ("quiz",)
    inlines = [ChoiceInline]


@admin.register(Choice)
class ChoiceAdmin(ProtectedContentAdmin):
    list_display = ("id", "question", "order", "is_correct")
    list_filter = ("is_correct",)

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        # Варианты меняются совместно в форме вопроса с проверкой всей группы.
        return False

    def has_delete_permission(self, request, obj=None):
        return False
