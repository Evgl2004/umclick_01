import os

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import transaction
from rest_framework import serializers
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer

from apps.core.request_identity import normalize_login


User = get_user_model()


class TeacherRegisterSerializer(serializers.Serializer):
    username = serializers.CharField(max_length=150)
    email = serializers.EmailField(required=False, allow_blank=True)
    password = serializers.CharField(write_only=True, min_length=8)
    first_name = serializers.CharField(max_length=150, required=False, allow_blank=True)
    last_name = serializers.CharField(max_length=150, required=False, allow_blank=True)
    signup_code = serializers.CharField(required=False, allow_blank=True)

    def validate_username(self, value):
        value = normalize_login(value)
        if User.objects.filter(username=value).exists():
            raise serializers.ValidationError('Имя пользователя уже занято.')
        return value

    def validate(self, attrs):
        expected_signup_code = os.getenv("TEACHER_SIGNUP_CODE", "").strip()
        provided_code = attrs.get("signup_code", "").strip()
        if expected_signup_code and provided_code != expected_signup_code:
            raise serializers.ValidationError('Неверный код регистрации преподавателя.')
        return attrs

    @transaction.atomic
    def create(self, validated_data):
        validated_data.pop("signup_code", None)
        password = validated_data.pop("password")
        user = User.objects.create_user(
            **validated_data,
            password=password,
            is_staff=False,
        )
        user.groups.add(Group.objects.get_or_create(name='teacher')[0])
        return user


class TeacherSerializer(serializers.ModelSerializer):
    roles = serializers.SerializerMethodField()

    def get_roles(self, obj):
        from apps.core.permissions import is_admin
        return (['admin'] if is_admin(obj) else []) + list(obj.groups.filter(name__in=['teacher', 'participant']).values_list('name', flat=True))

    class Meta:
        model = User
        fields = ["id", "username", "email", "first_name", "last_name", "is_staff", "roles"]


class NormalizedTokenObtainPairSerializer(TokenObtainPairSerializer):
    def validate(self, attrs):
        attrs = dict(attrs)
        attrs[self.username_field] = normalize_login(attrs.get(self.username_field))
        return super().validate(attrs)
