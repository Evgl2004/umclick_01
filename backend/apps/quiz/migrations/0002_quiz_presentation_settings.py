from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("quiz", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="quiz",
            name="question_only_on_display",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="quiz",
            name="show_choices_on_participant",
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name="quiz",
            name="reading_time_sec",
            field=models.PositiveIntegerField(default=15),
        ),
        migrations.AddField(
            model_name="quiz",
            name="results_time_sec",
            field=models.PositiveIntegerField(default=10),
        ),
    ]
