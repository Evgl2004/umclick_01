from pathlib import Path

from django.test import SimpleTestCase


REPOSITORY_ROOT = Path(__file__).resolve().parents[4]


class DemoNginxRateLimitTests(SimpleTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.config = (REPOSITORY_ROOT / 'deploy' / 'nginx.demo.conf').read_text(
            encoding='utf-8-sig'
        )
        cls.compose = (REPOSITORY_ROOT / 'deploy' / 'docker-compose.demo.yml').read_text(
            encoding='utf-8-sig'
        )

    def test_exact_entry_routes_and_all_other_api_routes_are_separate(self):
        for route in (
            'POST:/api/auth/register/',
            'POST:/api/auth/token/',
            'POST:/api/auth/token/refresh/',
            'GET:/api/sessions/join/preview/',
            'POST:/api/sessions/join/',
        ):
            self.assertIn(f'"{route}" login;', self.config)
        self.assertIn('~^(?!OPTIONS:)[A-Z]+:/api/ game;', self.config)

    def test_four_independent_zones_have_approved_rates_and_bursts(self):
        for fragment in (
            'zone=login_ip:10m rate=10r/s;',
            'zone=login_stage:10m rate=30r/s;',
            'zone=game_ip:10m rate=100r/s;',
            'zone=game_stage:10m rate=200r/s;',
            'zone=login_ip burst=120 nodelay;',
            'zone=login_stage burst=240 nodelay;',
            'zone=game_ip burst=300 nodelay;',
            'zone=game_stage burst=600 nodelay;',
        ):
            self.assertIn(fragment, self.config)

    def test_only_local_nginx_429_gets_static_retry_after(self):
        self.assertIn('limit_req_status 429;', self.config)
        self.assertIn('error_page 429 = @nginx_rate_limited;', self.config)
        self.assertIn('add_header Retry-After 1 always;', self.config)
        self.assertIn('proxy_intercept_errors off;', self.config)

    def test_proxy_overwrites_forwarding_headers(self):
        self.assertEqual(self.config.count('X-Forwarded-For $remote_addr;'), 2)
        self.assertNotIn('$proxy_add_x_forwarded_for', self.config)

    def test_compose_publishes_only_frontend_port(self):
        self.assertEqual(self.compose.count('    ports:'), 1)
        backend = self.compose.split('  backend:', 1)[1].split('  celery-worker:', 1)[0]
        self.assertNotIn('ports:', backend)
