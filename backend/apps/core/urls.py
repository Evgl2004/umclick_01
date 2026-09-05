from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView

from apps.core.views import RateLimitedTokenObtainPairView, TeacherMeAPIView, TeacherRegisterAPIView

urlpatterns = [
    path("register/", TeacherRegisterAPIView.as_view(), name="teacher-register"),
    path(
        "token/",
        RateLimitedTokenObtainPairView.as_view(),
        name="token-obtain-pair",
    ),
    path("token/refresh/", TokenRefreshView.as_view(), name="token-refresh"),
    path("me/", TeacherMeAPIView.as_view(), name="teacher-me"),
]
