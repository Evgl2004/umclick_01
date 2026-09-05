from ipaddress import ip_address, ip_network

from django.conf import settings
from django.contrib.auth import get_user_model


def normalize_login(value):
    """Нормализует логин тем же правилом, которое использует модель пользователя."""
    if not isinstance(value, str):
        return value
    return get_user_model().normalize_username(value)


def _trusted_proxy_networks():
    networks = []
    for value in getattr(settings, 'TRUSTED_PROXY_CIDRS', []):
        try:
            networks.append(ip_network(value, strict=False))
        except (TypeError, ValueError):
            continue
    return networks


def _is_trusted(address, networks):
    return any(address in network for network in networks)


def _canonical_client_address(raw_peer, forwarded='', real_ip=''):
    try:
        peer = ip_address(raw_peer)
    except (TypeError, ValueError):
        return 'unknown'

    networks = _trusted_proxy_networks()
    if not _is_trusted(peer, networks):
        return str(peer)

    values = [value.strip() for value in forwarded.split(',') if value.strip()]
    if not values:
        real_ip = real_ip.strip()
        values = [real_ip] if real_ip else []

    current = peer
    for value in reversed(values):
        if not _is_trusted(current, networks):
            break
        try:
            current = ip_address(value)
        except ValueError:
            return str(peer)
    return str(current)


def client_address(request):
    """Возвращает канонический адрес HTTP-клиента без доверия внешним заголовкам."""
    return _canonical_client_address(
        request.META.get('REMOTE_ADDR', ''),
        request.META.get('HTTP_X_FORWARDED_FOR', ''),
        request.META.get('HTTP_X_REAL_IP', ''),
    )


def websocket_client_address(scope):
    """Возвращает тот же канонический адрес для ASGI WebSocket-соединения."""
    client = scope.get('client') or ()
    raw_peer = client[0] if client else ''
    headers = {}
    for raw_name, raw_value in scope.get('headers', []):
        try:
            headers[raw_name.decode('ascii').lower()] = raw_value.decode('ascii')
        except UnicodeError:
            continue
    return _canonical_client_address(
        raw_peer,
        headers.get('x-forwarded-for', ''),
        headers.get('x-real-ip', ''),
    )
