# Сформировано Django 5.2.14; русские подписи моделей и полей.

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('session', '0003_access_and_history'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AlterModelOptions(
            name='livesession',
            options={'ordering': ['-created_at'], 'verbose_name': 'сессия', 'verbose_name_plural': 'сессии'},
        ),
        migrations.AlterModelOptions(
            name='sessiondisplayaccess',
            options={'verbose_name': 'доступ показа', 'verbose_name_plural': 'доступы показа'},
        ),
        migrations.AlterField(
            model_name='livesession',
            name='created_by',
            field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='created_sessions', to=settings.AUTH_USER_MODEL, verbose_name='Создатель'),
        ),
        migrations.AlterField(
            model_name='participant',
            name='user',
            field=models.OneToOneField(blank=True, null=True, on_delete=django.db.models.deletion.PROTECT, related_name='participant_profile', to=settings.AUTH_USER_MODEL, verbose_name='Учётная запись'),
        ),
        migrations.AlterField(
            model_name='sessiondisplayaccess',
            name='issued_at',
            field=models.DateTimeField(auto_now_add=True, verbose_name='Время выдачи'),
        ),
        migrations.AlterField(
            model_name='sessiondisplayaccess',
            name='revoked_at',
            field=models.DateTimeField(blank=True, null=True, verbose_name='Время отзыва'),
        ),
        migrations.AlterField(
            model_name='sessiondisplayaccess',
            name='token_digest',
            field=models.CharField(editable=False, max_length=64, unique=True, verbose_name='Отпечаток токена'),
        ),
        migrations.AlterField(
            model_name='sessionparticipant',
            name='name_snapshot',
            field=models.CharField(max_length=255, verbose_name='Имя в сессии'),
        ),
        migrations.AlterField(
            model_name='sessionparticipant',
            name='token_digest',
            field=models.CharField(editable=False, max_length=64, unique=True, verbose_name='Отпечаток токена'),
        ),
    ]
