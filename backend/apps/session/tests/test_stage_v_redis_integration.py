import os
import re
import time
import uuid
from unittest import skipUnless

import redis
from django.conf import settings
from django.test import override_settings
from rest_framework.test import APITestCase

from apps.core.rate_limit import RedisRateLimiter, TOKEN_UNITS, limit_per_second
from apps.core.websocket_limits import (
    LEASE_KEY_TTL_MS,
    LEASE_REFRESH_SECONDS,
    LEASE_TTL_MS,
    RedisWebSocketGuard,
)
from apps.session.models import AnswerAttempt
from apps.session.tests.helpers import game, teacher, url


@skipUnless(os.getenv('UMCLICK_RUN_REDIS_INTEGRATION') == 'true', 'Redis-контур не запрошен.')
@override_settings(RATE_LIMITS_ENABLED=True)
class StageVRedisIntegrationTests(APITestCase):
    def setUp(self):
        super().setUp()
        if not re.fullmatch(r'umclick:test:[0-9a-f-]{36}', settings.RATE_LIMIT_NAMESPACE):
            self.fail('Интеграционная проверка требует уникального пространства umclick:test:<UUID>.')
        self.redis = redis.Redis.from_url(
            settings.RATE_LIMIT_REDIS_URL,
            socket_connect_timeout=1,
            socket_timeout=1,
            decode_responses=False,
        )
        self.owner = teacher()
        self.game = game(self.owner, active=True)
        self.answer_limit = limit_per_second(
            'answer',
            f'participant:{self.game.link.pk}',
            10,
            40,
        )
        self.answer_key = RedisRateLimiter._key(self.answer_limit)
        self.owned_keys = {self.answer_key}

    def tearDown(self):
        try:
            if self.owned_keys:
                self.redis.delete(*self.owned_keys)
        finally:
            self.redis.close()
            super().tearDown()

    def redis_time_ms(self):
        seconds, microseconds = self.redis.time()
        return seconds * 1_000 + microseconds // 1_000

    def answer(self):
        return self.client.post(
            url(self.game.session, 'answer'),
            {
                'question_id': self.game.question.pk,
                'choice_id': self.game.correct.pk,
                'submission_id': str(uuid.uuid4()),
            },
            format='json',
        )

    def test_pr_32_has_deterministic_40_41_boundary_and_refill(self):
        future_last_ms = self.redis_time_ms() + 60_000
        self.redis.hset(
            self.answer_key,
            mapping={
                'tokens': 40 * TOKEN_UNITS,
                'last_ms': future_last_ms,
            },
        )
        self.redis.pexpire(self.answer_key, self.answer_limit.ttl_ms)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + self.game.secret)

        statuses = [self.answer().status_code for _ in range(40)]
        limited = self.answer()

        self.assertEqual(statuses, [200] * 40)
        self.assertEqual(limited.status_code, 429)
        self.assertEqual(limited.data['code'], 'rate_limited')
        self.assertGreaterEqual(int(limited['Retry-After']), 1)
        self.assertLess(self.redis_time_ms(), future_last_ms)
        self.assertGreaterEqual(
            int(self.redis.hget(self.answer_key, 'last_ms')),
            future_last_ms,
        )
        attempts_count = AnswerAttempt.objects.filter(
            run=self.game.session.current_run,
            session_participant=self.game.link,
        ).count()
        self.assertLessEqual(
            attempts_count,
            20,
        )

        refill_started_ms = self.redis_time_ms()
        self.redis.hset(
            self.answer_key,
            mapping={'tokens': 0, 'last_ms': refill_started_ms},
        )
        self.redis.pexpire(self.answer_key, self.answer_limit.ttl_ms)
        deadline = time.monotonic() + 2
        while self.redis_time_ms() - refill_started_ms < 100:
            if time.monotonic() >= deadline:
                self.fail('Redis TIME не продвинулось на 100 мс за две секунды.')
            time.sleep(0.01)

        restored = self.answer()

        self.assertEqual(restored.status_code, 200)
        print(
            'PR32_EVIDENCE '
            f'successful_requests={statuses.count(200)} '
            f'limited_status={limited.status_code} '
            f'attempt_rows={attempts_count} '
            f'restored_status={restored.status_code}'
        )

    def test_websocket_limits_leases_heartbeat_and_release(self):
        guard = RedisWebSocketGuard(client=self.redis)
        self.assertEqual((LEASE_REFRESH_SECONDS, LEASE_TTL_MS), (15, 45_000))

        rate_address = '203.0.113.100'
        rate_keys = guard.open_keys(rate_address)
        self.owned_keys.update(rate_keys)
        future_last_ms = self.redis_time_ms() + 60_000
        self.redis.hset(
            rate_keys[0],
            mapping={'tokens': 60 * TOKEN_UNITS, 'last_ms': future_last_ms},
        )
        rate_leases = [f'rate-{index}' for index in range(60)]
        rate_results = [guard.open(rate_address, lease) for lease in rate_leases]
        rate_limited = guard.open(rate_address, 'rate-61')
        self.assertTrue(all(result.allowed for result in rate_results))
        self.assertEqual(rate_limited.reason, 'rate_limited')
        self.assertEqual(self.redis.zcard(rate_keys[1]), 60)
        self.assertGreater(self.redis.pttl(rate_keys[1]), 0)
        self.assertLessEqual(self.redis.pttl(rate_keys[1]), LEASE_KEY_TTL_MS)
        for lease in rate_leases:
            guard.release(rate_address, None, lease)

        message_lease = 'message-lease'
        message_limit = limit_per_second('ws_message', message_lease, 5, 20)
        message_key = RedisRateLimiter._key(message_limit)
        self.owned_keys.add(message_key)
        self.redis.hset(
            message_key,
            mapping={'tokens': 20 * TOKEN_UNITS, 'last_ms': future_last_ms},
        )
        message_results = [guard.check_message(message_lease) for _ in range(20)]
        message_limited = guard.check_message(message_lease)
        self.assertTrue(all(result.allowed for result in message_results))
        self.assertFalse(message_limited.allowed)

        access_address = '203.0.113.101'
        access_subject = 'participant:integration-record'
        access_keys = guard.access_keys(access_address, access_subject)
        self.owned_keys.update(guard.open_keys(access_address))
        self.owned_keys.update(access_keys)
        access_leases = [f'access-{index}' for index in range(4)]
        self.assertTrue(all(guard.open(access_address, lease).allowed for lease in access_leases))
        access_results = [
            guard.acquire_access(access_address, access_subject, lease)
            for lease in access_leases
        ]
        self.assertTrue(all(result.allowed for result in access_results[:3]))
        self.assertEqual(access_results[3].reason, 'connection_limit')
        for lease in access_leases:
            guard.release(access_address, access_subject, lease)

        heartbeat_address = '203.0.113.102'
        heartbeat_subject = 'display:integration-record'
        heartbeat_lease = 'heartbeat-lease'
        heartbeat_keys = guard.access_keys(heartbeat_address, heartbeat_subject)
        self.owned_keys.update(guard.open_keys(heartbeat_address))
        self.owned_keys.update(heartbeat_keys)
        self.assertTrue(guard.open(heartbeat_address, heartbeat_lease).allowed)
        self.assertTrue(
            guard.acquire_access(
                heartbeat_address,
                heartbeat_subject,
                heartbeat_lease,
            ).allowed
        )
        score_before = int(self.redis.zscore(heartbeat_keys[2], heartbeat_lease))
        self.assertTrue(
            guard.heartbeat(
                heartbeat_address,
                heartbeat_subject,
                heartbeat_lease,
            ).allowed
        )
        score_after = int(self.redis.zscore(heartbeat_keys[2], heartbeat_lease))
        self.assertGreaterEqual(score_after, score_before)
        guard.release(heartbeat_address, heartbeat_subject, heartbeat_lease)
        self.assertIsNone(self.redis.zscore(heartbeat_keys[2], heartbeat_lease))

        now_ms = self.redis_time_ms()
        ip_address = '203.0.113.103'
        ip_keys = guard.open_keys(ip_address)
        self.owned_keys.update(ip_keys)
        self.redis.hset(
            ip_keys[0],
            mapping={'tokens': TOKEN_UNITS, 'last_ms': future_last_ms},
        )
        self.redis.zadd(
            ip_keys[1],
            {f'ip-{index}': now_ms + LEASE_TTL_MS for index in range(120)},
        )
        self.redis.pexpire(ip_keys[1], LEASE_KEY_TTL_MS)
        self.assertEqual(guard.open(ip_address, 'ip-121').reason, 'connection_limit')

        stage_address = '203.0.113.104'
        stage_keys = guard.open_keys(stage_address)
        self.owned_keys.update(stage_keys)
        self.redis.hset(
            stage_keys[0],
            mapping={'tokens': TOKEN_UNITS, 'last_ms': future_last_ms},
        )
        self.redis.zadd(
            stage_keys[2],
            {f'stage-{index}': now_ms + LEASE_TTL_MS for index in range(240)},
        )
        self.redis.pexpire(stage_keys[2], LEASE_KEY_TTL_MS)
        self.assertEqual(guard.open(stage_address, 'stage-241').reason, 'connection_limit')

        print(
            'WS_REDIS_EVIDENCE '
            'open=60/61 messages=20/21 access=3/4 ip=120/121 stage=240/241 '
            f'lease_ttl_ms={LEASE_TTL_MS} heartbeat_seconds={LEASE_REFRESH_SECONDS}'
        )
