import os
from datetime import timedelta
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.getenv("DJANGO_SECRET_KEY", "unsafe-dev-key")
DEBUG = os.getenv("DJANGO_DEBUG", "true").lower() == "true"

allowed_hosts_raw = os.getenv("DJANGO_ALLOWED_HOSTS", "*")
ALLOWED_HOSTS = [host.strip() for host in allowed_hosts_raw.split(",") if host.strip()]

trusted_proxy_cidrs_raw = os.getenv("TRUSTED_PROXY_CIDRS", "")
TRUSTED_PROXY_CIDRS = [
    value.strip()
    for value in trusted_proxy_cidrs_raw.split(",")
    if value.strip()
]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "corsheaders",
    "rest_framework",
    "rest_framework_simplejwt",
    "channels",
    "apps.core",
    "apps.quiz",
    "apps.session",
]

MIDDLEWARE = [
    "apps.core.middleware.HistoryProtectionMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "umclick.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "umclick.wsgi.application"
ASGI_APPLICATION = "umclick.asgi.application"

DB_NAME = os.getenv("POSTGRES_DB")
DB_USER = os.getenv("POSTGRES_USER")
DB_PASSWORD = os.getenv("POSTGRES_PASSWORD")
DB_HOST = os.getenv("POSTGRES_HOST")
DB_PORT = os.getenv("POSTGRES_PORT", "5432")

if all([DB_NAME, DB_USER, DB_PASSWORD, DB_HOST]):
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": DB_NAME,
            "USER": DB_USER,
            "PASSWORD": DB_PASSWORD,
            "HOST": DB_HOST,
            "PORT": DB_PORT,
        }
    }
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": BASE_DIR / "db.sqlite3",
        }
    }

AUTH_PASSWORD_VALIDATORS = [
    {
        "NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.CommonPasswordValidator",
    },
    {
        "NAME": "django.contrib.auth.password_validation.NumericPasswordValidator",
    },
]

LANGUAGE_CODE = "ru"
TIME_ZONE = os.getenv("DJANGO_TIME_ZONE", "UTC")
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

cors_allow_all_raw = os.getenv("CORS_ALLOW_ALL_ORIGINS")
if cors_allow_all_raw is None:
    CORS_ALLOW_ALL_ORIGINS = DEBUG
else:
    CORS_ALLOW_ALL_ORIGINS = cors_allow_all_raw.lower() == "true"

cors_allowed_origins_raw = os.getenv("CORS_ALLOWED_ORIGINS", "")
CORS_ALLOWED_ORIGINS = [
    origin.strip()
    for origin in cors_allowed_origins_raw.split(",")
    if origin.strip()
]

REST_FRAMEWORK = {
    "EXCEPTION_HANDLER": "apps.core.errors.exception_handler",
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "apps.session.access.ScopedTokenAuthentication",
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
}

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=30),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=7),
    "AUTH_HEADER_TYPES": ("Bearer",),
}

REDIS_URL = os.getenv("REDIS_URL", "")
CHANNEL_LAYER_REDIS_URL = os.getenv("CHANNEL_LAYER_REDIS_URL", REDIS_URL)
RATE_LIMIT_REDIS_URL = os.getenv("RATE_LIMIT_REDIS_URL", REDIS_URL)
RATE_LIMIT_NAMESPACE = os.getenv("RATE_LIMIT_NAMESPACE", "umclick:limit:v1")
RATE_LIMIT_HMAC_SECRET = os.getenv("RATE_LIMIT_HMAC_SECRET", SECRET_KEY)
RATE_LIMITS_ENABLED = os.getenv("RATE_LIMITS_ENABLED", "true").lower() == "true"
WS_LIMIT_REDIS_URL = os.getenv("WS_LIMIT_REDIS_URL", RATE_LIMIT_REDIS_URL)
WS_LIMIT_NAMESPACE = os.getenv("WS_LIMIT_NAMESPACE", RATE_LIMIT_NAMESPACE)
WS_LIMIT_HMAC_SECRET = os.getenv("WS_LIMIT_HMAC_SECRET", RATE_LIMIT_HMAC_SECRET)
WS_LIMITS_ENABLED = os.getenv("WS_LIMITS_ENABLED", "true").lower() == "true"
CELERY_BROKER_URL = os.getenv("CELERY_BROKER_URL", REDIS_URL)
CELERY_RESULT_BACKEND = os.getenv("CELERY_RESULT_BACKEND", CELERY_BROKER_URL)

if CHANNEL_LAYER_REDIS_URL:
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels_redis.core.RedisChannelLayer",
            "CONFIG": {
                "hosts": [CHANNEL_LAYER_REDIS_URL],
            },
        }
    }
else:
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels.layers.InMemoryChannelLayer",
        }
    }

CELERY_ACCEPT_CONTENT = ["json"]
CELERY_TASK_SERIALIZER = "json"
CELERY_RESULT_SERIALIZER = "json"
CELERY_TIMEZONE = TIME_ZONE
CELERY_ENABLE_UTC = True

try:
    auto_reveal_interval_sec = max(int(os.getenv("AUTO_REVEAL_BEAT_INTERVAL_SEC", "1")), 1)
except ValueError:
    auto_reveal_interval_sec = 1
CELERY_BEAT_SCHEDULE = {
    "session-auto-reveal-tick": {
        "task": "apps.session.auto_reveal_due_sessions",
        "schedule": timedelta(seconds=auto_reveal_interval_sec),
    },
}
