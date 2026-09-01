from django.core.exceptions import ValidationError
from django.db.models.deletion import ProtectedError
from rest_framework.exceptions import APIException
from rest_framework.response import Response
from rest_framework.views import exception_handler as default_handler

from apps.core.protection import HistoryConflict


class Conflict(APIException):
    status_code = 409
    default_detail = 'Операция противоречит текущему состоянию.'
    default_code = 'state_conflict'


def exception_handler(exc, context):
    if isinstance(exc, (HistoryConflict, ProtectedError)):
        payload = {'detail': 'Операция запрещена: использованное содержимое и игровая история защищены.'}
        session_uuid = getattr(exc, 'blocking_session_uuid', None)
        if session_uuid:
            from apps.core.permissions import can_manage_session
            from apps.session.models import LiveSession
            session = LiveSession.objects.select_related('quiz').get(join_token=session_uuid)
            if can_manage_session(context['request'].user, session):
                payload['session_uuid'] = str(session_uuid)
        return Response(payload, status=409)
    if isinstance(exc, ValidationError):
        return Response(exc.message_dict if hasattr(exc, 'message_dict') else {'detail': exc.messages}, status=400)
    return default_handler(exc, context)
