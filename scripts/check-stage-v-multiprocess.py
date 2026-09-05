"""Два локальных Daphne-процесса с общей тестовой PostgreSQL и Redis."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from urllib.error import HTTPError
from urllib.request import Request, urlopen


REPO_ROOT = Path(__file__).resolve().parents[1]
BACKEND_DIR = REPO_ROOT / "backend"
SITE_PACKAGES = BACKEND_DIR / ".venv" / "Lib" / "site-packages"
REQUIRED_DATABASE_KEYS = (
    "UMCLICK_TEST_DB_HOST",
    "UMCLICK_TEST_DB_PORT",
    "UMCLICK_TEST_DB_USER",
    "UMCLICK_TEST_DB_PASSWORD",
    "UMCLICK_TEST_DB_NAME",
)


def bootstrap_project() -> None:
    runtime_site_packages = os.path.normcase(
        os.path.normpath(os.path.join(sys.base_prefix, "Lib", "site-packages"))
    )
    sys.path[:] = [
        path
        for path in sys.path
        if os.path.normcase(os.path.normpath(path)) != runtime_site_packages
    ]
    sys.path.insert(0, str(BACKEND_DIR))
    sys.path.insert(0, str(SITE_PACKAGES))


def load_test_environment() -> None:
    environment_path = REPO_ROOT / ".env.test.local"
    if not environment_path.is_file():
        raise RuntimeError("Не найден .env.test.local.")
    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(
        environment_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise RuntimeError(
                f"Некорректная строка {line_number} в .env.test.local."
            )
        key, value = (part.strip() for part in line.split("=", 1))
        if key not in REQUIRED_DATABASE_KEYS:
            raise RuntimeError(f"Недопустимый ключ {key} в .env.test.local.")
        if not value or key in values:
            raise RuntimeError(f"Некорректное значение ключа {key}.")
        values[key] = value
    missing = [key for key in REQUIRED_DATABASE_KEYS if key not in values]
    if missing:
        raise RuntimeError(
            "В .env.test.local отсутствуют обязательные переменные: "
            + ", ".join(missing)
        )
    os.environ.update(values)


def configure_stage_v_environment(namespace: str) -> None:
    os.environ.update(
        {
            "DJANGO_SETTINGS_MODULE": "umclick.test_settings",
            "UMCLICK_STAGE_V_REDIS_URL": "redis://127.0.0.1:6379/0",
            "UMCLICK_STAGE_V_REDIS_NAMESPACE": namespace,
            "PYTHONUTF8": "1",
            "PYTHONIOENCODING": "utf-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
        }
    )


def verify_database(expected_database: str) -> str:
    import django

    django.setup()
    from django.db import connection

    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT current_database(), current_user")
            actual_database, actual_user = cursor.fetchone()
    finally:
        connection.close()
    if actual_database != expected_database:
        raise RuntimeError(
            "Процесс подключён не к ожидаемой выделенной тестовой базе."
        )
    if actual_user != os.environ["UMCLICK_TEST_DB_USER"]:
        raise RuntimeError("Процесс подключён не от имени тестовой роли.")
    return actual_database


def serve(port: int) -> None:
    expected_database = os.environ["UMCLICK_TEST_DB_NAME"]
    actual_database = verify_database(expected_database)
    from django.conf import settings

    backend = settings.CHANNEL_LAYERS["default"]["BACKEND"]
    if backend != "channels_redis.core.RedisChannelLayer":
        raise RuntimeError("Двухпроцессная проверка не допускает InMemoryChannelLayer.")
    print(
        f"DAPHNE_CHILD_READY port={port} database={actual_database} "
        f"settings={os.environ['DJANGO_SETTINGS_MODULE']} channel_backend={backend}",
        flush=True,
    )
    from daphne.cli import CommandLineInterface

    CommandLineInterface().run(
        ["-b", "127.0.0.1", "-p", str(port), "umclick.asgi:application"]
    )


def reserve_ports(count: int) -> list[int]:
    holders = []
    try:
        for _ in range(count):
            holder = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            holder.bind(("127.0.0.1", 0))
            holder.listen(1)
            holders.append(holder)
        return [holder.getsockname()[1] for holder in holders]
    finally:
        for holder in holders:
            holder.close()


def collect_output(process: subprocess.Popen[str], lines: list[str]) -> None:
    assert process.stdout is not None
    for line in process.stdout:
        lines.append(line.rstrip())


def wait_for_port(process: subprocess.Popen[str], port: int, lines: list[str]) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                f"Daphne на порту {port} завершился раньше времени: "
                + " | ".join(lines[-8:])
            )
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"Daphne на порту {port} не стал доступен за 10 секунд.")


def http_post_json(port: int, path: str, payload: dict) -> tuple[int, dict]:
    request = Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=3) as response:
            return response.status, json.loads(response.read())
    except HTTPError as error:
        return error.code, json.loads(error.read())


class RawWebSocket:
    def __init__(self, port: int, path: str):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.buffer = b""
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.socket.sendall(request.encode("ascii"))
        response = self._receive_until(b"\r\n\r\n")
        headers, self.buffer = response.split(b"\r\n\r\n", 1)
        if not headers.startswith(b"HTTP/1.1 101"):
            raise RuntimeError(
                "WebSocket handshake не принят: "
                + headers.split(b"\r\n", 1)[0].decode("ascii", errors="replace")
            )

    def _receive_until(self, marker: bytes) -> bytes:
        data = self.buffer
        while marker not in data:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise RuntimeError("Соединение закрыто во время WebSocket handshake.")
            data += chunk
        return data

    def _read_exact(self, size: int) -> bytes:
        while len(self.buffer) < size:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise RuntimeError("WebSocket закрыт до полного кадра.")
            self.buffer += chunk
        result, self.buffer = self.buffer[:size], self.buffer[size:]
        return result

    def receive_frame(self, timeout: float = 3) -> tuple[int, bytes]:
        self.socket.settimeout(timeout)
        first, second = self._read_exact(2)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._read_exact(8))[0]
        return first & 0x0F, self._read_exact(length)

    def send_close(self) -> None:
        payload = struct.pack("!H", 1000)
        mask = os.urandom(4)
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self.socket.sendall(bytes([0x88, 0x80 | len(payload)]) + mask + masked)

    def close(self) -> None:
        self.socket.close()


def wait_for_cardinality(client, key: str, expected: int) -> None:
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if client.zcard(key) == expected:
            return
        time.sleep(0.02)
    raise RuntimeError(
        f"Redis-аренда {key.rsplit(':', 1)[0]} не достигла ожидаемого размера {expected}."
    )


def terminate_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def verify_ports_released(ports: list[int]) -> None:
    probes = []
    try:
        for port in ports:
            probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            probe.bind(("127.0.0.1", port))
            probes.append(probe)
    finally:
        for probe in probes:
            probe.close()


def run_check(*, fail_after_first: bool = False) -> None:
    load_test_environment()
    namespace = f"umclick:test:{uuid.uuid4()}"
    configure_stage_v_environment(namespace)

    import redis

    redis_client = redis.Redis.from_url(
        os.environ["UMCLICK_STAGE_V_REDIS_URL"],
        socket_connect_timeout=1,
        socket_timeout=1,
        decode_responses=False,
    )
    try:
        pong = redis_client.ping()
    except Exception as error:
        raise RuntimeError(
            f"Redis PING не получил PONG: {type(error).__name__}: {error}"
        ) from error
    if pong is not True:
        raise RuntimeError(f"Redis PING не получил PONG: ответ {pong!r}.")

    expected_database = os.environ["UMCLICK_TEST_DB_NAME"]
    actual_database = verify_database(expected_database)
    from django.conf import settings
    from apps.core.rate_limit import RedisRateLimiter, TOKEN_UNITS, limit_per_minute
    from apps.core.request_identity import normalize_login
    from apps.core.websocket_limits import LEASE_KEY_TTL_MS, LEASE_TTL_MS, RedisWebSocketGuard

    if not namespace.startswith("umclick:test:"):
        raise RuntimeError("Небезопасное пространство Redis.")
    if settings.CHANNEL_LAYERS["default"]["BACKEND"] != "channels_redis.core.RedisChannelLayer":
        raise RuntimeError("Настройки не подключили Redis channel layer.")

    processes: list[subprocess.Popen[str]] = []
    readers: list[threading.Thread] = []
    outputs: list[list[str]] = []
    sockets: list[RawWebSocket] = []
    ports = reserve_ports(2)
    try:
        for port in ports:
            lines: list[str] = []
            process = subprocess.Popen(
                [sys.executable, "-B", "-X", "utf8", str(Path(__file__).resolve()), "--serve", str(port)],
                cwd=BACKEND_DIR,
                env=os.environ.copy(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
            )
            processes.append(process)
            outputs.append(lines)
            reader = threading.Thread(
                target=collect_output,
                args=(process, lines),
                daemon=True,
            )
            reader.start()
            readers.append(reader)
            wait_for_port(process, port, lines)
            if fail_after_first and len(processes) == 1:
                raise RuntimeError("Контролируемая ошибка после запуска первого Daphne.")

        for port, lines in zip(ports, outputs):
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and not any(
                line.startswith("DAPHNE_CHILD_READY") for line in lines
            ):
                time.sleep(0.02)
            ready = next(
                (line for line in lines if line.startswith("DAPHNE_CHILD_READY")),
                None,
            )
            if ready is None:
                raise RuntimeError(f"Daphne {port} не подтвердил тестовую базу.")
            print(ready)

        login = f"stage-v-{uuid.uuid4()}"
        login_limit = limit_per_minute("login_name", normalize_login(login), 10, 10)
        login_key = RedisRateLimiter._key(login_limit)
        redis_seconds, redis_microseconds = redis_client.time()
        now_ms = redis_seconds * 1000 + redis_microseconds // 1000
        future_last_ms = now_ms + 60_000
        redis_client.hset(
            login_key,
            mapping={"tokens": 2 * TOKEN_UNITS, "last_ms": future_last_ms},
        )
        redis_client.pexpire(login_key, login_limit.ttl_ms)
        credentials = {"username": login, "password": "synthetic-invalid-password"}
        first_status, _ = http_post_json(ports[0], "/api/auth/token/", credentials)
        second_status, _ = http_post_json(ports[1], "/api/auth/token/", credentials)
        third_status, third_body = http_post_json(
            ports[0], "/api/auth/token/", credentials
        )
        if (first_status, second_status, third_status) != (401, 401, 429):
            raise RuntimeError(
                "Общий HTTP-лимит не подтверждён: "
                f"{first_status}/{second_status}/{third_status}."
            )
        if third_body.get("code") != "rate_limited":
            raise RuntimeError("HTTP 429 не содержит code=rate_limited.")

        guard = RedisWebSocketGuard(client=redis_client)
        address = "127.0.0.1"
        open_key, ip_lease_key, _ = guard.open_keys(address)
        redis_client.hset(
            open_key,
            mapping={"tokens": 10 * TOKEN_UNITS, "last_ms": future_last_ms},
        )
        redis_client.pexpire(open_key, 120_000)
        redis_client.zadd(
            ip_lease_key,
            {
                f"seed-{index}": now_ms + LEASE_TTL_MS
                for index in range(119)
            },
        )
        redis_client.pexpire(ip_lease_key, LEASE_KEY_TTL_MS)
        path = f"/ws/sessions/{uuid.uuid4()}/"

        held = RawWebSocket(ports[0], path)
        sockets.append(held)
        wait_for_cardinality(redis_client, ip_lease_key, 120)

        rejected = RawWebSocket(ports[1], path)
        sockets.append(rejected)
        opcode, payload = rejected.receive_frame()
        if opcode != 1:
            raise RuntimeError("Ожидалось текстовое сообщение WebSocket-ошибки.")
        error_body = json.loads(payload.decode("utf-8"))
        close_opcode, close_payload = rejected.receive_frame()
        close_code = (
            struct.unpack("!H", close_payload[:2])[0]
            if close_opcode == 8 and len(close_payload) >= 2
            else None
        )
        if error_body.get("code") != "connection_limit" or close_code != 4429:
            raise RuntimeError(
                "Общий предел аренды не подтверждён: "
                f"reason={error_body.get('code')} close={close_code}."
            )
        rejected.close()
        sockets.remove(rejected)

        held.send_close()
        held.close()
        sockets.remove(held)
        wait_for_cardinality(redis_client, ip_lease_key, 119)

        restored = RawWebSocket(ports[1], path)
        sockets.append(restored)
        wait_for_cardinality(redis_client, ip_lease_key, 120)
        restored.send_close()
        restored.close()
        sockets.remove(restored)
        wait_for_cardinality(redis_client, ip_lease_key, 119)

        print(
            "MULTIPROCESS_EVIDENCE "
            f"settings=umclick.test_settings database={actual_database} "
            f"namespace={namespace} "
            f"ports={ports[0]},{ports[1]} http=401/401/429 "
            "ws=120/121 release=119 restored=120 channel=redis"
        )
    finally:
        for connection in sockets:
            connection.close()
        for process in processes:
            terminate_process(process)
        for reader in readers:
            reader.join(timeout=2)
        verify_ports_released(ports)
        owned_keys = list(redis_client.scan_iter(match=f"{namespace}:*"))
        if owned_keys:
            redis_client.delete(*owned_keys)
        remaining = list(redis_client.scan_iter(match=f"{namespace}:*"))
        print(
            f"CLEANUP_EVIDENCE namespace={namespace} "
            f"owned_keys={len(remaining)} ports_released={len(ports)}"
        )
        redis_client.close()
        if remaining:
            raise RuntimeError("Не удалось удалить собственные тестовые ключи Redis.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", type=int)
    parser.add_argument("--fail-after-first", action="store_true")
    arguments = parser.parse_args()
    bootstrap_project()
    if arguments.serve is not None:
        serve(arguments.serve)
        return
    run_check(fail_after_first=arguments.fail_after_first)


if __name__ == "__main__":
    main()
