from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone
from rest_framework import serializers
from rest_framework.exceptions import AuthenticationFailed

from apps.core.errors import Conflict
from apps.session.access import ScopedAccess, issue_secret, resolve_join_session
from apps.session.legal import get_current_consent_versions
from apps.session.models import LiveSession, Participant, SessionParticipant, ParticipantAnswer


class JoinInput(serializers.Serializer):
    pin = serializers.RegexField(r'^\d{6}$', required=False)
    join_token = serializers.UUIDField(required=False)
    name = serializers.CharField(max_length=255, required=False)
    phone = serializers.CharField(max_length=32, required=False, allow_blank=True, allow_null=True)
    consent = serializers.BooleanField(required=False, default=False)

    def validate(self, attrs):
        if not attrs.get('pin') and not attrs.get('join_token'):
            raise serializers.ValidationError('Укажите PIN или публичный UUID сессии.')
        return attrs


@transaction.atomic
def join_session(request, data):
    session = resolve_join_session(pin=data.get('pin'), join_token=data.get('join_token'))
    session = LiveSession.objects.select_for_update().get(pk=session.pk)
    access = request.auth
    if isinstance(access, ScopedAccess):
        if access.kind != 'participant' or access.session_id != session.pk:
            raise AuthenticationFailed('Токен не разрешает участие в этой сессии.')
        return SessionParticipant.objects.get(pk=access.record_id), None
    user = request.user if request.user.is_authenticated else None
    if user:
        get_user_model().objects.select_for_update().get(pk=user.pk)
        existing = SessionParticipant.objects.filter(session=session, participant__user=user).first()
        if existing:
            raise Conflict('Участие уже зарегистрировано. Для возвращения нужен прежний токен; перевыпуск недоступен.')
    if session.status != LiveSession.STATUS_WAITING:
        raise Conflict('Регистрация закрыта. Вернуться можно только с действительным токеном участия.')
    if not data.get('name'):
        raise serializers.ValidationError({'name': 'Введите имя участника.'})
    consent = data.get('consent', False)
    privacy, personal = get_current_consent_versions()
    defaults = dict(name=data['name'], phone=data.get('phone') or None, consent=consent,
                    consent_given_at=timezone.now() if consent else None,
                    privacy_policy_version=privacy if consent else '',
                    personal_data_consent_version=personal if consent else '')
    participant = Participant.objects.get_or_create(user=user, defaults=defaults)[0] if user else Participant.objects.create(**defaults)
    secret, digest = issue_secret('participant')
    participation = SessionParticipant.objects.create(session=session, participant=participant,
                                                      name_snapshot=data['name'], token_digest=digest)
    return participation, secret


def own_result(participation):
    session = participation.session
    result = {'session_uuid': str(session.join_token), 'session_participant_id': participation.pk,
              'name': participation.name_snapshot, 'status': session.status, 'quiz_title': session.quiz.title}
    if session.status in {LiveSession.STATUS_FINISHED, LiveSession.STATUS_ABORTED}:
        result['answers'] = list(ParticipantAnswer.objects.filter(session_participant=participation).values(
            'question_id', 'choice_id', 'is_correct', 'score_points', 'elapsed_ms'))
    return result
