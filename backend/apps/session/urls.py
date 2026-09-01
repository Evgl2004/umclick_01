from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.session.views import (
    CurrentLegalDocumentsAPIView,
    JoinSessionAPIView,
    JoinSessionPreviewAPIView,
    LiveSessionViewSet,
    SubmitAnswerAPIView,
    ParticipationAPIView,
    DisplayStateAPIView,
    OwnResultsAPIView,
)

router = DefaultRouter()
router.register("", LiveSessionViewSet, basename="session")

urlpatterns = [
    path("legal/current/", CurrentLegalDocumentsAPIView.as_view(), name="session-legal-current"),
    path("join/preview/", JoinSessionPreviewAPIView.as_view(), name="session-join-preview"),
    path("join/", JoinSessionAPIView.as_view(), name="session-join"),
    path('my-results/', OwnResultsAPIView.as_view(), name='my-results'),
    path('<uuid:session_uuid>/participation/', ParticipationAPIView.as_view(), name='session-participation'),
    path('<uuid:session_uuid>/answer/', SubmitAnswerAPIView.as_view(), name='session-answer'),
    path('<uuid:session_uuid>/display-state/', DisplayStateAPIView.as_view(), name='session-display-state'),
    path("", include(router.urls)),
]
