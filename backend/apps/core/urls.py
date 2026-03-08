from django.urls import path
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

from apps.core.views import TeacherMeAPIView, TeacherRegisterAPIView

urlpatterns = [
    path("register/", TeacherRegisterAPIView.as_view(), name="teacher-register"),
    path("token/", TokenObtainPairView.as_view(), name="token-obtain-pair"),
    path("token/refresh/", TokenRefreshView.as_view(), name="token-refresh"),
    path("me/", TeacherMeAPIView.as_view(), name="teacher-me"),
]
