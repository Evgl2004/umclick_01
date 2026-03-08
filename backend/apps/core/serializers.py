import os

from django.contrib.auth import get_user_model
from rest_framework import serializers


User = get_user_model()


class TeacherRegisterSerializer(serializers.Serializer):
    username = serializers.CharField(max_length=150)
    email = serializers.EmailField(required=False, allow_blank=True)
    password = serializers.CharField(write_only=True, min_length=8)
    first_name = serializers.CharField(max_length=150, required=False, allow_blank=True)
    last_name = serializers.CharField(max_length=150, required=False, allow_blank=True)
    signup_code = serializers.CharField(required=False, allow_blank=True)

    def validate_username(self, value):
        if User.objects.filter(username=value).exists():
            raise serializers.ValidationError("Username already exists.")
        return value

    def validate(self, attrs):
        expected_signup_code = os.getenv("TEACHER_SIGNUP_CODE", "").strip()
        provided_code = attrs.get("signup_code", "").strip()
        if expected_signup_code and provided_code != expected_signup_code:
            raise serializers.ValidationError("Invalid signup_code for teacher registration.")
        return attrs

    def create(self, validated_data):
        validated_data.pop("signup_code", None)
        password = validated_data.pop("password")
        user = User.objects.create_user(
            **validated_data,
            password=password,
            is_staff=True,
        )
        return user


class TeacherSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ["id", "username", "email", "first_name", "last_name", "is_staff"]
