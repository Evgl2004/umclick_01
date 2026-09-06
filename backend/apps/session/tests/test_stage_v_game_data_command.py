import io
import json
import hashlib
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import connection
from django.test import TransactionTestCase

from django.contrib.auth import authenticate, get_user_model

from apps.quiz.models import QuizVersion
from apps.session.models import LiveSession
from apps.session.tests.helpers import game, teacher


class StageVGameDataCommandTests(TransactionTestCase):
    reset_sequences = True

    def setUp(self):
        self.owner = teacher("stage-v-cleanup-owner")
        self.game = game(self.owner, active=True)
        self.version = QuizVersion.objects.create(
            quiz=self.game.quiz,
            number=1,
            title='Синтетическая версия для проверки очистки',
        )
        self.password_hash = self.owner.password
        self.group_names = set(self.owner.groups.values_list('name', flat=True))
        with connection.cursor() as cursor:
            cursor.execute("SELECT current_database(), current_user, inet_server_port()")
            self.database_name, self.role_name, port = cursor.fetchone()
        self.host = str(connection.settings_dict.get("HOST") or "").strip()
        self.port = str(port)

    def arguments(self):
        return [
            "--expected-database",
            self.database_name,
            "--expected-host",
            self.host,
            "--expected-port",
            self.port,
            "--expected-role",
            self.role_name,
        ]

    def test_inventory_is_read_only_and_machine_readable(self):
        output = io.StringIO()
        call_command("stage_v_game_data", "--inventory", *self.arguments(), stdout=output)

        payload = json.loads(output.getvalue())
        self.assertEqual(payload["mode"], "inventory")
        self.assertEqual(payload["transaction"], "not_started")
        self.assertEqual(payload["before"], payload["after"])
        self.assertEqual(
            payload["target"],
            {
                "database": self.database_name,
                "host": self.host,
                "port": self.port,
                "role": self.role_name,
            },
        )
        fingerprint_source = (
            f"{self.database_name}\0{self.host}\0{self.port}\0{self.role_name}"
        )
        self.assertEqual(
            payload["target_fingerprint"],
            hashlib.sha256(fingerprint_source.encode("utf-8")).hexdigest()[:16],
        )
        self.assertTrue(LiveSession.objects.filter(pk=self.game.session.pk).exists())
        self.assertEqual(payload['before']['game_data']['quiz_quizversion'], 1)
        self.assertTrue(QuizVersion.objects.filter(pk=self.version.pk).exists())

    def test_rollback_test_executes_same_delete_set_without_changes(self):
        output = io.StringIO()
        confirmation = f"DELETE-STAGE-V-GAME-DATA:{self.database_name}"
        call_command(
            "stage_v_game_data",
            "--rollback-test",
            *self.arguments(),
            "--confirm",
            confirmation,
            stdout=output,
        )

        payload = json.loads(output.getvalue())
        self.assertEqual(payload["transaction"], "rolled_back")
        self.assertEqual(payload["before"], payload["after"])
        self.assertGreater(payload["deleted"]["session_livesession"], 0)
        self.assertEqual(payload['deleted']['quiz_quizversion'], 1)
        self.assertTrue(LiveSession.objects.filter(pk=self.game.session.pk).exists())
        self.assertTrue(QuizVersion.objects.filter(pk=self.version.pk).exists())

    @patch.dict("os.environ", {"UMCLICK_ALLOW_GAME_DATA_CLEANUP": ""}, clear=False)
    def test_apply_requires_environment_guard_before_delete(self):
        output = io.StringIO()
        confirmation = f"DELETE-STAGE-V-GAME-DATA:{self.database_name}"
        with self.assertRaisesMessage(
            CommandError,
            "UMCLICK_ALLOW_GAME_DATA_CLEANUP",
        ):
            call_command(
                "stage_v_game_data",
                "--apply",
                *self.arguments(),
                "--confirm",
                confirmation,
                "--backup-sha256",
                "0" * 64,
                stdout=output,
            )

        self.assertTrue(LiveSession.objects.filter(pk=self.game.session.pk).exists())

    def test_wrong_database_host_port_or_role_is_rejected_before_mutation(self):
        replacements = {
            "--expected-database": "wrong_database",
            "--expected-host": "wrong-host",
            "--expected-port": str(int(self.port) + 1),
            "--expected-role": "wrong_role",
        }
        for option, wrong_value in replacements.items():
            with self.subTest(option=option):
                arguments = self.arguments()
                arguments[arguments.index(option) + 1] = wrong_value
                with self.assertRaisesMessage(CommandError, "Целевое окружение не совпало"):
                    call_command(
                        "stage_v_game_data",
                        "--inventory",
                        *arguments,
                        stdout=io.StringIO(),
                    )
                self.assertTrue(
                    LiveSession.objects.filter(pk=self.game.session.pk).exists()
                )

    def test_wrong_confirmation_is_rejected_before_mutation(self):
        with self.assertRaisesMessage(CommandError, "точная фраза подтверждения"):
            call_command(
                "stage_v_game_data",
                "--rollback-test",
                *self.arguments(),
                "--confirm",
                "DELETE-STAGE-V-GAME-DATA:wrong",
                stdout=io.StringIO(),
            )
        self.assertTrue(LiveSession.objects.filter(pk=self.game.session.pk).exists())

    def test_apply_rejects_malformed_and_other_valid_sha256(self):
        confirmation = f"DELETE-STAGE-V-GAME-DATA:{self.database_name}"
        approved_digest = "a" * 64
        approved_guard = "|".join(
            (
                self.database_name,
                self.host,
                self.port,
                self.role_name,
                approved_digest,
            )
        )
        with patch.dict(
            "os.environ",
            {"UMCLICK_ALLOW_GAME_DATA_CLEANUP": approved_guard},
            clear=False,
        ):
            with self.assertRaisesMessage(CommandError, "полная SHA-256"):
                call_command(
                    "stage_v_game_data",
                    "--apply",
                    *self.arguments(),
                    "--confirm",
                    confirmation,
                    "--backup-sha256",
                    "not-a-sha",
                    stdout=io.StringIO(),
                )
            with self.assertRaisesMessage(
                CommandError,
                "UMCLICK_ALLOW_GAME_DATA_CLEANUP",
            ):
                call_command(
                    "stage_v_game_data",
                    "--apply",
                    *self.arguments(),
                    "--confirm",
                    confirmation,
                    "--backup-sha256",
                    "b" * 64,
                    stdout=io.StringIO(),
                )
        self.assertTrue(LiveSession.objects.filter(pk=self.game.session.pk).exists())

    def test_apply_with_exact_target_confirmation_and_sha_deletes_only_game_data(self):
        confirmation = f"DELETE-STAGE-V-GAME-DATA:{self.database_name}"
        digest = "c" * 64
        guard = "|".join(
            (
                self.database_name,
                self.host,
                self.port,
                self.role_name,
                digest,
            )
        )
        output = io.StringIO()
        with patch.dict(
            "os.environ",
            {"UMCLICK_ALLOW_GAME_DATA_CLEANUP": guard},
            clear=False,
        ):
            call_command(
                "stage_v_game_data",
                "--apply",
                *self.arguments(),
                "--confirm",
                confirmation,
                "--backup-sha256",
                digest,
                stdout=output,
            )

        payload = json.loads(output.getvalue())
        self.assertEqual(payload["transaction"], "committed")
        self.assertFalse(LiveSession.objects.filter(pk=self.game.session.pk).exists())
        self.assertFalse(QuizVersion.objects.filter(pk=self.version.pk).exists())
        self.assertEqual(payload['deleted']['quiz_quizversion'], 1)
        owner = get_user_model().objects.get(pk=self.owner.pk)
        self.assertEqual(owner.password, self.password_hash)
        self.assertEqual(
            set(owner.groups.values_list('name', flat=True)),
            self.group_names,
        )
        self.assertIsNotNone(
            authenticate(
                username='stage-v-cleanup-owner',
                password='test-password-123',
            )
        )
