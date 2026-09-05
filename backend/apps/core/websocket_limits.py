import hashlib
import hmac
import math
from dataclasses import dataclass

from django.conf import settings
from redis.exceptions import RedisError

from apps.core.rate_limit import (
    TOKEN_UNITS,
    LimiterUnavailable,
    RedisRateLimiter,
    get_process_redis_client,
    limit_per_second,
)


LEASE_REFRESH_SECONDS = 15
LEASE_TTL_MS = 45_000
LEASE_KEY_TTL_MS = 90_000


LUA_WS_OPEN = r"""
local token_cost = tonumber(ARGV[1])
local capacity = tonumber(ARGV[2])
local refill_per_ms = tonumber(ARGV[3])
local bucket_ttl_ms = tonumber(ARGV[4])
local lease_id = ARGV[5]
local lease_ttl_ms = tonumber(ARGV[6])
local lease_key_ttl_ms = tonumber(ARGV[7])
local ip_limit = tonumber(ARGV[8])
local stage_limit = tonumber(ARGV[9])
local time = redis.call('TIME')
local now_ms = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)

redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', now_ms)
redis.call('ZREMRANGEBYSCORE', KEYS[3], '-inf', now_ms)

local stored = redis.call('HMGET', KEYS[1], 'tokens', 'last_ms')
local tokens = tonumber(stored[1]) or capacity
local stored_last_ms = tonumber(stored[2]) or now_ms
local elapsed_ms = math.max(0, now_ms - stored_last_ms)
tokens = math.min(capacity, tokens + elapsed_ms * refill_per_ms)
local new_last_ms = math.max(stored_last_ms, now_ms)
local allowed = 1
local reason = 0
local retry_ms = 0

if tokens < token_cost then
    allowed = 0
    reason = 1
    retry_ms = math.max(0, stored_last_ms - now_ms)
        + math.ceil((token_cost - tokens) / refill_per_ms)
end

local function capacity_retry(key)
    local earliest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    if #earliest < 2 then
        return 1
    end
    return math.max(1, tonumber(earliest[2]) - now_ms)
end

if redis.call('ZCARD', KEYS[2]) >= ip_limit then
    allowed = 0
    if reason == 0 then reason = 2 end
    retry_ms = math.max(retry_ms, capacity_retry(KEYS[2]))
end
if redis.call('ZCARD', KEYS[3]) >= stage_limit then
    allowed = 0
    if reason == 0 then reason = 2 end
    retry_ms = math.max(retry_ms, capacity_retry(KEYS[3]))
end

if allowed == 1 then
    tokens = tokens - token_cost
end
redis.call('HSET', KEYS[1], 'tokens', tokens, 'last_ms', new_last_ms)
redis.call('PEXPIRE', KEYS[1], bucket_ttl_ms)

if allowed == 1 then
    local expires_ms = now_ms + lease_ttl_ms
    redis.call('ZADD', KEYS[2], expires_ms, lease_id)
    redis.call('ZADD', KEYS[3], expires_ms, lease_id)
    redis.call('PEXPIRE', KEYS[2], lease_key_ttl_ms)
    redis.call('PEXPIRE', KEYS[3], lease_key_ttl_ms)
end

return {allowed, reason, retry_ms}
"""


LUA_WS_ACCESS = r"""
local lease_id = ARGV[1]
local lease_ttl_ms = tonumber(ARGV[2])
local lease_key_ttl_ms = tonumber(ARGV[3])
local access_limit = tonumber(ARGV[4])
local time = redis.call('TIME')
local now_ms = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)

for i = 1, #KEYS do
    redis.call('ZREMRANGEBYSCORE', KEYS[i], '-inf', now_ms)
end
if not redis.call('ZSCORE', KEYS[1], lease_id)
    or not redis.call('ZSCORE', KEYS[2], lease_id) then
    return {0, 3, 3000}
end
if redis.call('ZCARD', KEYS[3]) >= access_limit then
    local earliest = redis.call('ZRANGE', KEYS[3], 0, 0, 'WITHSCORES')
    local retry_ms = 1
    if #earliest >= 2 then
        retry_ms = math.max(1, tonumber(earliest[2]) - now_ms)
    end
    return {0, 2, retry_ms}
end

local expires_ms = now_ms + lease_ttl_ms
for i = 1, #KEYS do
    redis.call('ZADD', KEYS[i], expires_ms, lease_id)
    redis.call('PEXPIRE', KEYS[i], lease_key_ttl_ms)
end
return {1, 0, 0}
"""


LUA_WS_HEARTBEAT = r"""
local lease_id = ARGV[1]
local lease_ttl_ms = tonumber(ARGV[2])
local lease_key_ttl_ms = tonumber(ARGV[3])
local time = redis.call('TIME')
local now_ms = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)

for i = 1, #KEYS do
    redis.call('ZREMRANGEBYSCORE', KEYS[i], '-inf', now_ms)
    if not redis.call('ZSCORE', KEYS[i], lease_id) then
        return {0, 3, 3000}
    end
end
local expires_ms = now_ms + lease_ttl_ms
for i = 1, #KEYS do
    redis.call('ZADD', KEYS[i], expires_ms, lease_id)
    redis.call('PEXPIRE', KEYS[i], lease_key_ttl_ms)
end
return {1, 0, 0}
"""


LUA_WS_RELEASE = r"""
local lease_id = ARGV[1]
for i = 1, #KEYS do
    redis.call('ZREM', KEYS[i], lease_id)
end
return 1
"""


@dataclass(frozen=True)
class WebSocketLimitDecision:
    allowed: bool
    reason: str | None = None
    retry_after: int | None = None


class RedisWebSocketGuard:
    def __init__(self, client=None):
        self._client = client

    def _redis_client(self):
        if self._client is not None:
            return self._client
        redis_url = getattr(settings, 'WS_LIMIT_REDIS_URL', '')
        if not redis_url:
            raise LimiterUnavailable('Хранилище WebSocket-квот не настроено.')
        try:
            self._client = get_process_redis_client(redis_url)
        except (RedisError, ValueError) as exc:
            raise LimiterUnavailable('Хранилище WebSocket-квот недоступно.') from exc
        return self._client

    @staticmethod
    def _key(operation: str, subject: str) -> str:
        namespace = getattr(settings, 'WS_LIMIT_NAMESPACE', 'umclick:limit:v1').rstrip(':')
        secret = str(getattr(settings, 'WS_LIMIT_HMAC_SECRET', settings.SECRET_KEY)).encode()
        digest = hmac.new(secret, f'{operation}\0{subject}'.encode(), hashlib.sha256).hexdigest()
        return f'{namespace}:{operation}:{digest}'

    def open_keys(self, address: str):
        return (
            self._key('ws_open', address),
            self._key('ws_lease_ip', address),
            f"{getattr(settings, 'WS_LIMIT_NAMESPACE', 'umclick:limit:v1').rstrip(':')}:ws_lease_stage",
        )

    def access_keys(self, address: str, access_subject: str):
        _, ip_key, stage_key = self.open_keys(address)
        return ip_key, stage_key, self._key('ws_lease_access', access_subject)

    @staticmethod
    def _decision(result) -> WebSocketLimitDecision:
        allowed = bool(int(result[0]))
        if allowed:
            return WebSocketLimitDecision(allowed=True)
        reason = {
            1: 'rate_limited',
            2: 'connection_limit',
            3: 'limiter_unavailable',
        }.get(int(result[1]), 'limiter_unavailable')
        retry_ms = max(1, int(result[2]))
        return WebSocketLimitDecision(
            allowed=False,
            reason=reason,
            retry_after=max(1, math.ceil(retry_ms / 1_000)),
        )

    def _eval(self, script, keys, arguments):
        try:
            return self._redis_client().eval(script, len(keys), *keys, *arguments)
        except (RedisError, OSError, ValueError) as exc:
            raise LimiterUnavailable('Хранилище WebSocket-квот недоступно.') from exc

    def open(self, address: str, lease_id: str) -> WebSocketLimitDecision:
        limit = limit_per_second('ws_open', address, 10, 60)
        result = self._eval(
            LUA_WS_OPEN,
            self.open_keys(address),
            [
                TOKEN_UNITS,
                limit.capacity_units,
                limit.refill_units_per_ms,
                limit.ttl_ms,
                lease_id,
                LEASE_TTL_MS,
                LEASE_KEY_TTL_MS,
                120,
                240,
            ],
        )
        return self._decision(result)

    def acquire_access(
        self,
        address: str,
        access_subject: str,
        lease_id: str,
    ) -> WebSocketLimitDecision:
        result = self._eval(
            LUA_WS_ACCESS,
            self.access_keys(address, access_subject),
            [lease_id, LEASE_TTL_MS, LEASE_KEY_TTL_MS, 3],
        )
        return self._decision(result)

    def heartbeat(self, address: str, access_subject: str, lease_id: str):
        result = self._eval(
            LUA_WS_HEARTBEAT,
            self.access_keys(address, access_subject),
            [lease_id, LEASE_TTL_MS, LEASE_KEY_TTL_MS],
        )
        return self._decision(result)

    def check_message(self, lease_id: str):
        return RedisRateLimiter(client=self._redis_client()).check(
            [limit_per_second('ws_message', lease_id, 5, 20)]
        )

    def release(self, address: str, access_subject: str | None, lease_id: str):
        if access_subject is None:
            _, ip_key, stage_key = self.open_keys(address)
            keys = (ip_key, stage_key)
        else:
            keys = self.access_keys(address, access_subject)
        self._eval(LUA_WS_RELEASE, keys, [lease_id])
