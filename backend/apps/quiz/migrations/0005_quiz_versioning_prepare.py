# Подготовительная схема версий без изменения действующего прикладного договора.

import django.db.models.deletion
from django.db import migrations, models


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
            'Найдены игровые данные перед подготовкой версий викторин. '
            'Выполните отдельно разрешённую контролируемую очистку и повторите миграцию. '
            f'Непустые таблицы: {", ".join(non_empty)}.'
        )


class Migration(migrations.Migration):

    dependencies = [
        ('quiz', '0004_alter_choice_options_alter_question_options_and_more'),
        ('session', '0006_stage_b_deadline_constraints'),
    ]

    operations = [
        migrations.RunPython(
            require_empty_versioning_game_data,
            migrations.RunPython.noop,
        ),
        migrations.AddField(
            model_name='quiz',
            name='archived_at',
            field=models.DateTimeField(blank=True, editable=False, null=True),
        ),
        migrations.AddField(
            model_name='quiz',
            name='content_revision',
            field=models.PositiveBigIntegerField(default=1, editable=False),
        ),
        migrations.CreateModel(
            name='QuizVersion',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('number', models.PositiveIntegerField()),
                ('status', models.CharField(choices=[('draft', 'Черновик'), ('fixed', 'Зафиксированная версия')], default='draft', max_length=16)),
                ('fixed_at', models.DateTimeField(blank=True, null=True)),
                ('title', models.CharField(max_length=255)),
                ('description', models.TextField(blank=True)),
                ('question_only_on_display', models.BooleanField(default=False)),
                ('show_choices_on_participant', models.BooleanField(default=True)),
                ('reading_time_sec', models.PositiveIntegerField(default=15)),
                ('results_time_sec', models.PositiveIntegerField(default=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('quiz', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='versions', to='quiz.quiz')),
            ],
            options={
                'verbose_name': 'версия викторины',
                'verbose_name_plural': 'версии викторин',
                'ordering': ['number', 'id'],
                'constraints': [
                    models.UniqueConstraint(fields=('quiz', 'number'), name='uniq_quiz_version_number'),
                    models.UniqueConstraint(condition=models.Q(('status', 'draft')), fields=('quiz',), name='uniq_quiz_draft_version'),
                    models.CheckConstraint(condition=models.Q(models.Q(('fixed_at__isnull', True), ('status', 'draft')), models.Q(('fixed_at__isnull', False), ('status', 'fixed')), _connector='OR'), name='quiz_version_status_fixed_at'),
                ],
            },
        ),
        migrations.AddField(
            model_name='question',
            name='quiz_version',
            field=models.ForeignKey(blank=True, editable=False, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='questions', to='quiz.quizversion'),
        ),
    ]
