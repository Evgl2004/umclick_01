from django.core.exceptions import ValidationError


def validate_quiz_data(data):
    errors = {}
    if not str(data.get('title', '')).strip():
        errors['title'] = 'Название не должно быть пустым.'
    for field, default, low, high in [('reading_time_sec', 15, 3, 120), ('results_time_sec', 10, 3, 60)]:
        value = data.get(field, default)
        if not isinstance(value, int) or not low <= value <= high:
            errors[field] = f'Допустимое время: от {low} до {high} секунд.'
    questions = data.get('questions', [])
    if not questions:
        errors['questions'] = 'Добавьте хотя бы один вопрос.'
    for i, question in enumerate(questions):
        prefix = f'questions.{i}'
        if not question.get('text', '').strip():
            errors[f'{prefix}.text'] = 'Текст вопроса не должен быть пустым.'
        if not 5 <= question.get('time_limit_sec', 20) <= 180:
            errors[f'{prefix}.time_limit_sec'] = 'Допустимое время: от 5 до 180 секунд.'
        choices = question.get('choices', [])
        if len(choices) < 2:
            errors[f'{prefix}.choices'] = 'Нужны как минимум два варианта.'
        if sum(bool(choice.get('is_correct', False)) for choice in choices) != 1:
            errors[f'{prefix}.choices'] = 'Нужен ровно один правильный вариант.'
        for j, choice in enumerate(choices):
            if not choice.get('text', '').strip():
                errors[f'{prefix}.choices.{j}.text'] = 'Текст варианта не должен быть пустым.'
    if errors:
        raise ValidationError(errors)


def quiz_data(quiz):
    return dict(title=quiz.title, reading_time_sec=quiz.reading_time_sec, results_time_sec=quiz.results_time_sec,
                questions=[dict(id=q.pk, text=q.text, time_limit_sec=q.time_limit_sec,
                                choices=list(q.choices.values('id', 'text', 'is_correct')))
                           for q in quiz.questions.all()])


def validate_quiz_instance(quiz):
    validate_quiz_data(quiz_data(quiz))
