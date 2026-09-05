from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, override_settings
from rest_framework.test import APIRequestFactory, APITestCase

from apps.core.request_identity import client_address, normalize_login, websocket_client_address


class LoginNormalizationTests(APITestCase):
    def test_token_login_uses_the_shared_django_normalization(self):
        get_user_model().objects.create_user(
            username='Teacher',
            password='test-password-123',
        )

        response = self.client.post(
            '/api/auth/token/',
            {'username': 'Ｔｅａｃｈｅｒ', 'password': 'test-password-123'},
            format='json',
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(normalize_login('Ｔｅａｃｈｅｒ'), 'Teacher')
        self.assertEqual(normalize_login('Teacher'), 'Teacher')
        self.assertEqual(normalize_login('teacher'), 'teacher')

    def test_registration_checks_uniqueness_after_shared_normalization(self):
        get_user_model().objects.create_user(
            username='Teacher',
            password='test-password-123',
        )

        response = self.client.post(
            '/api/auth/register/',
            {'username': 'Ｔｅａｃｈｅｒ', 'password': 'another-test-password-123'},
            format='json',
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(get_user_model().objects.filter(username='Teacher').count(), 1)


class ClientAddressTests(SimpleTestCase):
    def setUp(self):
        self.factory = APIRequestFactory()

    @override_settings(TRUSTED_PROXY_CIDRS=[])
    def test_untrusted_peer_cannot_spoof_forwarded_address(self):
        request = self.factory.get(
            '/',
            HTTP_X_FORWARDED_FOR='198.51.100.77',
            HTTP_X_REAL_IP='198.51.100.78',
            REMOTE_ADDR='203.0.113.10',
        )

        self.assertEqual(client_address(request), '203.0.113.10')

    @override_settings(TRUSTED_PROXY_CIDRS=['127.0.0.0/8', '10.0.0.0/8'])
    def test_trusted_proxy_chain_is_read_from_right_to_left(self):
        request = self.factory.get(
            '/',
            HTTP_X_FORWARDED_FOR='198.51.100.77, 10.0.0.5',
            REMOTE_ADDR='127.0.0.1',
        )

        self.assertEqual(client_address(request), '198.51.100.77')

    @override_settings(TRUSTED_PROXY_CIDRS=['127.0.0.0/8'])
    def test_malformed_forwarded_chain_falls_back_to_immediate_peer(self):
        request = self.factory.get(
            '/',
            HTTP_X_FORWARDED_FOR='198.51.100.77, неверный-адрес',
            REMOTE_ADDR='127.0.0.1',
        )

        self.assertEqual(client_address(request), '127.0.0.1')

    @override_settings(TRUSTED_PROXY_CIDRS=['127.0.0.0/8'])
    def test_ipv6_address_is_canonicalized(self):
        request = self.factory.get(
            '/',
            HTTP_X_REAL_IP='2001:0db8:0:0:0:0:0:1',
            REMOTE_ADDR='127.0.0.1',
        )

        self.assertEqual(client_address(request), '2001:db8::1')

    @override_settings(TRUSTED_PROXY_CIDRS=['127.0.0.0/8'])
    def test_websocket_scope_uses_the_same_trusted_proxy_rule(self):
        scope = {
            'client': ('127.0.0.1', 50000),
            'headers': [(b'x-forwarded-for', b'198.51.100.77')],
        }

        self.assertEqual(websocket_client_address(scope), '198.51.100.77')
