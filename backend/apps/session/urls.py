from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.session.views import JoinSessionAPIView, LiveSessionViewSet, SubmitAnswerAPIView

router = DefaultRouter()
router.register("", LiveSessionViewSet, basename="session")

urlpatterns = [
    path("join/", JoinSessionAPIView.as_view(), name="session-join"),
    path("answer/", SubmitAnswerAPIView.as_view(), name="session-answer"),
    path("", include(router.urls)),
]
