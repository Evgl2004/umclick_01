"""Единая безопасная конфигурация локальных серверных проверок."""

import os
import re
from urllib.parse import urlsplit

from django.core.exceptions import ImproperlyConfigured

from .settings import *  # noqa: F403


_REQUIRED_ENVIRONMENT_KEYS = (
    "UMCLICK_TEST_DB_HOST",
    "UMCLICK_TEST_DB_PORT",
    "UMCLICK_TEST_DB_USER",
    "UMCLICK_TEST_DB_PASSWORD",
    "UMCLICK_TEST_DB_NAME",
)
_SAFE_IDENTIFIER = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")
_SAFE_TEST_DATABASE = re.compile(r"^test_umclick_[a-z0-9_]+$")
_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def _required_environment_value(name):
    value = os.environ.get(name)
    if value is None or not value.strip():
        raise ImproperlyConfigured(
            f"Не задана обязательная переменная локальных проверок: {name}."
        )
    if name == "UMCLICK_TEST_DB_PASSWORD":
        return value
    return value.strip()


_test_environment = {
    name: _required_environment_value(name) for name in _REQUIRED_ENVIRONMENT_KEYS
}

_database_host = _test_environment["UMCLICK_TEST_DB_HOST"].lower()
if _database_host not in _LOOPBACK_HOSTS:
    raise ImproperlyConfigured(
        "Локальные проверки разрешают PostgreSQL только на loopback-адресе."
    )

try:
    _database_port = int(_test_environment["UMCLICK_TEST_DB_PORT"])
except ValueError as error:
    raise ImproperlyConfigured(
        "Порт PostgreSQL локальных проверок должен быть целым числом."
    ) from error
if not 1 <= _database_port <= 65535:
    raise ImproperlyConfigured(
        "Порт PostgreSQL локальных проверок должен быть от 1 до 65535."
    )

_database_user = _test_environment["UMCLICK_TEST_DB_USER"]
_test_database = _test_environment["UMCLICK_TEST_DB_NAME"]

if not _SAFE_IDENTIFIER.fullmatch(_database_user):
    raise ImproperlyConfigured(
        "Имя пользователя PostgreSQL содержит недопустимые символы."
    )
if not _SAFE_TEST_DATABASE.fullmatch(_test_database):
    raise ImproperlyConfigured(
        "Имя постоянной тестовой базы должно соответствовать шаблону test_umclick_*."
    )

DEBUG = True
SECRET_KEY = "umclick-local-tests-synthetic-secret-not-for-production"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": _test_database,
        "USER": _database_user,
        "PASSWORD": _test_environment["UMCLICK_TEST_DB_PASSWORD"],
        "HOST": _database_host,
        "PORT": str(_database_port),
        "CONN_MAX_AGE": 0,
        "TEST": {"NAME": _test_database},
    }
}

CHANNEL_LAYERS = {
    "default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}
}
CELERY_TASK_ALWAYS_EAGER = True
CELERY_TASK_EAGER_PROPAGATES = True
CELERY_BROKER_URL = "memory://"
CELERY_RESULT_BACKEND = "cache+memory://"
RATE_LIMITS_ENABLED = os.getenv("UMCLICK_TEST_RATE_LIMITS", "false").lower() == "true"
WS_LIMITS_ENABLED = os.getenv("UMCLICK_TEST_WS_LIMITS", "false").lower() == "true"
ALLOWED_HOSTS = ["127.0.0.1", "localhost", "testserver", "[::1]"]
PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]


_stage_v_redis_url = os.getenv("UMCLICK_STAGE_V_REDIS_URL", "").strip()
if _stage_v_redis_url:
    _redis_uri = urlsplit(_stage_v_redis_url)
    if (
        _redis_uri.scheme != "redis"
        or _redis_uri.hostname not in _LOOPBACK_HOSTS
        or _redis_uri.username is not None
        or _redis_uri.password is not None
        or _redis_uri.query
        or _redis_uri.fragment
    ):
        raise ImproperlyConfigured(
            "Двухпроцессная проверка разрешает Redis без учётных данных только на loopback."
        )
    _stage_v_namespace = os.getenv("UMCLICK_STAGE_V_REDIS_NAMESPACE", "").strip()
    if not re.fullmatch(r"umclick:test:[0-9a-f-]{36}", _stage_v_namespace):
        raise ImproperlyConfigured(
            "Двухпроцессной проверке требуется пространство umclick:test:<UUID>."
        )

    RATE_LIMIT_REDIS_URL = _stage_v_redis_url
    RATE_LIMIT_NAMESPACE = _stage_v_namespace
    RATE_LIMIT_HMAC_SECRET = SECRET_KEY  # noqa: F405
    RATE_LIMITS_ENABLED = True
    WS_LIMIT_REDIS_URL = _stage_v_redis_url
    WS_LIMIT_NAMESPACE = _stage_v_namespace
    WS_LIMIT_HMAC_SECRET = SECRET_KEY  # noqa: F405
    WS_LIMITS_ENABLED = True
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels_redis.core.RedisChannelLayer",
            "CONFIG": {
                "hosts": [_stage_v_redis_url],
                "prefix": f"{_stage_v_namespace}:channel",
            },
        }
    }
