from rest_framework import viewsets

from apps.quiz.models import Quiz
from apps.quiz.serializers import QuizSerializer


class QuizViewSet(viewsets.ModelViewSet):
    queryset = Quiz.objects.prefetch_related("questions__choices").all()
    serializer_class = QuizSerializer
