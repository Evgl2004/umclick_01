from django.conf import settings
from django.db import migrations, models


def require_prepared_game_data(apps, schema_editor):
    """Остановка без удаления данных и без выдуманного владельца старых записей."""
    using = schema_editor.connection.alias
    for app, model in [('quiz', 'Quiz'), ('session', 'LiveSession'), ('session', 'Participant'),
                       ('session', 'SessionParticipant'), ('session', 'ParticipantAnswer')]:
        if apps.get_model(app, model).objects.using(using).exists():
            raise RuntimeError('Найдены неподготовленные игровые данные. Миграция ничего не удаляет. Требуется отдельно согласованный переход на подготовленной базе с сохранением учётных записей.')


class Migration(migrations.Migration):
    dependencies = [('quiz', '0002_quiz_presentation_settings'), ('session', '0002_live_session_presentation_flow'), migrations.swappable_dependency(settings.AUTH_USER_MODEL)]
    operations = [migrations.RunPython(require_prepared_game_data, migrations.RunPython.noop),
                  migrations.AddField(model_name='quiz', name='owner', field=models.ForeignKey(on_delete=models.PROTECT, related_name='quizzes', to=settings.AUTH_USER_MODEL))]
