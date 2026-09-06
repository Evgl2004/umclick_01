# Сессия после переключения всегда ссылается на неизменяемую версию викторины.

from django.db import migrations, models
import django.db.models.deletion


GAME_MODELS = (
    ('session', 'FinalAnswer'),
    ('session', 'AnswerAttempt'),
    ('session', 'LegacyParticipantAnswer'),
    ('session', 'SessionCommand'),
    ('session', 'SessionDisplayAccess'),
    ('session', 'SessionQuestionRun'),
    ('session', 'SessionParticipant'),
    ('session', 'LiveSession'),
    ('session', 'Participant'),
    ('quiz', 'Choice'),
    ('quiz', 'Question'),
    ('quiz', 'QuizVersion'),
    ('quiz', 'Quiz'),
)


def prevent_destructive_reverse(apps, schema_editor):
    using = schema_editor.connection.alias
    non_empty = []
    for app_label, model_name in GAME_MODELS:
        model = apps.get_model(app_label, model_name)
        if model.objects.using(using).exists():
            non_empty.append(model._meta.db_table)
    if non_empty:
        raise RuntimeError(
            'Обратное переключение схемы версий запрещено при наличии игровых данных. '
            f'Непустые таблицы: {", ".join(non_empty)}.'
        )


class Migration(migrations.Migration):

    dependencies = [
        ('quiz', '0006_quiz_versioning_switch'),
        ('session', '0007_quiz_versioning_prepare'),
    ]

    operations = [
        migrations.AlterField(
            model_name='livesession',
            name='quiz_version',
            field=models.ForeignKey(
                editable=False,
                on_delete=django.db.models.deletion.PROTECT,
                related_name='sessions',
                to='quiz.quizversion',
            ),
        ),
        migrations.RemoveField(model_name='livesession', name='quiz'),
        migrations.RunPython(
            migrations.RunPython.noop,
            prevent_destructive_reverse,
        ),
    ]
