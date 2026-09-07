from django.db import transaction
from django.db.models import Exists, OuterRef
from rest_framework import serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response

from apps.core.permissions import IsTeacher, is_admin
from apps.quiz.models import Quiz
from apps.quiz.serializers import QuizSerializer
from apps.quiz.services import (
    archive_quiz,
    delete_quiz,
    effective_version_prefetch,
    restore_quiz,
)
from apps.session.models import LiveSession


class QuizViewSet(viewsets.ModelViewSet):
    queryset = Quiz.objects.all()
    serializer_class = QuizSerializer
    permission_classes = [IsTeacher]

    def get_queryset(self):
        session_exists = LiveSession.objects.filter(
            quiz_version__quiz_id=OuterRef('pk'),
        )
        queryset = (
            super()
            .get_queryset()
            .annotate(can_delete=~Exists(session_exists))
            .prefetch_related(effective_version_prefetch())
        )
        if not is_admin(self.request.user):
            queryset = queryset.filter(owner=self.request.user)
        if self.action == 'list':
            archived = self.request.query_params.get('archived', 'false').lower()
            if archived not in {'true', 'false'}:
                raise serializers.ValidationError({
                    'archived': 'Используйте значение true или false.'
                })
            queryset = queryset.filter(archived_at__isnull=archived == 'false')
        return queryset

    @action(detail=True, methods=['post'])
    def archive(self, request, pk=None):
        quiz = self.get_object()
        with transaction.atomic():
            archived_quiz = archive_quiz(quiz_id=quiz.pk, actor=request.user)
            response_data = self.get_serializer(archived_quiz).data
        return Response(response_data)

    @action(detail=True, methods=['post'])
    def restore(self, request, pk=None):
        quiz = self.get_object()
        with transaction.atomic():
            restored_quiz = restore_quiz(quiz_id=quiz.pk, actor=request.user)
            response_data = self.get_serializer(restored_quiz).data
        return Response(response_data)

    def destroy(self, request, *args, **kwargs):
        quiz = self.get_object()
        delete_quiz(quiz_id=quiz.pk, actor=request.user)
        return Response(status=status.HTTP_204_NO_CONTENT)
