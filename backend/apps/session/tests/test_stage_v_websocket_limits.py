from django.test import SimpleTestCase, override_settings
from redis.exceptions import ConnectionError as RedisConnectionError

from apps.core.rate_limit import LimiterUnavailable
from apps.core.websocket_limits import (
    LUA_WS_ACCESS,
    LUA_WS_HEARTBEAT,
    LUA_WS_OPEN,
    RedisWebSocketGuard,
)


class RecordingRedis:
    def __init__(self, results=None, error=None):
        self.results = list(results or [])
        self.error = error
        self.calls = []

    def eval(self, *arguments):
        self.calls.append(arguments)
        if self.error:
            raise self.error
        return self.results.pop(0)


class WebSocketLuaContractTests(SimpleTestCase):
    def test_all_lease_scripts_use_redis_time_and_atomic_key_sets(self):
        self.assertIn("redis.call('TIME')", LUA_WS_OPEN)
        self.assertIn("redis.call('TIME')", LUA_WS_ACCESS)
        self.assertIn("redis.call('TIME')", LUA_WS_HEARTBEAT)
        self.assertIn("redis.call('ZREMRANGEBYSCORE'", LUA_WS_OPEN)
        self.assertIn("redis.call('ZREMRANGEBYSCORE'", LUA_WS_ACCESS)
        self.assertIn("redis.call('ZREMRANGEBYSCORE'", LUA_WS_HEARTBEAT)


@override_settings(
    WS_LIMIT_NAMESPACE='umclick:test:unit',
    WS_LIMIT_HMAC_SECRET='test-only-secret',
)
class RedisWebSocketGuardTests(SimpleTestCase):
    def test_open_checks_bucket_ip_and_stage_in_one_eval_without_raw_ip(self):
        client = RecordingRedis(results=[[1, 0, 1_000]])
        guard = RedisWebSocketGuard(client=client)

        result = guard.open('203.0.113.50', 'lease-1')

        self.assertTrue(result.allowed)
        self.assertEqual(len(client.calls), 1)
        call = client.calls[0]
        self.assertEqual(call[1], 3)
        self.assertNotIn('203.0.113.50', str(call[2:5]))

    def test_access_limit_is_one_atomic_eval_without_raw_access(self):
        client = RecordingRedis(results=[[1, 0, 1_000]])
        guard = RedisWebSocketGuard(client=client)

        result = guard.acquire_access(
            '203.0.113.50',
            'participant:secret-record',
            'lease-1',
        )

        self.assertTrue(result.allowed)
        self.assertEqual(len(client.calls), 1)
        call = client.calls[0]
        self.assertEqual(call[1], 3)
        self.assertNotIn('203.0.113.50', str(call[2:5]))
        self.assertNotIn('secret-record', str(call[2:5]))

    def test_decisions_preserve_reason_and_round_retry_up(self):
        client = RecordingRedis(results=[[0, 1, 1_001], [0, 2, 2_001]])
        guard = RedisWebSocketGuard(client=client)

        rate = guard.open('203.0.113.50', 'lease-1')
        capacity = guard.acquire_access('203.0.113.50', 'participant:1', 'lease-1')

        self.assertEqual((rate.reason, rate.retry_after), ('rate_limited', 2))
        self.assertEqual((capacity.reason, capacity.retry_after), ('connection_limit', 3))

    def test_redis_failure_is_fail_closed(self):
        guard = RedisWebSocketGuard(
            client=RecordingRedis(error=RedisConnectionError('test failure'))
        )

        with self.assertRaises(LimiterUnavailable):
            guard.open('203.0.113.50', 'lease-1')
