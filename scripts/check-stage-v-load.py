"""Ограниченная loopback-проверка 30 участников этапа В без новых зависимостей."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
from pathlib import Path
import runpy
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
SERVER_SCRIPT = Path(__file__).with_name("check-stage-v-multiprocess.py")
PARTICIPANT_COUNT = 30
ATTEMPTS_PER_PARTICIPANT = 20


def _helpers() -> dict:
    return runpy.run_path(str(SERVER_SCRIPT))


def _request_json(
    port: int,
    method: str,
    path: str,
    *,
    payload: dict | None = None,
    authorization: str | None = None,
) -> tuple[int, dict, float]:
    headers = {"Content-Type": "application/json"}
    if authorization is not None:
        headers["Authorization"] = authorization
    request = Request(
        f"http://127.0.0.1:{port}{path}",
        data=None if payload is None else json.dumps(payload).encode("utf-8"),
        headers=headers,
        method=method,
    )
    started = time.perf_counter()
    try:
        with urlopen(request, timeout=8) as response:
            body = response.read()
            decoded = json.loads(body) if body else {}
            return response.status, decoded, (time.perf_counter() - started) * 1000
    except HTTPError as error:
        body = error.read()
        try:
            decoded = json.loads(body) if body else {}
        except json.JSONDecodeError:
            decoded = {}
        return error.code, decoded, (time.perf_counter() - started) * 1000


def _send_websocket_json(connection, payload: dict) -> None:
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    mask = os.urandom(4)
    if len(data) <= 125:
        header = bytes([0x81, 0x80 | len(data)])
    elif len(data) <= 65_535:
        header = bytes([0x81, 0x80 | 126]) + struct.pack("!H", len(data))
    else:
        header = bytes([0x81, 0x80 | 127]) + struct.pack("!Q", len(data))
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
    connection.socket.sendall(header + mask + masked)


def _open_participant_socket(raw_websocket, port: int, session_uuid: str, token: str):
    started = time.perf_counter()
    connection = raw_websocket(port, f"/ws/sessions/{session_uuid}/")
    try:
        _send_websocket_json(
            connection,
            {"event": "auth", "access_type": "participant", "token": token},
        )
        for _ in range(4):
            opcode, payload = connection.receive_frame(timeout=8)
            if opcode == 1:
                message = json.loads(payload.decode("utf-8"))
                if message.get("event") == "connection_error":
                    raise RuntimeError(
                        f"WebSocket отклонён с причиной {message.get('code', 'unknown')}."
                    )
                if message.get("event") == "session_state":
                    if message.get("schema_version") != 2:
                        raise RuntimeError("WebSocket вернул неверную версию схемы.")
                    return connection, (time.perf_counter() - started) * 1000
            if opcode == 8:
                close_code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None
                raise RuntimeError(f"WebSocket закрыт до состояния: {close_code}.")
        raise RuntimeError("WebSocket не вернул начальное состояние.")
    except Exception:
        connection.close()
        raise


def _latency_summary(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)

    def percentile(value: float) -> float:
        index = max(0, math.ceil(value * len(ordered)) - 1)
        return round(ordered[index], 1)

    return {
        "p50": percentile(0.50),
        "p95": percentile(0.95),
        "p99": percentile(0.99),
        "max": round(ordered[-1], 1),
    }


def _command_payload(state: dict) -> dict:
    return {
        "command_id": str(uuid.uuid4()),
        "state_revision": state["state_revision"],
        "phase": state["phase"],
        "question_run_id": state.get("question_run_id"),
    }


def _assert_statuses(label: str, results: list[tuple[int, dict, float]], expected: int) -> None:
    statuses = [result[0] for result in results]
    if statuses != [expected] * len(results):
        counts = {status: statuses.count(status) for status in sorted(set(statuses))}
        raise RuntimeError(f"{label}: неожиданные HTTP-статусы {counts}.")


def _cleanup_synthetic_database(
    connection,
    session_id: int | None,
    quiz_id: int | None,
    owner_id: int | None,
    created_group_id: int | None,
) -> int:
    """Удалить только граф данных, созданный этим запуском, в одной транзакции."""
    from django.db import transaction

    with transaction.atomic():
        with connection.cursor() as cursor:
            cursor.execute("SET LOCAL lock_timeout = '5s'")
            participant_ids = []
            if session_id is not None:
                cursor.execute(
                    "SELECT participant_id FROM session_sessionparticipant WHERE session_id = %s",
                    [session_id],
                )
                participant_ids = [row[0] for row in cursor.fetchall()]
                cursor.execute(
                    "UPDATE session_livesession SET current_run_id = NULL, "
                    "current_question_id = NULL, revealed_question_id = NULL WHERE id = %s",
                    [session_id],
                )
                cursor.execute(
                    "DELETE FROM session_finalanswer WHERE run_id IN "
                    "(SELECT id FROM session_sessionquestionrun WHERE session_id = %s)",
                    [session_id],
                )
                cursor.execute(
                    "DELETE FROM session_answerattempt WHERE run_id IN "
                    "(SELECT id FROM session_sessionquestionrun WHERE session_id = %s)",
                    [session_id],
                )
                cursor.execute(
                    "DELETE FROM session_legacyparticipantanswer WHERE session_participant_id IN "
                    "(SELECT id FROM session_sessionparticipant WHERE session_id = %s)",
                    [session_id],
                )
                for table in (
                    "session_sessioncommand",
                    "session_sessiondisplayaccess",
                ):
                    cursor.execute(
                        f'DELETE FROM "{table}" WHERE session_id = %s',
                        [session_id],
                    )
                cursor.execute(
                    "DELETE FROM session_sessionquestionrun WHERE session_id = %s",
                    [session_id],
                )
                cursor.execute(
                    "DELETE FROM session_sessionparticipant WHERE session_id = %s",
                    [session_id],
                )
                cursor.execute(
                    "DELETE FROM session_livesession WHERE id = %s",
                    [session_id],
                )
                if participant_ids:
                    cursor.execute(
                        "DELETE FROM session_participant WHERE id = ANY(%s)",
                        [participant_ids],
                    )
            if quiz_id is not None:
                cursor.execute(
                    "DELETE FROM quiz_choice WHERE question_id IN "
                    "(SELECT id FROM quiz_question WHERE quiz_id = %s)",
                    [quiz_id],
                )
                cursor.execute(
                    "DELETE FROM quiz_question WHERE quiz_id = %s",
                    [quiz_id],
                )
                cursor.execute("DELETE FROM quiz_quiz WHERE id = %s", [quiz_id])
            if owner_id is not None:
                cursor.execute(
                    "DELETE FROM auth_user_groups WHERE user_id = %s",
                    [owner_id],
                )
                cursor.execute(
                    "DELETE FROM auth_user_user_permissions WHERE user_id = %s",
                    [owner_id],
                )
                cursor.execute("DELETE FROM auth_user WHERE id = %s", [owner_id])
            if created_group_id is not None:
                cursor.execute(
                    "DELETE FROM auth_group_permissions WHERE group_id = %s",
                    [created_group_id],
                )
                cursor.execute(
                    "DELETE FROM auth_group WHERE id = %s AND NOT EXISTS "
                    "(SELECT 1 FROM auth_user_groups WHERE group_id = %s)",
                    [created_group_id, created_group_id],
                )

            remaining = 0
            for table, record_id in (
                ("session_livesession", session_id),
                ("quiz_quiz", quiz_id),
                ("auth_user", owner_id),
                ("auth_group", created_group_id),
            ):
                if record_id is None:
                    continue
                cursor.execute(f'SELECT COUNT(*) FROM "{table}" WHERE id = %s', [record_id])
                remaining += cursor.fetchone()[0]
            return remaining


def run_check(fail_after: str | None = None) -> dict:
    helpers = _helpers()
    helpers["bootstrap_project"]()
    helpers["load_test_environment"]()
    namespace = f"umclick:test:{uuid.uuid4()}"
    helpers["configure_stage_v_environment"](namespace)

    import django
    import redis

    django.setup()
    from django.contrib.auth import get_user_model
    from django.contrib.auth.models import Group
    from django.db import connection

    from apps.core.rate_limit import RedisRateLimiter, TOKEN_UNITS, limit_per_second
    from apps.core.websocket_limits import RedisWebSocketGuard
    from apps.quiz.models import Choice, Question, Quiz
    from apps.session.models import AnswerAttempt, LiveSession, SessionParticipant

    database_name = helpers["verify_database"](os.environ["UMCLICK_TEST_DB_NAME"])
    if not database_name.startswith("test_umclick_"):
        raise RuntimeError("Нагрузочная проверка разрешена только в test_umclick_*.")

    redis_client = redis.Redis.from_url(
        os.environ["UMCLICK_STAGE_V_REDIS_URL"],
        socket_connect_timeout=1,
        socket_timeout=1,
        decode_responses=False,
    )
    if redis_client.ping() is not True:
        raise RuntimeError("Redis PING не вернул PONG.")

    owner = None
    quiz = None
    session = None
    created_group = None
    port = None
    output: list[str] = []
    process = None
    reader = None
    sockets = []
    cleanup = {"database_rows": None, "owned_keys": None, "ports_released": 0}
    cleanup_errors: list[str] = []
    result = None
    failure = None
    try:
        run_id = uuid.uuid4()
        username = f"stage-v-load-{run_id}"
        password = f"local-{run_id}"
        owner = get_user_model().objects.create_user(
            username=username,
            password=password,
        )
        teacher_group, group_created = Group.objects.get_or_create(name="teacher")
        if group_created:
            created_group = teacher_group
        owner.groups.add(teacher_group)
        if fail_after == "user":
            raise RuntimeError("Управляемый отказ после создания пользователя.")
        quiz = Quiz.objects.create(
            owner=owner,
            title="Ограниченная нагрузочная проверка этапа В",
            reading_time_sec=3,
            results_time_sec=3,
        )
        question = Question.objects.create(
            quiz=quiz,
            text="Выберите правильный вариант",
            order=1,
            time_limit_sec=120,
        )
        correct = Choice.objects.create(
            question=question,
            text="Правильный",
            is_correct=True,
            order=1,
        )
        Choice.objects.create(
            question=question,
            text="Неверный",
            is_correct=False,
            order=2,
        )
        if fail_after == "quiz":
            raise RuntimeError("Управляемый отказ после создания части графа викторины.")
        session = LiveSession.objects.create(quiz=quiz, created_by=owner)
        session_uuid = str(session.join_token)
        port = helpers["reserve_ports"](1)[0]
        process = subprocess.Popen(
            [
                sys.executable,
                "-B",
                "-X",
                "utf8",
                str(SERVER_SCRIPT),
                "--serve",
                str(port),
            ],
            cwd=BACKEND_DIR,
            env=os.environ.copy(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
        )
        reader = threading.Thread(
            target=helpers["collect_output"],
            args=(process, output),
            daemon=True,
        )
        reader.start()
        helpers["wait_for_port"](process, port, output)

        login_status, login_body, _ = _request_json(
            port,
            "POST",
            "/api/auth/token/",
            payload={"username": username, "password": password},
        )
        if login_status != 200 or not isinstance(login_body.get("access"), str):
            raise RuntimeError(f"Вход ведущего не выполнен: HTTP {login_status}.")
        bearer = f"Bearer {login_body['access']}"

        with concurrent.futures.ThreadPoolExecutor(max_workers=PARTICIPANT_COUNT) as pool:
            join_results = list(
                pool.map(
                    lambda index: _request_json(
                        port,
                        "POST",
                        "/api/sessions/join/",
                        payload={
                            "join_token": session_uuid,
                            "name": f"Участник {index + 1}",
                            "consent": False,
                        },
                    ),
                    range(PARTICIPANT_COUNT),
                )
            )
        _assert_statuses("Подключение участников", join_results, 200)
        participant_tokens = [body["participant_token"] for _, body, _ in join_results]
        participant_ids = [body["session_participant_id"] for _, body, _ in join_results]

        websocket_results = []
        websocket_errors = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=PARTICIPANT_COUNT) as pool:
            futures = [
                pool.submit(
                    _open_participant_socket,
                    helpers["RawWebSocket"],
                    port,
                    session_uuid,
                    token,
                )
                for token in participant_tokens
            ]
            for future in concurrent.futures.as_completed(futures):
                try:
                    connection_object, latency = future.result()
                    sockets.append(connection_object)
                    websocket_results.append(latency)
                except Exception as error:
                    websocket_errors.append(str(error))
        if websocket_errors or len(websocket_results) != PARTICIPANT_COUNT:
            raise RuntimeError(
                f"WebSocket-подключения: успешно {len(websocket_results)}, "
                f"ошибок {len(websocket_errors)}."
            )

        guard = RedisWebSocketGuard(client=redis_client)
        _, ip_lease_key, _ = guard.open_keys("127.0.0.1")
        helpers["wait_for_cardinality"](redis_client, ip_lease_key, PARTICIPANT_COUNT)
        reconnect_tokens = participant_tokens[:5]
        for connection_object in sockets[:5]:
            connection_object.send_close()
            connection_object.close()
        del sockets[:5]
        helpers["wait_for_cardinality"](
            redis_client,
            ip_lease_key,
            PARTICIPANT_COUNT - len(reconnect_tokens),
        )
        reconnect_latencies = []
        for token in reconnect_tokens:
            connection_object, latency = _open_participant_socket(
                helpers["RawWebSocket"], port, session_uuid, token
            )
            sockets.append(connection_object)
            reconnect_latencies.append(latency)
        helpers["wait_for_cardinality"](redis_client, ip_lease_key, PARTICIPANT_COUNT)

        state_path = f"/api/sessions/{session_uuid}/state/"
        status, state, _ = _request_json(
            port, "GET", state_path, authorization=bearer
        )
        if status != 200:
            raise RuntimeError(f"Начальное состояние ведущего: HTTP {status}.")
        for action in ("start", "start-quiz"):
            status, state, _ = _request_json(
                port,
                "POST",
                f"/api/sessions/{session_uuid}/{action}/",
                payload=_command_payload(state),
                authorization=bearer,
            )
            if status != 200:
                raise RuntimeError(f"Команда {action}: HTTP {status}.")

        time.sleep(3.2)
        with concurrent.futures.ThreadPoolExecutor(max_workers=PARTICIPANT_COUNT) as pool:
            state_results = list(
                pool.map(
                    lambda item: _request_json(
                        port,
                        "GET",
                        f"/api/sessions/{session_uuid}/participation/",
                        authorization=f"Participant {item}",
                    ),
                    participant_tokens,
                )
            )
        _assert_statuses("Состояние участников", state_results, 200)
        if any(body.get("state", {}).get("phase") != "answering" for _, body, _ in state_results):
            raise RuntimeError("Не все участники получили фазу answering.")

        answer_results = []
        answer_started = time.perf_counter()
        for attempt_index in range(ATTEMPTS_PER_PARTICIPANT):
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=PARTICIPANT_COUNT
            ) as pool:
                wave_results = list(
                    pool.map(
                        lambda token: _request_json(
                            port,
                            "POST",
                            f"/api/sessions/{session_uuid}/answer/",
                            payload={
                                "question_id": question.pk,
                                "choice_id": correct.pk,
                                "submission_id": str(uuid.uuid4()),
                            },
                            authorization=f"Participant {token}",
                        ),
                        participant_tokens,
                    )
                )
            _assert_statuses(
                f"Ответы участников, волна {attempt_index + 1}",
                wave_results,
                200,
            )
            answer_results.extend(wave_results)
        answer_elapsed = time.perf_counter() - answer_started

        status, state, _ = _request_json(port, "GET", state_path, authorization=bearer)
        if status != 200:
            raise RuntimeError(f"Состояние перед завершением вопроса: HTTP {status}.")
        if state.get("phase") != "answering":
            raise RuntimeError(
                "Нагрузочные ответы не уложились в управляемое окно: "
                f"ожидалась фаза answering, получена {state.get('phase')!r}."
            )
        status, state, _ = _request_json(
            port,
            "POST",
            f"/api/sessions/{session_uuid}/end-question/",
            payload=_command_payload(state),
            authorization=bearer,
        )
        if status != 200 or state.get("phase") != "delivery":
            raise RuntimeError(f"Досрочное завершение вопроса: HTTP {status}.")
        time.sleep(3.2)
        status, state, _ = _request_json(port, "GET", state_path, authorization=bearer)
        if status != 200 or state.get("phase") != "results":
            raise RuntimeError(f"Фаза результатов не достигнута: HTTP {status}.")
        time.sleep(3.2)
        status, state, _ = _request_json(port, "GET", state_path, authorization=bearer)
        if status != 200 or state.get("phase") != "final":
            raise RuntimeError(f"Финальная фаза не достигнута: HTTP {status}.")

        redis_seconds, redis_microseconds = redis_client.time()
        future_ms = redis_seconds * 1000 + redis_microseconds // 1000 + 60_000
        isolated_limit = limit_per_second(
            "state", f"participant:{participant_ids[0]}", 5, 20
        )
        isolated_key = RedisRateLimiter._key(isolated_limit)
        redis_client.hset(
            isolated_key,
            mapping={"tokens": 0, "last_ms": future_ms},
        )
        redis_client.pexpire(isolated_key, isolated_limit.ttl_ms)
        limited_status, _, _ = _request_json(
            port,
            "GET",
            f"/api/sessions/{session_uuid}/participation/",
            authorization=f"Participant {participant_tokens[0]}",
        )
        peer_status, _, _ = _request_json(
            port,
            "GET",
            f"/api/sessions/{session_uuid}/participation/",
            authorization=f"Participant {participant_tokens[1]}",
        )
        if (limited_status, peer_status) != (429, 200):
            raise RuntimeError(
                "Независимость персональных квот не подтверждена: "
                f"{limited_status}/{peer_status}."
            )

        session_participants = SessionParticipant.objects.filter(session=session).count()
        attempts = AnswerAttempt.objects.filter(session_participant__session=session).count()
        expected_attempts = PARTICIPANT_COUNT * ATTEMPTS_PER_PARTICIPANT
        if session_participants != PARTICIPANT_COUNT or attempts != expected_attempts:
            raise RuntimeError(
                f"Неожиданные строки: participants={session_participants}, attempts={attempts}."
            )
        result = {
            "check": "stage_v_load",
            "status": "ok",
            "target": "127.0.0.1",
            "database": database_name,
            "namespace": namespace,
            "participants": PARTICIPANT_COUNT,
            "joins": {
                "ok": PARTICIPANT_COUNT,
                "unexpected_429": 0,
                "latency_ms": _latency_summary([item[2] for item in join_results]),
            },
            "websockets": {
                "authorized": PARTICIPANT_COUNT,
                "unexpected_rejections": 0,
                "latency_ms": _latency_summary(websocket_results),
            },
            "reconnect": {
                "ok": len(reconnect_latencies),
                "participant_rows_after": session_participants,
                "latency_ms": _latency_summary(reconnect_latencies),
            },
            "states": {
                "ok": PARTICIPANT_COUNT,
                "unexpected_429": 0,
                "latency_ms": _latency_summary([item[2] for item in state_results]),
            },
            "answers": {
                "ok": expected_attempts,
                "unexpected_429": 0,
                "attempt_rows": attempts,
                "wall_seconds": round(answer_elapsed, 3),
                "requests_per_second": round(expected_attempts / answer_elapsed, 1),
                "latency_ms": _latency_summary([item[2] for item in answer_results]),
            },
            "personal_quota": {"limited": limited_status, "peer": peer_status},
            "final_phase": state["phase"],
        }
    except Exception as error:
        failure = error
    finally:
        for connection_object in sockets:
            try:
                connection_object.send_close()
                connection_object.close()
            except Exception as error:
                cleanup_errors.append(f"websocket:{error}")
        if process is not None:
            try:
                helpers["terminate_process"](process)
            except Exception as error:
                cleanup_errors.append(f"process:{error}")
        if reader is not None:
            reader.join(timeout=2)
        if port is not None:
            try:
                helpers["verify_ports_released"]([port])
                cleanup["ports_released"] = 1
            except Exception as error:
                cleanup_errors.append(f"port:{error}")
        try:
            owned_keys = list(redis_client.scan_iter(match=f"{namespace}:*"))
            if owned_keys:
                redis_client.delete(*owned_keys)
            cleanup["owned_keys"] = sum(
                1 for _ in redis_client.scan_iter(match=f"{namespace}:*")
            )
        except Exception as error:
            cleanup_errors.append(f"redis:{error}")
        finally:
            try:
                redis_client.close()
            except Exception as error:
                cleanup_errors.append(f"redis-close:{error}")
        try:
            cleanup["database_rows"] = _cleanup_synthetic_database(
                connection,
                session.pk if session is not None else None,
                quiz.pk if quiz is not None else None,
                owner.pk if owner is not None else None,
                created_group.pk if created_group is not None else None,
            )
        except Exception as error:
            cleanup_errors.append(f"database:{error}")
        finally:
            try:
                connection.close()
            except Exception as error:
                cleanup_errors.append(f"database-close:{error}")
    if cleanup_errors:
        details = "; ".join(cleanup_errors)
        if failure is None:
            failure = RuntimeError(f"Очистка ресурсов завершилась с ошибками: {details}")
        else:
            failure = RuntimeError(f"{failure}; ошибки очистки: {details}")
    if failure is not None:
        raise RuntimeError(
            f"{failure} Очистка: {json.dumps(cleanup, ensure_ascii=False, sort_keys=True)}"
        ) from failure
    if result is None:
        raise RuntimeError("Нагрузочная проверка не сформировала результат.")
    result["cleanup"] = cleanup
    if cleanup != {"database_rows": 0, "owned_keys": 0, "ports_released": 1}:
        raise RuntimeError(f"Очистка нагрузочной проверки не завершена: {cleanup}.")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Ограниченная loopback-проверка 30 участников этапа В."
    )
    failures = parser.add_mutually_exclusive_group()
    failures.add_argument("--fail-after-user", action="store_true")
    failures.add_argument("--fail-after-quiz", action="store_true")
    arguments = parser.parse_args()
    fail_after = "user" if arguments.fail_after_user else "quiz" if arguments.fail_after_quiz else None
    try:
        result = run_check(fail_after=fail_after)
    except Exception as error:
        print(
            json.dumps(
                {
                    "check": "stage_v_load",
                    "status": "error",
                    "error_type": type(error).__name__,
                    "message": str(error),
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )
        raise SystemExit(1) from error
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
