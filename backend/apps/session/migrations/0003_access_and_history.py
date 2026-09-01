import uuid
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [('session', '0002_live_session_presentation_flow'), ('quiz', '0003_owner_and_history'), ('core', '0001_roles')]
    operations = [
        migrations.AddField(model_name='livesession', name='created_by', field=models.ForeignKey(on_delete=models.PROTECT, related_name='created_sessions', to=settings.AUTH_USER_MODEL)),
        migrations.AlterField(model_name='livesession', name='quiz', field=models.ForeignKey(on_delete=models.PROTECT, related_name='sessions', to='quiz.quiz')),
        migrations.AlterField(model_name='livesession', name='current_question', field=models.ForeignKey(blank=True, null=True, on_delete=models.PROTECT, related_name='active_sessions', to='quiz.question')),
        migrations.AlterField(model_name='livesession', name='pin', field=models.CharField(db_index=True, max_length=6)),
        migrations.AddConstraint(model_name='livesession', constraint=models.UniqueConstraint(condition=models.Q(status__in=['waiting', 'live']), fields=('pin',), name='uniq_open_session_pin')),
        migrations.AddField(model_name='participant', name='user', field=models.OneToOneField(blank=True, null=True, on_delete=models.PROTECT, related_name='participant_profile', to=settings.AUTH_USER_MODEL)),
        migrations.AlterField(model_name='participant', name='phone', field=models.CharField(blank=True, null=True, max_length=32)),
        migrations.AddField(model_name='sessionparticipant', name='token_digest', field=models.CharField(editable=False, max_length=64, unique=True)),
        migrations.AddField(model_name='sessionparticipant', name='name_snapshot', field=models.CharField(max_length=255)),
        migrations.AlterField(model_name='sessionparticipant', name='session', field=models.ForeignKey(on_delete=models.PROTECT, related_name='participants', to='session.livesession')),
        migrations.AlterField(model_name='sessionparticipant', name='participant', field=models.ForeignKey(on_delete=models.PROTECT, related_name='session_links', to='session.participant')),
        migrations.AlterField(model_name='participantanswer', name='session_participant', field=models.ForeignKey(on_delete=models.PROTECT, related_name='answers', to='session.sessionparticipant')),
        migrations.AlterField(model_name='participantanswer', name='question', field=models.ForeignKey(on_delete=models.PROTECT, related_name='session_answers', to='quiz.question')),
        migrations.AlterField(model_name='participantanswer', name='choice', field=models.ForeignKey(blank=True, null=True, on_delete=models.PROTECT, related_name='answers', to='quiz.choice')),
        migrations.CreateModel(name='SessionDisplayAccess', fields=[
            ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
            ('token_digest', models.CharField(editable=False, max_length=64, unique=True)),
            ('issued_at', models.DateTimeField(auto_now_add=True)),
            ('revoked_at', models.DateTimeField(blank=True, null=True)),
            ('session', models.ForeignKey(on_delete=models.PROTECT, related_name='display_accesses', to='session.livesession')),
        ]),
    ]
