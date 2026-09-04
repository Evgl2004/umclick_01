# Схема проведения этапа Б: неизменяемые попытки, итоги, команды и сроки.

import django.db.models.deletion
from django.db import migrations, models


def classify_existing_sessions(apps, schema_editor):
    LiveSession = apps.get_model('session', 'LiveSession')
    LegacyAnswer = apps.get_model('session', 'LegacyParticipantAnswer')

    broken_answers = []
    for answer in LegacyAnswer.objects.select_related(
        'session_participant__session',
        'question',
        'choice',
    ).iterator():
        session = answer.session_participant.session
        if answer.question.quiz_id != session.quiz_id:
            broken_answers.append(answer.pk)
        elif answer.choice_id and answer.choice.question_id != answer.question_id:
            broken_answers.append(answer.pk)
    if broken_answers:
        raise RuntimeError(
            'Обнаружены противоречивые связи старых ответов; миграция остановлена. '
            f'Идентификаторы: {broken_answers[:20]}.'
        )

    blocked_sessions = []
    terminal_statuses = {'finished', 'aborted'}
    for session in LiveSession.objects.order_by('pk').iterator():
        has_answers = LegacyAnswer.objects.filter(
            session_participant__session_id=session.pk,
        ).exists()
        if session.status in terminal_statuses and session.phase == 'final':
            target_schema = 'legacy'
        elif (
            session.status in {'waiting', 'live'}
            and session.phase == 'lobby'
            and session.current_question_id is None
            and not has_answers
        ):
            target_schema = 'v2'
        else:
            blocked_sessions.append(session.pk)
            continue
        LiveSession.objects.filter(pk=session.pk).update(gameplay_schema=target_schema)

    if blocked_sessions:
        raise RuntimeError(
            'Найдены активные или противоречивые сессии временной схемы этапа А. '
            'Завершите их либо примите отдельное решение о переносе; миграция не изменяла их игровые данные. '
            f'Идентификаторы: {blocked_sessions[:20]}.'
        )


def prevent_unsafe_reverse(apps, schema_editor):
    LiveSession = apps.get_model('session', 'LiveSession')
    protected_models = ('SessionQuestionRun', 'AnswerAttempt', 'FinalAnswer', 'SessionCommand')
    has_stage_b_rows = any(apps.get_model('session', name).objects.exists() for name in protected_models)
    if has_stage_b_rows or LiveSession.objects.filter(gameplay_schema='v2').exists():
        raise RuntimeError(
            'Обратная миграция запрещена: обнаружены сессии или игровые данные схемы этапа Б.'
        )


class Migration(migrations.Migration):

    dependencies = [
        ('session', '0004_alter_livesession_options_and_more'),
    ]

    operations = [
        migrations.RenameModel(
            old_name='ParticipantAnswer',
            new_name='LegacyParticipantAnswer',
        ),
        migrations.AddField(
            model_name='livesession',
            name='gameplay_schema',
            field=models.CharField(
                choices=[('legacy', 'Временная схема этапа А'), ('v2', 'Схема проведения этапа Б')],
                default='v2',
                editable=False,
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name='livesession',
            name='state_revision',
            field=models.PositiveBigIntegerField(default=0, editable=False),
        ),
        migrations.AlterField(
            model_name='livesession',
            name='phase',
            field=models.CharField(
                choices=[
                    ('lobby', 'Lobby'),
                    ('reading', 'Reading'),
                    ('answering', 'Answering'),
                    ('delivery', 'Доставка'),
                    ('results', 'Results'),
                    ('final', 'Final'),
                ],
                default='lobby',
                max_length=16,
            ),
        ),
        migrations.CreateModel(
            name='SessionQuestionRun',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('ordinal', models.PositiveIntegerField()),
                ('reading_started_at', models.DateTimeField()),
                ('reading_ends_at', models.DateTimeField()),
                ('answering_started_at', models.DateTimeField()),
                ('planned_answer_deadline_at', models.DateTimeField()),
                ('planned_delivery_deadline_at', models.DateTimeField()),
                ('answer_deadline_at', models.DateTimeField()),
                ('delivery_deadline_at', models.DateTimeField()),
                ('finalized_at', models.DateTimeField(blank=True, null=True)),
                ('results_started_at', models.DateTimeField(blank=True, null=True)),
                ('results_ends_at', models.DateTimeField(blank=True, null=True)),
                ('question', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='session_runs', to='quiz.question')),
                ('session', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='question_runs', to='session.livesession')),
            ],
            options={
                'ordering': ['session_id', 'ordinal', 'id'],
                'constraints': [
                    models.UniqueConstraint(fields=('session', 'question'), name='uniq_run_session_question'),
                    models.UniqueConstraint(fields=('session', 'ordinal'), name='uniq_run_session_ordinal'),
                    models.CheckConstraint(condition=models.Q(('reading_started_at__lte', models.F('reading_ends_at'))), name='run_reading_dates_ordered'),
                    models.CheckConstraint(condition=models.Q(('reading_ends_at__lte', models.F('answering_started_at'))), name='run_answering_after_reading'),
                    models.CheckConstraint(condition=models.Q(('answering_started_at__lte', models.F('answer_deadline_at'))), name='run_answer_deadline_ordered'),
                    models.CheckConstraint(condition=models.Q(('answer_deadline_at__lte', models.F('delivery_deadline_at'))), name='run_delivery_deadline_ordered'),
                    models.CheckConstraint(condition=models.Q(('answer_deadline_at__lte', models.F('planned_answer_deadline_at'))), name='run_answer_not_extended'),
                    models.CheckConstraint(condition=models.Q(('delivery_deadline_at__lte', models.F('planned_delivery_deadline_at'))), name='run_delivery_not_extended'),
                    models.CheckConstraint(
                        condition=(
                            models.Q(('finalized_at__isnull', True), ('results_ends_at__isnull', True), ('results_started_at__isnull', True))
                            | models.Q(('finalized_at__isnull', False), ('results_ends_at__isnull', False), ('results_started_at__isnull', False))
                        ),
                        name='run_results_dates_complete',
                    ),
                ],
            },
        ),
        migrations.AddField(
            model_name='livesession',
            name='current_run',
            field=models.ForeignKey(
                blank=True,
                editable=False,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name='current_for_sessions',
                to='session.sessionquestionrun',
            ),
        ),
        migrations.CreateModel(
            name='AnswerAttempt',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('submission_id', models.UUIDField()),
                ('payload_digest', models.CharField(editable=False, max_length=64)),
                ('admitted_at', models.DateTimeField()),
                ('ordinal', models.PositiveSmallIntegerField()),
                ('choice', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='answer_attempts', to='quiz.choice')),
                ('run', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='attempts', to='session.sessionquestionrun')),
                ('session_participant', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='answer_attempts', to='session.sessionparticipant')),
            ],
            options={
                'ordering': ['admitted_at', 'id'],
                'indexes': [models.Index(fields=['run', 'session_participant', 'admitted_at'], name='attempt_run_part_time_idx')],
                'constraints': [
                    models.UniqueConstraint(fields=('run', 'session_participant', 'submission_id'), name='uniq_attempt_submission'),
                    models.UniqueConstraint(fields=('run', 'session_participant', 'ordinal'), name='uniq_attempt_ordinal'),
                    models.CheckConstraint(condition=models.Q(('ordinal__gte', 1), ('ordinal__lte', 20)), name='attempt_ordinal_1_20'),
                ],
            },
        ),
        migrations.CreateModel(
            name='FinalAnswer',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('outcome', models.CharField(choices=[('answered', 'Ответ дан'), ('unanswered', 'Ответ не дан')], max_length=16)),
                ('is_correct', models.BooleanField(default=False)),
                ('actual_elapsed_ms', models.PositiveIntegerField(blank=True, null=True)),
                ('ranking_elapsed_ms', models.PositiveIntegerField(blank=True, null=True)),
                ('finalized_at', models.DateTimeField()),
                ('run', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='final_answers', to='session.sessionquestionrun')),
                ('selected_attempt', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.PROTECT, related_name='selected_by_finals', to='session.answerattempt')),
                ('session_participant', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='final_answers', to='session.sessionparticipant')),
                ('timing_attempt', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.PROTECT, related_name='timed_by_finals', to='session.answerattempt')),
            ],
            options={
                'ordering': ['run_id', 'session_participant_id'],
                'constraints': [
                    models.UniqueConstraint(fields=('run', 'session_participant'), name='uniq_final_run_participant'),
                    models.CheckConstraint(
                        condition=(
                            models.Q(
                                ('actual_elapsed_ms__isnull', False),
                                ('outcome', 'answered'),
                                ('ranking_elapsed_ms__isnull', False),
                                ('selected_attempt__isnull', False),
                                ('timing_attempt__isnull', False),
                            )
                            | models.Q(
                                ('actual_elapsed_ms__isnull', True),
                                ('is_correct', False),
                                ('outcome', 'unanswered'),
                                ('ranking_elapsed_ms__isnull', True),
                                ('selected_attempt__isnull', True),
                                ('timing_attempt__isnull', True),
                            )
                        ),
                        name='final_outcome_fields_match',
                    ),
                ],
            },
        ),
        migrations.CreateModel(
            name='SessionCommand',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('command_id', models.UUIDField()),
                ('kind', models.CharField(max_length=32)),
                ('expected_revision', models.PositiveBigIntegerField()),
                ('payload_digest', models.CharField(editable=False, max_length=64)),
                ('applied_revision', models.PositiveBigIntegerField()),
                ('response', models.JSONField(default=dict)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('session', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='commands', to='session.livesession')),
            ],
            options={
                'ordering': ['session_id', 'created_at', 'id'],
                'constraints': [
                    models.UniqueConstraint(fields=('session', 'command_id'), name='uniq_session_command_id'),
                    models.CheckConstraint(condition=models.Q(('applied_revision', models.F('expected_revision') + 1)), name='command_revision_incremented'),
                ],
            },
        ),
        migrations.RunPython(classify_existing_sessions, migrations.RunPython.noop),
        migrations.RunPython(migrations.RunPython.noop, prevent_unsafe_reverse),
    ]
