from django.core.exceptions import ValidationError
from django.db.models.deletion import ProtectedError
from rest_framework.exceptions import APIException, AuthenticationFailed
from rest_framework.response import Response

from apps.core.protection import HistoryConflict


class Conflict(APIException):
    status_code = 409
    default_detail = 'Операция противоречит текущему состоянию.'
    default_code = 'conflict'

    def __init__(self, detail=None):
        super().__init__(detail)
        self.response_data = {
            'code': self.default_code,
            'detail': str(self.detail),
        }


class StateConflict(Conflict):
    """Конфликт с типизированным снимком актуального серверного состояния."""

    def __init__(self, message: str, state: dict):
        super().__init__(message)
        self.response_data = {
            'code': 'state_conflict',
            'detail': message,
            'state': state,
        }


class QuizRevisionConflict(Conflict):
    """Конфликт оптимистической блокировки содержимого викторины."""

    default_code = 'quiz_revision_conflict'

    def __init__(self, current_revision: int):
        message = 'Викторина уже изменена. Обновите данные и повторите сохранение.'
        super().__init__(message)
        self.response_data = {
            'code': self.default_code,
            'detail': message,
            'current_content_revision': current_revision,
        }


class AccessAuthenticationFailed(AuthenticationFailed):
    """Безопасная машинно-читаемая причина отказа ролевого доступа."""

    def __init__(self, message: str, code: str):
        super().__init__(message, code=code)
        self.response_data = {'code': code, 'detail': message}


class RateLimitExceeded(APIException):
    status_code = 429
    default_code = 'rate_limited'

    def __init__(self, retry_after: int):
        message = 'Слишком много запросов. Повторите попытку позже.'
        super().__init__(message, code=self.default_code)
        self.retry_after = retry_after
        self.response_data = {
            'code': self.default_code,
            'detail': message,
            'retry_after': retry_after,
        }


class LimiterServiceUnavailable(APIException):
    status_code = 503
    default_code = 'limiter_unavailable'

    def __init__(self, retry_after: int = 3):
        message = 'Сервис временно недоступен. Повторите попытку позже.'
        super().__init__(message, code=self.default_code)
        self.retry_after = retry_after
        self.response_data = {
            'code': self.default_code,
            'detail': message,
            'retry_after': retry_after,
        }


def exception_handler(exc, context):
    from rest_framework.views import exception_handler as default_handler

    if isinstance(exc, StateConflict):
        return Response(exc.response_data, status=exc.status_code)
    if isinstance(exc, Conflict):
        return Response(exc.response_data, status=exc.status_code)
    if isinstance(exc, AccessAuthenticationFailed):
        return Response(exc.response_data, status=exc.status_code)
    if isinstance(exc, (RateLimitExceeded, LimiterServiceUnavailable)):
        return Response(
            exc.response_data,
            status=exc.status_code,
            headers={'Retry-After': str(exc.retry_after)},
        )
    if isinstance(exc, (HistoryConflict, ProtectedError)):
        payload = {
            'code': 'conflict',
            'detail': 'Операция запрещена: использованное содержимое и игровая история защищены.',
        }
        session_uuid = getattr(exc, 'blocking_session_uuid', None)
        if session_uuid:
            from apps.core.permissions import can_manage_session
            from apps.session.models import LiveSession
            session = LiveSession.objects.select_related(
                'quiz_version', 'quiz_version__quiz'
            ).get(join_token=session_uuid)
            if can_manage_session(context['request'].user, session):
                payload['session_uuid'] = str(session_uuid)
        return Response(payload, status=409)
    if isinstance(exc, ValidationError):
        return Response(exc.message_dict if hasattr(exc, 'message_dict') else {'detail': exc.messages}, status=400)
    return default_handler(exc, context)
