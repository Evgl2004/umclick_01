from rest_framework import permissions, status
from django.contrib.auth import get_user_model
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.views import TokenObtainPairView

from apps.core.rate_limit import enforce_rate_limits, limit_per_minute
from apps.core.request_identity import client_address, normalize_login
from apps.core.serializers import (
    NormalizedTokenObtainPairSerializer,
    TeacherRegisterSerializer,
    TeacherSerializer,
)


class RateLimitedTokenObtainPairView(TokenObtainPairView):
    serializer_class = NormalizedTokenObtainPairSerializer

    def post(self, request, *args, **kwargs):
        username_field = get_user_model().USERNAME_FIELD
        normalized_login = normalize_login(request.data.get(username_field, ''))
        address = client_address(request)
        enforce_rate_limits(
            [
                limit_per_minute('login_name', normalized_login, 10, 10),
                limit_per_minute('login_ip', address, 60, 30),
            ]
        )
        return super().post(request, *args, **kwargs)


class TeacherRegisterAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        serializer = TeacherRegisterSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        teacher = serializer.save()
        return Response(TeacherSerializer(teacher).data, status=status.HTTP_201_CREATED)


class TeacherMeAPIView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        return Response(TeacherSerializer(request.user).data)
