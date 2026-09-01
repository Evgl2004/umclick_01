"""Изолированная локальная конфигурация проверок А; настройки стенда не используются."""
from .settings import *

DEBUG = True
SECRET_KEY = 'stage-a-local-synthetic-test-key-not-for-production-2026'
DATABASES = {'default': {'ENGINE': 'django.db.backends.postgresql', 'NAME': 'postgres',
                         'USER': 'codex_stage_a', 'PASSWORD': '', 'HOST': '127.0.0.1', 'PORT': '55439',
                         'TEST': {'NAME': 'test_codex_stage_a'}}}
CHANNEL_LAYERS = {'default': {'BACKEND': 'channels.layers.InMemoryChannelLayer'}}
CELERY_TASK_ALWAYS_EAGER = True
ALLOWED_HOSTS = ['127.0.0.1', 'localhost', 'testserver']
PASSWORD_HASHERS = ['django.contrib.auth.hashers.MD5PasswordHasher']
