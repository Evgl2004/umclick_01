from rest_framework import viewsets

from apps.core.permissions import IsTeacher, is_admin
from apps.quiz.models import Quiz
from apps.quiz.serializers import QuizSerializer
from apps.quiz.services import effective_version_prefetch


class QuizViewSet(viewsets.ModelViewSet):
    queryset = Quiz.objects.prefetch_related(effective_version_prefetch()).all()
    serializer_class = QuizSerializer
    permission_classes = [IsTeacher]

    def get_queryset(self):
        queryset = super().get_queryset()
        return queryset if is_admin(self.request.user) else queryset.filter(owner=self.request.user)
