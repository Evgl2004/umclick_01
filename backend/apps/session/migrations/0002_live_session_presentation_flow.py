from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("session", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="livesession",
            name="phase",
            field=models.CharField(
                choices=[
                    ("lobby", "Lobby"),
                    ("reading", "Reading"),
                    ("answering", "Answering"),
                    ("results", "Results"),
                    ("final", "Final"),
                ],
                default="lobby",
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name="livesession",
            name="phase_started_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="participantanswer",
            name="elapsed_ms",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AlterField(
            model_name="livesession",
            name="status",
            field=models.CharField(
                choices=[
                    ("waiting", "Waiting"),
                    ("live", "Live"),
                    ("finished", "Finished"),
                    ("aborted", "Aborted"),
                ],
                default="waiting",
                max_length=16,
            ),
        ),
    ]
