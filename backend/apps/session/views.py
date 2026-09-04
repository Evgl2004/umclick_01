import csv
from django.db import transaction
from django.http import HttpResponse
from django.utils import timezone
from rest_framework import permissions, status, viewsets, serializers
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.errors import Conflict
from apps.core.permissions import IsTeacher, is_admin
from apps.session.access import issue_secret, scoped_session, resolve_join_session
from apps.session.advance import advance_session_if_due
from apps.session.gameplay import execute_manual_command
from apps.session.legal import get_current_legal_documents
from apps.session.models import LiveSession, SessionParticipant, SessionDisplayAccess
from apps.session.participation import JoinInput, join_session, own_result
from apps.session.realtime import (
    broadcast_session_event,
    build_account_session_state,
    build_display_session_state,
    build_participant_session_state,
)
from apps.session.serializers import (
    LiveSessionCreateSerializer,
    LiveSessionSerializer,
    SessionCommandInputSerializer,
    SubmitAnswerSerializer,
    build_leaderboard,
)


class LiveSessionViewSet(viewsets.ModelViewSet):
    queryset = LiveSession.objects.select_related('quiz', 'current_question')
    permission_classes = [IsTeacher]
    lookup_field = 'join_token'
    lookup_url_kwarg = 'pk'
    lookup_value_regex = '[0-9a-fA-F-]{36}'
    http_method_names = ['get', 'post', 'delete', 'head', 'options']

    def get_queryset(self):
        queryset = super().get_queryset()
        return queryset if is_admin(self.request.user) else queryset.filter(quiz__owner=self.request.user)

    def get_serializer_class(self):
        return LiveSessionCreateSerializer if self.action == 'create' else LiveSessionSerializer

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    @action(detail=True, methods=['post'])
    def start(self, request, pk=None):
        return self._command(request, pk, 'start_session')

    @action(detail=True, methods=['post'], url_path='start-quiz')
    def start_quiz(self, request, pk=None):
        return self._command(request, pk, 'start_quiz')

    @action(detail=True, methods=['post'], url_path='end-question')
    def end_question(self, request, pk=None):
        return self._command(request, pk, 'end_question')

    @action(detail=True, methods=['post'])
    def finish(self, request, pk=None):
        return self._command(request, pk, 'abort_session')

    @action(detail=True, methods=['post'], url_path='next-question')
    def next_question(self, request, pk=None):
        return self._command(request, pk, 'next_question')

    def _command(self, request, pk, kind):
        session = self.get_object()
        form = SessionCommandInputSerializer(data=request.data)
        form.is_valid(raise_exception=True)
        response, repeated = execute_manual_command(session.pk, kind, form.validated_data)
        return Response({**response, 'repeated': repeated})

    @action(detail=True, methods=['get'])
    def state(self, request, pk=None):
        session, _ = advance_session_if_due(self.get_object())
        return Response(build_account_session_state(session))

    @action(detail=True, methods=['get'], url_path='results/export')
    def export_results(self, request, pk=None):
        session = self.get_object()
        response = HttpResponse(content_type='text/csv; charset=utf-8')
        response['Content-Disposition'] = f'attachment; filename="session_{session.join_token}_results.csv"'
        writer = csv.writer(response)
        rows = build_leaderboard(session)
        if session.gameplay_schema == LiveSession.GAMEPLAY_SCHEMA_LEGACY:
            writer.writerow(['Место', 'Имя участника', 'Телефон', 'Баллы', 'Правильные ответы', 'Время ответа, мс'])
            for row in rows:
                writer.writerow([row['rank'], row['participant_name'], row['phone'], row['points'], row['correct_answers'], row['answer_time_ms']])
        else:
            writer.writerow(['Место', 'Имя участника', 'Телефон', 'Правильные ответы', 'Сумма времени правильных ответов, мс'])
            for row in rows:
                writer.writerow([row['rank'], row['participant_name'], row['phone'], row['correct_answers'], row['correct_time_ms']])
        return response

    @action(detail=True, methods=['get'])
    def leaderboard(self, request, pk=None):
        session = self.get_object()
        if session.gameplay_schema == LiveSession.GAMEPLAY_SCHEMA_V2 and not session.question_runs.filter(finalized_at__isnull=False).exists():
            raise Conflict('Рейтинг ещё не сформирован.')
        return Response(build_leaderboard(session))

    @action(detail=True, methods=['post'], url_path='display-access')
    @transaction.atomic
    def display_access(self, request, pk=None):
        session = LiveSession.objects.select_for_update().get(pk=self.get_object().pk)
        secret, digest = issue_secret('display')
        grant = SessionDisplayAccess(session=session, token_digest=digest)
        if not grant.is_valid:
            raise Conflict('Срок доступа к показу этой сессии истёк.')
        grant.save()
        response = Response({'id': str(grant.pk), 'display_token': secret}, status=201)
        response['Cache-Control'] = 'no-store'
        return response

    @action(detail=True, methods=['delete'], url_path=r'display-access/(?P<grant_id>[0-9a-fA-F-]{36})')
    @transaction.atomic
    def revoke_display_access(self, request, pk=None, grant_id=None):
        from django.shortcuts import get_object_or_404
        session = self.get_object()
        grant = get_object_or_404(SessionDisplayAccess.objects.select_for_update(), pk=grant_id, session=session)
        if grant.revoked_at is None:
            grant.revoked_at = timezone.now()
            grant.save(update_fields=['revoked_at'])
        broadcast_session_event(session.pk, 'access_revoked', {})
        return Response(status=204)


class CurrentLegalDocumentsAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def get(self, request):
        return Response(get_current_legal_documents())


class JoinSessionPreviewAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def get(self, request):
        query = dict(pin=request.query_params.get('pin'), join_token=request.query_params.get('join_token') or request.query_params.get('token'))
        form = JoinInput(data={key: value for key, value in query.items() if value})
        form.is_valid(raise_exception=True)
        session = resolve_join_session(pin=form.validated_data.get('pin'), join_token=form.validated_data.get('join_token'))
        return Response({'session_uuid': str(session.join_token), 'can_join': session.status == LiveSession.STATUS_WAITING,
                         'quiz': {'title': session.quiz.title, 'description': session.quiz.description},
                         'legal_documents': get_current_legal_documents()})


class JoinSessionAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        form = JoinInput(data=request.data)
        form.is_valid(raise_exception=True)
        participation, secret = join_session(request, form.validated_data)
        payload = own_result(participation)
        if secret:
            payload['participant_token'] = secret
            broadcast_session_event(participation.session_id, 'participant_joined', {})
        response = Response(payload)
        response['Cache-Control'] = 'no-store'
        return response


class ParticipationAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def get(self, request, session_uuid):
        session = scoped_session(request, session_uuid, 'participant')
        session, _ = advance_session_if_due(session)
        participation = SessionParticipant.objects.get(pk=request.auth.record_id)
        payload = own_result(participation)
        payload['state'] = build_participant_session_state(session, participation.pk)
        return Response(payload)


class DisplayStateAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def get(self, request, session_uuid):
        session = scoped_session(request, session_uuid, 'display')
        session, _ = advance_session_if_due(session)
        return Response(build_display_session_state(session))


class SubmitAnswerAPIView(APIView):
    permission_classes = [permissions.AllowAny]

    def post(self, request, session_uuid):
        session = scoped_session(request, session_uuid, 'participant')
        participation = SessionParticipant.objects.get(pk=request.auth.record_id)
        form = SubmitAnswerSerializer(data=request.data, context={'participation': participation})
        form.is_valid(raise_exception=True)
        form.save()
        return Response({'accepted': True, 'message': 'Ответ зафиксирован'})


class OwnResultsAPIView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        participations = SessionParticipant.objects.filter(participant__user=request.user).select_related('session__quiz')
        return Response([own_result(item) for item in participations])
