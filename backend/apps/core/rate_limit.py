import hashlib
import hmac
import math
import threading
from dataclasses import dataclass

import redis
from django.conf import settings
from redis.exceptions import RedisError


TOKEN_UNITS = 60_000
_REDIS_CLIENT_OPTIONS = {
    'socket_connect_timeout': 1,
    'socket_timeout': 1,
    'decode_responses': False,
}
_PROCESS_REDIS_CLIENTS = {}
_PROCESS_REDIS_CLIENTS_LOCK = threading.Lock()


LUA_TOKEN_BUCKET = r"""
local token_cost = tonumber(ARGV[1])
local time = redis.call('TIME')
local now_ms = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)
local states = {}
local allowed = 1
local retry_ms = 0

for i = 1, #KEYS do
    local offset = 2 + (i - 1) * 3
    local capacity = tonumber(ARGV[offset])
    local refill_per_ms = tonumber(ARGV[offset + 1])
    local ttl_ms = tonumber(ARGV[offset + 2])
    local stored = redis.call('HMGET', KEYS[i], 'tokens', 'last_ms')
    local tokens = tonumber(stored[1]) or capacity
    local stored_last_ms = tonumber(stored[2]) or now_ms
    local elapsed_ms = math.max(0, now_ms - stored_last_ms)

    tokens = math.min(capacity, tokens + elapsed_ms * refill_per_ms)
    states[i] = {
        tokens = tokens,
        last_ms = math.max(stored_last_ms, now_ms),
        ttl_ms = ttl_ms,
        refill_per_ms = refill_per_ms,
        future_wait_ms = math.max(0, stored_last_ms - now_ms)
    }

    if tokens < token_cost then
        allowed = 0
        local deficit = token_cost - tokens
        local bucket_retry_ms = states[i].future_wait_ms + math.ceil(deficit / refill_per_ms)
        retry_ms = math.max(retry_ms, bucket_retry_ms)
    end
end

for i = 1, #KEYS do
    local state = states[i]
    if allowed == 1 then
        state.tokens = state.tokens - token_cost
    end
    redis.call('HSET', KEYS[i], 'tokens', state.tokens, 'last_ms', state.last_ms)
    redis.call('PEXPIRE', KEYS[i], state.ttl_ms)
end

return {allowed, retry_ms, now_ms}
"""


class LimiterUnavailable(RuntimeError):
    """Общее хранилище квот не может надёжно принять решение."""


def get_process_redis_client(redis_url: str):
    """Вернуть один Redis-клиент и пул на URL в пределах текущего процесса."""
    client = _PROCESS_REDIS_CLIENTS.get(redis_url)
    if client is not None:
        return client
    with _PROCESS_REDIS_CLIENTS_LOCK:
        client = _PROCESS_REDIS_CLIENTS.get(redis_url)
        if client is None:
            client = redis.Redis.from_url(redis_url, **_REDIS_CLIENT_OPTIONS)
            _PROCESS_REDIS_CLIENTS[redis_url] = client
        return client


def reset_process_redis_clients():
    """Закрыть и забыть только клиенты реестра текущего процесса."""
    with _PROCESS_REDIS_CLIENTS_LOCK:
        clients = list(_PROCESS_REDIS_CLIENTS.values())
        _PROCESS_REDIS_CLIENTS.clear()
    for client in clients:
        client.close()


@dataclass(frozen=True)
class BucketLimit:
    operation: str
    subject: str
    refill_units_per_ms: int
    capacity_operations: int

    @property
    def capacity_units(self) -> int:
        return self.capacity_operations * TOKEN_UNITS

    @property
    def ttl_ms(self) -> int:
        restoration_ms = math.ceil(self.capacity_units / self.refill_units_per_ms)
        return max(120_000, restoration_ms * 2)


@dataclass(frozen=True)
class LimitDecision:
    allowed: bool
    retry_after: int | None = None


def limit_per_minute(
    operation: str,
    subject: str,
    requests: int,
    burst: int,
) -> BucketLimit:
    refill_numerator = requests * TOKEN_UNITS
    if refill_numerator % 60_000:
        raise ValueError('Скорость должна точно представляться целым числом единиц в миллисекунду.')
    return BucketLimit(operation, subject, refill_numerator // 60_000, burst)


def limit_per_second(
    operation: str,
    subject: str,
    requests: int,
    burst: int,
) -> BucketLimit:
    refill_numerator = requests * TOKEN_UNITS
    if refill_numerator % 1_000:
        raise ValueError('Скорость должна точно представляться целым числом единиц в миллисекунду.')
    return BucketLimit(operation, subject, refill_numerator // 1_000, burst)


class RedisRateLimiter:
    def __init__(self, client=None):
        self._client = client

    def _redis_client(self):
        if self._client is not None:
            return self._client
        redis_url = getattr(settings, 'RATE_LIMIT_REDIS_URL', '') or getattr(settings, 'REDIS_URL', '')
        if not redis_url:
            raise LimiterUnavailable('Хранилище общих квот не настроено.')
        try:
            self._client = get_process_redis_client(redis_url)
        except (RedisError, ValueError) as exc:
            raise LimiterUnavailable('Хранилище общих квот недоступно.') from exc
        return self._client

    @staticmethod
    def _key(limit: BucketLimit) -> str:
        namespace = getattr(settings, 'RATE_LIMIT_NAMESPACE', 'umclick:limit:v1').rstrip(':')
        secret = str(getattr(settings, 'RATE_LIMIT_HMAC_SECRET', settings.SECRET_KEY)).encode()
        subject = f'{limit.operation}\0{limit.subject}'.encode()
        digest = hmac.new(secret, subject, hashlib.sha256).hexdigest()
        return f'{namespace}:{limit.operation}:{digest}'

    def check(self, limits: list[BucketLimit]) -> LimitDecision:
        if not limits:
            return LimitDecision(allowed=True)

        keys = [self._key(limit) for limit in limits]
        arguments: list[int] = [TOKEN_UNITS]
        for limit in limits:
            arguments.extend(
                [
                    limit.capacity_units,
                    limit.refill_units_per_ms,
                    limit.ttl_ms,
                ]
            )

        try:
            result = self._redis_client().eval(
                LUA_TOKEN_BUCKET,
                len(keys),
                *keys,
                *arguments,
            )
        except (RedisError, OSError, ValueError) as exc:
            raise LimiterUnavailable('Хранилище общих квот недоступно.') from exc

        allowed = bool(int(result[0]))
        retry_ms = max(0, int(result[1]))
        return LimitDecision(
            allowed=allowed,
            retry_after=None if allowed else max(1, math.ceil(retry_ms / 1_000)),
        )


def enforce_rate_limits(limits: list[BucketLimit]) -> None:
    if not getattr(settings, 'RATE_LIMITS_ENABLED', True):
        return

    from apps.core.errors import LimiterServiceUnavailable, RateLimitExceeded

    try:
        decision = RedisRateLimiter().check(limits)
    except LimiterUnavailable as exc:
        raise LimiterServiceUnavailable() from exc
    if not decision.allowed:
        raise RateLimitExceeded(decision.retry_after or 1)
