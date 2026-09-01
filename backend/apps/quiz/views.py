from rest_framework import viewsets

from apps.core.permissions import IsTeacher, is_admin
from apps.quiz.models import Quiz
from apps.quiz.serializers import QuizSerializer


class QuizViewSet(viewsets.ModelViewSet):
    queryset = Quiz.objects.prefetch_related("questions__choices").all()
    serializer_class = QuizSerializer
    permission_classes = [IsTeacher]

    def get_queryset(self):
        queryset = super().get_queryset()
        return queryset if is_admin(self.request.user) else queryset.filter(owner=self.request.user)

    def perform_create(self, serializer):
        serializer.save(owner=self.request.user)
