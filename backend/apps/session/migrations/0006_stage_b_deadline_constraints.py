# Дополнительные ограничения неизменяемых сроков этапа Б.

import datetime
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('session', '0005_stage_b_gameplay'),
    ]

    operations = [
        migrations.AddConstraint(
            model_name='sessionquestionrun',
            constraint=models.CheckConstraint(
                condition=models.Q(('answering_started_at__lte', models.F('planned_answer_deadline_at'))),
                name='run_planned_answer_ordered',
            ),
        ),
        migrations.AddConstraint(
            model_name='sessionquestionrun',
            constraint=models.CheckConstraint(
                condition=models.Q(
                    ('planned_delivery_deadline_at', models.F('planned_answer_deadline_at') + datetime.timedelta(seconds=3)),
                ),
                name='run_planned_delivery_3s',
            ),
        ),
        migrations.AddConstraint(
            model_name='sessionquestionrun',
            constraint=models.CheckConstraint(
                condition=models.Q(
                    ('delivery_deadline_at', models.F('answer_deadline_at') + datetime.timedelta(seconds=3)),
                ),
                name='run_delivery_3s',
            ),
        ),
        migrations.AddConstraint(
            model_name='sessionquestionrun',
            constraint=models.CheckConstraint(
                condition=(
                    models.Q(('results_started_at__isnull', True))
                    | models.Q(('results_started_at__lte', models.F('results_ends_at')))
                ),
                name='run_results_dates_ordered',
            ),
        ),
    ]
