from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.session.views import (
    CurrentLegalDocumentsAPIView,
    JoinSessionAPIView,
    JoinSessionPreviewAPIView,
    LiveSessionViewSet,
    SubmitAnswerAPIView,
)

router = DefaultRouter()
router.register("", LiveSessionViewSet, basename="session")

urlpatterns = [
    path("legal/current/", CurrentLegalDocumentsAPIView.as_view(), name="session-legal-current"),
    path("join/preview/", JoinSessionPreviewAPIView.as_view(), name="session-join-preview"),
    path("join/", JoinSessionAPIView.as_view(), name="session-join"),
    path("answer/", SubmitAnswerAPIView.as_view(), name="session-answer"),
    path("", include(router.urls)),
]
