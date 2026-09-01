# Сформировано Django 5.2.14; русские подписи моделей и полей.

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('quiz', '0003_owner_and_history'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AlterModelOptions(
            name='choice',
            options={'ordering': ['order', 'id'], 'verbose_name': 'вариант ответа', 'verbose_name_plural': 'варианты ответов'},
        ),
        migrations.AlterModelOptions(
            name='question',
            options={'ordering': ['order', 'id'], 'verbose_name': 'вопрос', 'verbose_name_plural': 'вопросы'},
        ),
        migrations.AlterModelOptions(
            name='quiz',
            options={'ordering': ['-created_at'], 'verbose_name': 'викторина', 'verbose_name_plural': 'викторины'},
        ),
        migrations.AlterField(
            model_name='quiz',
            name='owner',
            field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='quizzes', to=settings.AUTH_USER_MODEL, verbose_name='Владелец'),
        ),
    ]
