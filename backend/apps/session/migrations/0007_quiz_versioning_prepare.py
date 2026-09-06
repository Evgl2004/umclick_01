# Необязательная связь с подготовленной версией без переключения сессий.

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('quiz', '0005_quiz_versioning_prepare'),
        ('session', '0006_stage_b_deadline_constraints'),
    ]

    operations = [
        migrations.AddField(
            model_name='livesession',
            name='quiz_version',
            field=models.ForeignKey(blank=True, editable=False, null=True, on_delete=django.db.models.deletion.PROTECT, related_name='sessions', to='quiz.quizversion'),
        ),
    ]
