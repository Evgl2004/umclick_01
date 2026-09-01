from django.urls import re_path

from apps.session.consumers import SessionConsumer

websocket_urlpatterns = [
    re_path(r'^ws/sessions/(?P<session_uuid>[0-9a-fA-F-]{36})/$', SessionConsumer.as_asgi()),
]
