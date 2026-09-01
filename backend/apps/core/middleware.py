from django.db.models.deletion import ProtectedError
from django.http import HttpResponse
from django.utils.deprecation import MiddlewareMixin
from apps.core.protection import HistoryConflict


class HistoryProtectionMiddleware(MiddlewareMixin):
    def process_exception(self, request, exception):
        if isinstance(exception, (HistoryConflict, ProtectedError)):
            return HttpResponse('Операция запрещена: использованное содержимое и игровая история защищены.', status=409, content_type='text/plain; charset=utf-8')
