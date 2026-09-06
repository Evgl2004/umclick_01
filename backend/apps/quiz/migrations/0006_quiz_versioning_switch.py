# Переключение на обязательные версии выполняется только на пустой игровой схеме.

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


def require_empty_versioning_game_data(apps, schema_editor):
    using = schema_editor.connection.alias
    non_empty = []
    for app_label, model_name in GAME_MODELS:
        model = apps.get_model(app_label, model_name)
        if model.objects.using(using).exists():
            non_empty.append(model._meta.db_table)
    if non_empty:
        raise RuntimeError(
            'Найдены игровые данные перед переключением на версии викторин. '
            'Удалите их только отдельной контролируемой операцией и повторите миграцию. '
            f'Непустые таблицы: {", ".join(non_empty)}.'
        )


class Migration(migrations.Migration):

    dependencies = [
        ('quiz', '0005_quiz_versioning_prepare'),
        ('session', '0007_quiz_versioning_prepare'),
    ]

    operations = [
        migrations.RunPython(
            require_empty_versioning_game_data,
            migrations.RunPython.noop,
        ),
        migrations.AlterField(
            model_name='question',
            name='quiz_version',
            field=models.ForeignKey(
                editable=False,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='questions',
                to='quiz.quizversion',
            ),
        ),
        migrations.RemoveField(model_name='question', name='quiz'),
        migrations.RemoveField(model_name='quiz', name='title'),
        migrations.RemoveField(model_name='quiz', name='description'),
        migrations.RemoveField(model_name='quiz', name='question_only_on_display'),
        migrations.RemoveField(model_name='quiz', name='show_choices_on_participant'),
        migrations.RemoveField(model_name='quiz', name='reading_time_sec'),
        migrations.RemoveField(model_name='quiz', name='results_time_sec'),
        migrations.AddConstraint(
            model_name='question',
            constraint=models.UniqueConstraint(
                fields=('quiz_version', 'order'),
                name='uniq_question_version_order',
                deferrable=models.Deferrable['DEFERRED'],
            ),
        ),
        migrations.AddConstraint(
            model_name='choice',
            constraint=models.UniqueConstraint(
                fields=('question', 'order'),
                name='uniq_choice_question_order',
                deferrable=models.Deferrable['DEFERRED'],
            ),
        ),
    ]
