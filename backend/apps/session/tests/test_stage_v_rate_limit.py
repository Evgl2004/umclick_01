from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock, patch

from django.test import SimpleTestCase, override_settings
from redis.exceptions import ConnectionError as RedisConnectionError

from apps.core.rate_limit import (
    LUA_TOKEN_BUCKET,
    TOKEN_UNITS,
    LimiterUnavailable,
    RedisRateLimiter,
    get_process_redis_client,
    limit_per_minute,
    limit_per_second,
    reset_process_redis_clients,
)
from apps.core.websocket_limits import RedisWebSocketGuard


class RecordingRedis:
    def __init__(self, result=None, error=None):
        self.result = result or [1, 0, 1_000]
        self.error = error
        self.calls = []

    def eval(self, *arguments):
        self.calls.append(arguments)
        if self.error:
            raise self.error
        return self.result


class TokenBucketConfigurationTests(SimpleTestCase):
    def test_approved_rates_use_exact_integer_scale(self):
        limits = [
            limit_per_minute('login', 'subject', 10, 10),
            limit_per_minute('pin', 'subject', 60, 120),
            limit_per_second('command', 'subject', 2, 10),
            limit_per_second('state', 'subject', 5, 20),
            limit_per_second('answer', 'subject', 10, 40),
        ]

        self.assertEqual(TOKEN_UNITS, 60_000)
        self.assertEqual([item.refill_units_per_ms for item in limits], [10, 60, 120, 300, 600])
        self.assertEqual(
            [item.capacity_units for item in limits],
            [600_000, 7_200_000, 600_000, 1_200_000, 2_400_000],
        )

    def test_lua_contains_time_last_ms_atomicity_and_ttl_invariants(self):
        self.assertIn("redis.call('TIME')", LUA_TOKEN_BUCKET)
        self.assertIn('math.max(0, now_ms - stored_last_ms)', LUA_TOKEN_BUCKET)
        self.assertIn('math.max(stored_last_ms, now_ms)', LUA_TOKEN_BUCKET)
        self.assertIn("redis.call('PEXPIRE', KEYS[i], state.ttl_ms)", LUA_TOKEN_BUCKET)
        self.assertLess(
            LUA_TOKEN_BUCKET.index('if allowed == 1 then'),
            LUA_TOKEN_BUCKET.index('state.tokens = state.tokens - token_cost'),
        )


class RedisRateLimiterTests(SimpleTestCase):
    @override_settings(RATE_LIMIT_NAMESPACE='umclick:test:unit', RATE_LIMIT_HMAC_SECRET='test-only-secret')
    def test_all_buckets_are_checked_by_one_atomic_eval_without_raw_subjects(self):
        client = RecordingRedis()
        limiter = RedisRateLimiter(client=client)
        limits = [
            limit_per_minute('login_name', 'Teacher', 10, 10),
            limit_per_minute('login_ip', '203.0.113.10', 60, 30),
        ]

        decision = limiter.check(limits)

        self.assertTrue(decision.allowed)
        self.assertEqual(len(client.calls), 1)
        arguments = client.calls[0]
        self.assertEqual(arguments[1], 2)
        keys = arguments[2:4]
        self.assertTrue(all(key.startswith('umclick:test:unit:') for key in keys))
        self.assertNotIn('Teacher', str(keys))
        self.assertNotIn('203.0.113.10', str(keys))

    @override_settings(RATE_LIMIT_NAMESPACE='umclick:test:unit', RATE_LIMIT_HMAC_SECRET='test-only-secret')
    def test_retry_after_is_rounded_up_to_seconds(self):
        limiter = RedisRateLimiter(client=RecordingRedis(result=[0, 1_001, 1_000]))

        decision = limiter.check([limit_per_second('answer', 'access', 10, 40)])

        self.assertFalse(decision.allowed)
        self.assertEqual(decision.retry_after, 2)

    @override_settings(RATE_LIMIT_REDIS_URL='redis://127.0.0.1:6379/15')
    def test_redis_failure_is_fail_closed(self):
        limiter = RedisRateLimiter(
            client=RecordingRedis(error=RedisConnectionError('test failure')),
        )

        with self.assertRaises(LimiterUnavailable):
            limiter.check([limit_per_second('answer', 'access', 10, 40)])

    @override_settings(RATE_LIMIT_REDIS_URL='', REDIS_URL='')
    def test_missing_redis_configuration_is_unavailable(self):
        with self.assertRaises(LimiterUnavailable):
            RedisRateLimiter().check([limit_per_second('answer', 'access', 10, 40)])


class ProcessRedisClientTests(SimpleTestCase):
    def setUp(self):
        reset_process_redis_clients()

    def tearDown(self):
        reset_process_redis_clients()

    @override_settings(
        RATE_LIMIT_REDIS_URL='redis://127.0.0.1:6379/0',
        WS_LIMIT_REDIS_URL='redis://127.0.0.1:6379/0',
    )
    @patch('apps.core.rate_limit.redis.Redis.from_url')
    def test_http_and_websocket_share_one_process_client_concurrently(self, factory):
        shared = Mock()
        factory.return_value = shared

        def resolve(index):
            if index % 2:
                return RedisRateLimiter()._redis_client()
            return RedisWebSocketGuard()._redis_client()

        with ThreadPoolExecutor(max_workers=12) as pool:
            clients = list(pool.map(resolve, range(48)))

        self.assertTrue(all(client is shared for client in clients))
        factory.assert_called_once_with(
            'redis://127.0.0.1:6379/0',
            socket_connect_timeout=1,
            socket_timeout=1,
            decode_responses=False,
        )

    @patch('apps.core.rate_limit.redis.Redis.from_url')
    def test_different_urls_use_different_pools_and_reset_closes_registry(self, factory):
        first = Mock()
        second = Mock()
        factory.side_effect = [first, second]

        self.assertIs(
            get_process_redis_client('redis://127.0.0.1:6379/0'),
            first,
        )
        self.assertIs(
            get_process_redis_client('redis://127.0.0.1:6379/1'),
            second,
        )
        reset_process_redis_clients()

        self.assertEqual(factory.call_count, 2)
        first.close.assert_called_once_with()
        second.close.assert_called_once_with()

    def test_injected_client_is_not_added_to_or_closed_by_process_registry(self):
        injected = Mock()
        self.assertIs(RedisRateLimiter(client=injected)._redis_client(), injected)

        reset_process_redis_clients()

        injected.close.assert_not_called()
