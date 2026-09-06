import hashlib
import json
import os
import re

from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction


TARGET_TABLES = (
    "session_finalanswer",
    "session_answerattempt",
    "session_legacyparticipantanswer",
    "session_sessioncommand",
    "session_sessiondisplayaccess",
    "session_sessionquestionrun",
    "session_sessionparticipant",
    "session_livesession",
    "session_participant",
    "quiz_choice",
    "quiz_question",
    "quiz_quizversion",
    "quiz_quiz",
)
PRESERVED_TABLES = (
    "auth_user",
    "auth_group",
    "auth_user_groups",
    "auth_user_user_permissions",
    "django_session",
    "django_migrations",
)
BACKUP_DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def _safe_fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


class Command(BaseCommand):
    help = (
        "Инвентаризирует либо контролируемо очищает только игровые данные этапа В. "
        "Учётные записи, права, сессии входа и история миграций сохраняются."
    )

    def add_arguments(self, parser):
        mode = parser.add_mutually_exclusive_group(required=True)
        mode.add_argument("--inventory", action="store_true")
        mode.add_argument("--rollback-test", action="store_true")
        mode.add_argument("--apply", action="store_true")
        parser.add_argument("--expected-database", required=True)
        parser.add_argument("--expected-host", required=True)
        parser.add_argument("--expected-port", required=True)
        parser.add_argument("--expected-role", required=True)
        parser.add_argument("--confirm")
        parser.add_argument("--backup-sha256")

    def handle(self, *args, **options):
        if connection.vendor != "postgresql":
            raise CommandError("Команда допускает только PostgreSQL.")

        target = self._verify_target(options)
        before = self._inventory()
        mode = self._mode(options)
        if mode == "inventory":
            self._write_result(mode, target, before, before, {}, "not_started")
            return

        self._verify_mutation_authority(mode, options, target)
        deleted = {}
        with transaction.atomic():
            with connection.cursor() as cursor:
                cursor.execute("SET LOCAL lock_timeout = '5s'")
                cursor.execute(
                    "LOCK TABLE "
                    + ", ".join(f'\"{table}\"' for table in TARGET_TABLES)
                    + " IN ACCESS EXCLUSIVE MODE"
                )
                locked_before = self._inventory(cursor)
                if locked_before != before:
                    raise CommandError(
                        "Инвентаризация изменилась до получения блокировок; повторите проверку."
                    )
                cursor.execute(
                    "UPDATE session_livesession "
                    "SET current_run_id = NULL, current_question_id = NULL, "
                    "revealed_question_id = NULL"
                )
                for table in TARGET_TABLES:
                    cursor.execute(f'DELETE FROM "{table}"')
                    deleted[table] = cursor.rowcount
                cleared = self._inventory(cursor)
                if any(cleared["game_data"].values()):
                    raise CommandError("Не все целевые игровые таблицы очищены.")
                if cleared["preserved"] != before["preserved"]:
                    raise CommandError("Изменилась одна из сохраняемых таблиц.")
                if mode == "rollback_test":
                    transaction.set_rollback(True)

        after = self._inventory()
        if mode == "rollback_test":
            if after != before:
                raise CommandError("Проверочный откат не восстановил исходную инвентаризацию.")
            transaction_result = "rolled_back"
        else:
            if any(after["game_data"].values()):
                raise CommandError("После фиксации остались игровые данные.")
            if after["preserved"] != before["preserved"]:
                raise CommandError("После фиксации изменились сохраняемые таблицы.")
            transaction_result = "committed"
        self._write_result(mode, target, before, after, deleted, transaction_result)

    @staticmethod
    def _mode(options):
        if options["inventory"]:
            return "inventory"
        if options["rollback_test"]:
            return "rollback_test"
        return "apply"

    @staticmethod
    def _actual_target():
        configured_host = str(connection.settings_dict.get("HOST") or "").strip()
        with connection.cursor() as cursor:
            cursor.execute("SELECT current_database(), current_user, inet_server_port()")
            database_name, role_name, server_port = cursor.fetchone()
        return {
            "database": database_name,
            "host": configured_host,
            "port": str(server_port),
            "role": role_name,
        }

    def _verify_target(self, options):
        expected = {
            "database": options["expected_database"].strip(),
            "host": options["expected_host"].strip(),
            "port": options["expected_port"].strip(),
            "role": options["expected_role"].strip(),
        }
        if any(not value for value in expected.values()):
            raise CommandError("Ожидаемые база, хост, порт и роль не могут быть пустыми.")
        actual = self._actual_target()
        if actual != expected:
            safe_actual = {
                "database": actual["database"],
                "host": actual["host"],
                "port": actual["port"],
                "role": actual["role"],
            }
            raise CommandError(
                "Целевое окружение не совпало: "
                + json.dumps(safe_actual, ensure_ascii=False, sort_keys=True)
            )
        return actual

    @staticmethod
    def _verify_mutation_authority(mode, options, target):
        required_confirmation = f"DELETE-STAGE-V-GAME-DATA:{target['database']}"
        if options.get("confirm") != required_confirmation:
            raise CommandError("Не передана точная фраза подтверждения для целевой базы.")
        if mode == "rollback_test":
            return

        backup_digest = (options.get("backup_sha256") or "").lower()
        if not BACKUP_DIGEST_PATTERN.fullmatch(backup_digest):
            raise CommandError("Нужна полная SHA-256 проверенной резервной копии.")
        expected_guard = "|".join(
            (
                target["database"],
                target["host"],
                target["port"],
                target["role"],
                backup_digest,
            )
        )
        if os.getenv("UMCLICK_ALLOW_GAME_DATA_CLEANUP") != expected_guard:
            raise CommandError(
                "UMCLICK_ALLOW_GAME_DATA_CLEANUP не подтверждает точные базу, хост, порт, роль и SHA-256."
            )

    @staticmethod
    def _inventory(cursor=None):
        owns_cursor = cursor is None
        cursor = cursor or connection.cursor()
        try:
            result = {"game_data": {}, "preserved": {}}
            for section, tables in (
                ("game_data", TARGET_TABLES),
                ("preserved", PRESERVED_TABLES),
            ):
                for table in tables:
                    cursor.execute(f'SELECT COUNT(*) FROM "{table}"')
                    result[section][table] = cursor.fetchone()[0]
            return result
        finally:
            if owns_cursor:
                cursor.close()

    def _write_result(self, mode, target, before, after, deleted, transaction_result):
        payload = {
            "check": "stage_v_game_data",
            "mode": mode,
            "target": target,
            "target_fingerprint": _safe_fingerprint(
                f"{target['database']}\0{target['host']}\0{target['port']}\0{target['role']}"
            ),
            "before": before,
            "deleted": deleted,
            "after": after,
            "transaction": transaction_result,
        }
        self.stdout.write(
            json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        )
