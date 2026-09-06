from importlib import import_module
from types import SimpleNamespace

from django.contrib.auth import authenticate
from django.contrib.auth.hashers import make_password
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.db.migrations.recorder import MigrationRecorder
from django.test import TransactionTestCase


class MigrationTransitionTests(TransactionTestCase):
    reset_sequences = True

    QUIZ_STAGE_A = '0004_alter_choice_options_alter_question_options_and_more'
    SESSION_STAGE_A = '0004_alter_livesession_options_and_more'
    SESSION_STAGE_B = '0006_stage_b_deadline_constraints'
    QUIZ_PREPARE = '0005_quiz_versioning_prepare'
    SESSION_PREPARE = '0007_quiz_versioning_prepare'
    QUIZ_SWITCH = '0006_quiz_versioning_switch'
    SESSION_SWITCH = '0008_quiz_versioning_switch'

    @staticmethod
    def targets_at(executor, *, quiz, session):
        return [
            node
            for node in executor.loader.graph.leaf_nodes()
            if node[0] not in {'quiz', 'session'}
        ] + [('quiz', quiz), ('session', session)]

    @staticmethod
    def apps_at(executor, targets):
        return executor.loader.project_state(
            [target for target in targets if target[1] is not None]
        ).apps

    @staticmethod
    def table_columns(table):
        with connection.cursor() as cursor:
            return {
                column.name
                for column in connection.introspection.get_table_description(
                    cursor,
                    table,
                )
            }

    @staticmethod
    def migration_is_applied(app, name):
        return MigrationRecorder(connection).migration_qs.filter(
            app=app,
            name=name,
        ).exists()

    @staticmethod
    def migration_applied_at(app, name):
        return MigrationRecorder(connection).migration_qs.get(
            app=app,
            name=name,
        ).applied

    def assert_base_schema(self):
        self.assertNotIn(
            'quiz_quizversion',
            connection.introspection.table_names(),
        )
        self.assertNotIn('archived_at', self.table_columns('quiz_quiz'))
        self.assertNotIn('content_revision', self.table_columns('quiz_quiz'))
        self.assertNotIn('quiz_version_id', self.table_columns('quiz_question'))
        self.assertNotIn(
            'quiz_version_id',
            self.table_columns('session_livesession'),
        )
        self.assertIn('title', self.table_columns('quiz_quiz'))
        self.assertIn('quiz_id', self.table_columns('quiz_question'))
        self.assertIn('quiz_id', self.table_columns('session_livesession'))

    def assert_prepared_schema(self):
        self.assertIn(
            'quiz_quizversion',
            connection.introspection.table_names(),
        )
        self.assertIn('archived_at', self.table_columns('quiz_quiz'))
        self.assertIn('content_revision', self.table_columns('quiz_quiz'))
        self.assertIn('quiz_version_id', self.table_columns('quiz_question'))
        self.assertIn(
            'quiz_version_id',
            self.table_columns('session_livesession'),
        )
        self.assertIn('title', self.table_columns('quiz_quiz'))
        self.assertIn('quiz_id', self.table_columns('quiz_question'))
        self.assertIn('quiz_id', self.table_columns('session_livesession'))
        with connection.cursor() as cursor:
            constraints = connection.introspection.get_constraints(
                cursor,
                'quiz_quizversion',
            )
        self.assertTrue(constraints['uniq_quiz_version_number']['unique'])
        self.assertTrue(constraints['uniq_quiz_draft_version']['unique'])
        self.assertTrue(constraints['quiz_version_status_fixed_at']['check'])

    def assert_switched_schema(self):
        self.assertIn('quiz_quizversion', connection.introspection.table_names())
        self.assertIn('archived_at', self.table_columns('quiz_quiz'))
        self.assertIn('content_revision', self.table_columns('quiz_quiz'))
        self.assertNotIn('title', self.table_columns('quiz_quiz'))
        self.assertIn('quiz_version_id', self.table_columns('quiz_question'))
        self.assertNotIn('quiz_id', self.table_columns('quiz_question'))
        self.assertIn('quiz_version_id', self.table_columns('session_livesession'))
        self.assertNotIn('quiz_id', self.table_columns('session_livesession'))
        with connection.cursor() as cursor:
            question_constraints = connection.introspection.get_constraints(
                cursor, 'quiz_question'
            )
            choice_constraints = connection.introspection.get_constraints(
                cursor, 'quiz_choice'
            )
        self.assertTrue(question_constraints['uniq_question_version_order']['unique'])
        self.assertTrue(choice_constraints['uniq_choice_question_order']['unique'])

    @staticmethod
    def delete_test_game_data(apps):
        """Удаляет только синтетические игровые строки текущего теста."""
        try:
            live_session = apps.get_model('session', 'LiveSession')
        except LookupError:
            live_session = None
        if live_session is not None:
            field_names = {field.name for field in live_session._meta.fields}
            updates = {}
            if 'current_run' in field_names:
                updates['current_run_id'] = None
            if 'current_question' in field_names:
                updates['current_question_id'] = None
            if updates:
                live_session.objects.update(**updates)

        deletion_order = (
            ('session', 'FinalAnswer'),
            ('session', 'AnswerAttempt'),
            ('session', 'LegacyParticipantAnswer'),
            ('session', 'ParticipantAnswer'),
            ('session', 'SessionCommand'),
            ('session', 'SessionDisplayAccess'),
            ('session', 'SessionQuestionRun'),
            ('session', 'SessionParticipant'),
            ('session', 'LiveSession'),
            ('session', 'Participant'),
            ('quiz', 'Choice'),
            ('quiz', 'Question'),
            ('quiz', 'QuizVersion'),
            ('quiz', 'Quiz'),
        )
        for app_label, model_name in deletion_order:
            try:
                model = apps.get_model(app_label, model_name)
            except LookupError:
                continue
            model.objects.all().delete()

    def test_old_schema_requires_explicit_preparation_and_preserves_accounts(self):
        self.assertEqual(connection.vendor, 'postgresql')
        self.assertTrue(connection.settings_dict['NAME'].startswith('test_'))
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        stage_a = self.targets_at(
            executor,
            quiz=self.QUIZ_STAGE_A,
            session=self.SESSION_STAGE_A,
        )
        old_targets = [
            ('quiz', '0002_quiz_presentation_settings'),
            ('session', '0002_live_session_presentation_flow'),
            ('auth', '0012_alter_user_first_name_max_length'),
            ('core', None),
        ]
        old_apps = None
        try:
            executor.migrate(old_targets)
            old_apps = self.apps_at(executor, old_targets)
            user_model = old_apps.get_model('auth', 'User')
            password_hash = make_password('synthetic-test-password')
            user = user_model.objects.create(
                username='preserved',
                password=password_hash,
                is_active=True,
                is_staff=True,
            )
            old_quiz = old_apps.get_model('quiz', 'Quiz')
            content = old_quiz.objects.create(
                title='Синтетический старый черновик'
            )
            question = old_apps.get_model('quiz', 'Question').objects.create(
                quiz=content,
                text='Старый вопрос',
            )
            old_choice = old_apps.get_model('quiz', 'Choice')
            correct = old_choice.objects.create(
                question=question,
                text='Да',
                is_correct=True,
            )
            old_choice.objects.create(question=question, text='Нет')
            session = old_apps.get_model('session', 'LiveSession').objects.create(
                quiz=content,
                pin='112233',
                status='finished',
            )
            participant = old_apps.get_model('session', 'Participant').objects.create(
                name='Синтетический участник',
                phone='synthetic-only',
            )
            link = old_apps.get_model(
                'session',
                'SessionParticipant',
            ).objects.create(session=session, participant=participant)
            old_answer = old_apps.get_model('session', 'ParticipantAnswer')
            answer = old_answer.objects.create(
                session_participant=link,
                question=question,
                choice=correct,
                is_correct=True,
                score_points=900,
            )

            with self.assertRaisesMessage(
                RuntimeError,
                'Найдены неподготовленные игровые данные',
            ):
                MigrationExecutor(connection).migrate(stage_a)
            self.assertTrue(old_quiz.objects.filter(pk=content.pk).exists())
            self.assertEqual(
                old_answer.objects.get(pk=answer.pk).score_points,
                900,
            )
            self.assertTrue(
                old_apps.get_model('session', 'Participant').objects.filter(
                    pk=participant.pk
                ).exists()
            )

            self.delete_test_game_data(old_apps)
            executor = MigrationExecutor(connection)
            executor.migrate(stage_a)
            stage_a_apps = self.apps_at(executor, stage_a)
            restored = stage_a_apps.get_model('auth', 'User').objects.get(
                pk=user.pk
            )
            self.assertEqual(restored.username, 'preserved')
            self.assertEqual(restored.password, password_hash)
            self.assertIsNotNone(
                authenticate(
                    username='preserved',
                    password='synthetic-test-password',
                )
            )
            MigrationExecutor(connection).migrate(stage_a)
        finally:
            if old_apps is not None:
                self.delete_test_game_data(old_apps)
            MigrationExecutor(connection).migrate(latest)

    def test_stage_b_migration_preserves_legacy_history_and_marks_safe_sessions(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        stage_a = self.targets_at(
            executor,
            quiz=self.QUIZ_STAGE_A,
            session=self.SESSION_STAGE_A,
        )
        stage_b = self.targets_at(
            executor,
            quiz=self.QUIZ_STAGE_A,
            session=self.SESSION_STAGE_B,
        )
        old_apps = None
        stage_b_apps = None
        try:
            executor.migrate(stage_a)
            old_apps = self.apps_at(executor, stage_a)
            user = old_apps.get_model('auth', 'User').objects.create(
                username='stage-b-owner'
            )
            quiz_model = old_apps.get_model('quiz', 'Quiz')
            question_model = old_apps.get_model('quiz', 'Question')
            choice_model = old_apps.get_model('quiz', 'Choice')
            session_model = old_apps.get_model('session', 'LiveSession')
            participant_model = old_apps.get_model('session', 'Participant')
            link_model = old_apps.get_model('session', 'SessionParticipant')
            answer_model = old_apps.get_model('session', 'ParticipantAnswer')

            content = quiz_model.objects.create(
                owner=user,
                title='Историческая викторина',
            )
            question = question_model.objects.create(
                quiz=content,
                text='Исторический вопрос',
            )
            choice = choice_model.objects.create(
                question=question,
                text='Верно',
                is_correct=True,
            )
            safe = session_model.objects.create(
                quiz=content,
                created_by=user,
                pin='121212',
            )
            terminal = session_model.objects.create(
                quiz=content,
                created_by=user,
                pin='343434',
                status='finished',
                phase='final',
            )
            participant = participant_model.objects.create(
                name='Исторический участник'
            )
            link = link_model.objects.create(
                session=terminal,
                participant=participant,
                token_digest='a' * 64,
                name_snapshot='Исторический участник',
            )
            old_answer = answer_model.objects.create(
                session_participant=link,
                question=question,
                choice=choice,
                is_correct=True,
                score_points=900,
                elapsed_ms=1234,
            )

            executor = MigrationExecutor(connection)
            executor.migrate(stage_b)
            stage_b_apps = self.apps_at(executor, stage_b)
            new_session_model = stage_b_apps.get_model('session', 'LiveSession')
            legacy_answer_model = stage_b_apps.get_model(
                'session',
                'LegacyParticipantAnswer',
            )
            self.assertEqual(
                new_session_model.objects.get(pk=safe.pk).gameplay_schema,
                'v2',
            )
            self.assertEqual(
                new_session_model.objects.get(pk=terminal.pk).gameplay_schema,
                'legacy',
            )
            preserved = legacy_answer_model.objects.get(pk=old_answer.pk)
            self.assertEqual(
                (preserved.score_points, preserved.elapsed_ms),
                (900, 1234),
            )
            self.assertFalse(
                stage_b_apps.get_model('session', 'AnswerAttempt').objects.exists()
            )
            self.assertFalse(
                stage_b_apps.get_model('session', 'FinalAnswer').objects.exists()
            )
        finally:
            cleanup_apps = stage_b_apps or old_apps
            if cleanup_apps is not None:
                self.delete_test_game_data(cleanup_apps)
            MigrationExecutor(connection).migrate(latest)

    def test_stage_b_migration_stops_on_active_legacy_question(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        stage_a = self.targets_at(
            executor,
            quiz=self.QUIZ_STAGE_A,
            session=self.SESSION_STAGE_A,
        )
        stage_b = self.targets_at(
            executor,
            quiz=self.QUIZ_STAGE_A,
            session=self.SESSION_STAGE_B,
        )
        old_apps = None
        try:
            executor.migrate(stage_a)
            old_apps = self.apps_at(executor, stage_a)
            user = old_apps.get_model('auth', 'User').objects.create(
                username='blocked-stage-b-owner'
            )
            content = old_apps.get_model('quiz', 'Quiz').objects.create(
                owner=user,
                title='Активная викторина',
            )
            question = old_apps.get_model('quiz', 'Question').objects.create(
                quiz=content,
                text='Активный вопрос',
            )
            old_apps.get_model('quiz', 'Choice').objects.create(
                question=question,
                text='Верно',
                is_correct=True,
            )
            session = old_apps.get_model('session', 'LiveSession').objects.create(
                quiz=content,
                created_by=user,
                pin='565656',
                status='live',
                phase='reading',
                current_question=question,
            )
            with self.assertRaisesMessage(
                RuntimeError,
                'Найдены активные или противоречивые сессии',
            ):
                MigrationExecutor(connection).migrate(stage_b)
            self.assertTrue(
                old_apps.get_model('session', 'LiveSession').objects.filter(
                    pk=session.pk
                ).exists()
            )
        finally:
            if old_apps is not None:
                self.delete_test_game_data(old_apps)
            MigrationExecutor(connection).migrate(latest)

    def test_clean_install_reaches_prepared_schema(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        without_game_apps = self.targets_at(executor, quiz=None, session=None)
        try:
            executor.migrate(without_game_apps)
            self.assertNotIn('quiz_quiz', connection.introspection.table_names())
            self.assertNotIn(
                'session_livesession',
                connection.introspection.table_names(),
            )

            MigrationExecutor(connection).migrate(latest)
            self.assert_switched_schema()
        finally:
            MigrationExecutor(connection).migrate(latest)

    def test_switched_schema_reverses_to_prepared_and_reapplies_without_game_data(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        prepared = self.targets_at(
            executor,
            quiz=self.QUIZ_PREPARE,
            session=self.SESSION_PREPARE,
        )
        try:
            executor.migrate(prepared)
            self.assert_prepared_schema()
            self.assertFalse(self.migration_is_applied('quiz', self.QUIZ_SWITCH))
            self.assertFalse(self.migration_is_applied('session', self.SESSION_SWITCH))
            MigrationExecutor(connection).migrate(latest)
            self.assert_switched_schema()
        finally:
            MigrationExecutor(connection).migrate(latest)

    def test_prepare_guard_preserves_schema_and_accounts_then_allows_retry(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        stage_b = self.targets_at(
            executor,
            quiz=self.QUIZ_STAGE_A,
            session=self.SESSION_STAGE_B,
        )
        old_apps = None
        try:
            executor.migrate(stage_b)
            old_apps = self.apps_at(executor, stage_b)
            user_model = old_apps.get_model('auth', 'User')
            password_hash = make_password('versioning-prepare-password')
            user = user_model.objects.create(
                username='versioning-prepare-owner',
                password=password_hash,
                is_active=True,
            )
            group = old_apps.get_model('auth', 'Group').objects.create(
                name='versioning-prepare-role'
            )
            user.groups.add(group)

            content = old_apps.get_model('quiz', 'Quiz').objects.create(
                owner=user,
                title='Данные перед подготовкой версий',
            )
            question = old_apps.get_model('quiz', 'Question').objects.create(
                quiz=content,
                text='Вопрос перед подготовкой',
            )
            old_apps.get_model('quiz', 'Choice').objects.create(
                question=question,
                text='Да',
                is_correct=True,
            )
            old_apps.get_model('quiz', 'Choice').objects.create(
                question=question,
                text='Нет',
            )
            session = old_apps.get_model('session', 'LiveSession').objects.create(
                quiz=content,
                created_by=user,
                pin='909090',
            )
            participant = old_apps.get_model('session', 'Participant').objects.create(
                name='Участник перед подготовкой'
            )
            old_apps.get_model('session', 'SessionParticipant').objects.create(
                session=session,
                participant=participant,
                token_digest='b' * 64,
                name_snapshot='Участник перед подготовкой',
            )

            with self.assertRaisesMessage(
                RuntimeError,
                'Найдены игровые данные перед подготовкой версий викторин',
            ):
                MigrationExecutor(connection).migrate(latest)

            self.assert_base_schema()
            self.assertTrue(
                old_apps.get_model('quiz', 'Quiz').objects.filter(
                    pk=content.pk
                ).exists()
            )
            self.assertTrue(
                old_apps.get_model('session', 'LiveSession').objects.filter(
                    pk=session.pk
                ).exists()
            )
            self.assertEqual(
                user_model.objects.get(pk=user.pk).password,
                password_hash,
            )
            self.assertTrue(
                user_model.objects.get(pk=user.pk).groups.filter(pk=group.pk).exists()
            )
            self.assertFalse(
                self.migration_is_applied('quiz', self.QUIZ_PREPARE)
            )
            self.assertFalse(
                self.migration_is_applied('session', self.SESSION_PREPARE)
            )

            self.delete_test_game_data(old_apps)
            old_apps = None
            MigrationExecutor(connection).migrate(latest)
            self.assert_switched_schema()
            self.assertTrue(
                self.migration_is_applied('quiz', self.QUIZ_PREPARE)
            )
            self.assertTrue(
                self.migration_is_applied('session', self.SESSION_PREPARE)
            )
            restored = user_model.objects.get(pk=user.pk)
            self.assertEqual(restored.password, password_hash)
            self.assertTrue(restored.groups.filter(pk=group.pk).exists())
            self.assertIsNotNone(
                authenticate(
                    username='versioning-prepare-owner',
                    password='versioning-prepare-password',
                )
            )
        finally:
            if old_apps is not None:
                self.delete_test_game_data(old_apps)
            MigrationExecutor(connection).migrate(latest)

    def test_switch_guard_preserves_prepared_schema_and_allows_retry(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        prepared = self.targets_at(
            executor,
            quiz=self.QUIZ_PREPARE,
            session=self.SESSION_PREPARE,
        )
        prepared_apps = None
        try:
            executor.migrate(prepared)
            prepared_apps = self.apps_at(executor, prepared)
            prepare_applied_at = {
                ('quiz', self.QUIZ_PREPARE): self.migration_applied_at(
                    'quiz', self.QUIZ_PREPARE
                ),
                ('session', self.SESSION_PREPARE): self.migration_applied_at(
                    'session', self.SESSION_PREPARE
                ),
            }
            user = prepared_apps.get_model('auth', 'User').objects.create(
                username='switch-guard-owner'
            )
            quiz_model = prepared_apps.get_model('quiz', 'Quiz')
            content = quiz_model.objects.create(
                owner=user,
                title='Данные после подготовительных миграций',
            )
            version = prepared_apps.get_model('quiz', 'QuizVersion').objects.create(
                quiz=content,
                number=1,
                title='Новая таблица версий тоже непуста',
            )
            question = prepared_apps.get_model('quiz', 'Question').objects.create(
                quiz=content,
                quiz_version=version,
                text='Подготовленный вопрос',
            )
            prepared_apps.get_model('quiz', 'Choice').objects.create(
                question=question,
                text='Да',
                is_correct=True,
            )

            with self.assertRaisesMessage(
                RuntimeError,
                'Найдены игровые данные перед переключением на версии викторин',
            ):
                MigrationExecutor(connection).migrate(latest)

            self.assert_prepared_schema()
            self.assertTrue(quiz_model.objects.filter(pk=content.pk).exists())
            self.assertTrue(
                prepared_apps.get_model('quiz', 'QuizVersion').objects.filter(
                    pk=version.pk
                ).exists()
            )
            self.assertTrue(self.migration_is_applied('quiz', self.QUIZ_PREPARE))
            self.assertTrue(self.migration_is_applied('session', self.SESSION_PREPARE))
            self.assertEqual(
                self.migration_applied_at('quiz', self.QUIZ_PREPARE),
                prepare_applied_at[('quiz', self.QUIZ_PREPARE)],
            )
            self.assertEqual(
                self.migration_applied_at('session', self.SESSION_PREPARE),
                prepare_applied_at[('session', self.SESSION_PREPARE)],
            )
            self.assertFalse(self.migration_is_applied('quiz', self.QUIZ_SWITCH))
            self.assertFalse(self.migration_is_applied('session', self.SESSION_SWITCH))

            self.delete_test_game_data(prepared_apps)
            prepared_apps = None
            MigrationExecutor(connection).migrate(latest)
            self.assert_switched_schema()
            self.assertTrue(self.migration_is_applied('quiz', self.QUIZ_PREPARE))
            self.assertTrue(self.migration_is_applied('session', self.SESSION_PREPARE))
            self.assertEqual(
                self.migration_applied_at('quiz', self.QUIZ_PREPARE),
                prepare_applied_at[('quiz', self.QUIZ_PREPARE)],
            )
            self.assertEqual(
                self.migration_applied_at('session', self.SESSION_PREPARE),
                prepare_applied_at[('session', self.SESSION_PREPARE)],
            )
            self.assertTrue(self.migration_is_applied('quiz', self.QUIZ_SWITCH))
            self.assertTrue(self.migration_is_applied('session', self.SESSION_SWITCH))
        finally:
            if prepared_apps is not None:
                self.delete_test_game_data(prepared_apps)
            MigrationExecutor(connection).migrate(latest)

    def test_switch_guard_checks_quiz_version_independently(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        prepared = self.targets_at(
            executor,
            quiz=self.QUIZ_PREPARE,
            session=self.SESSION_PREPARE,
        )
        try:
            executor.migrate(prepared)
            prepared_apps = self.apps_at(executor, prepared)
            migration = import_module(
                'apps.quiz.migrations.0006_quiz_versioning_switch'
            )

            class ExistsResult:
                def __init__(self, exists):
                    self.exists_value = exists

                def using(self, alias):
                    self.alias = alias
                    return self

                def exists(self):
                    return self.exists_value

            class RecordingApps:
                def __init__(self, non_empty=None):
                    self.non_empty = non_empty
                    self.checked = []

                def get_model(self, app_label, model_name):
                    key = (app_label, model_name)
                    historical_model = prepared_apps.get_model(*key)
                    self.checked.append(key)
                    return SimpleNamespace(
                        _meta=historical_model._meta,
                        objects=ExistsResult(key == self.non_empty),
                    )

            all_empty = RecordingApps()
            migration.require_empty_versioning_game_data(
                all_empty,
                SimpleNamespace(connection=connection),
            )
            self.assertEqual(tuple(all_empty.checked), migration.GAME_MODELS)

            only_version = RecordingApps(('quiz', 'QuizVersion'))
            with self.assertRaisesMessage(RuntimeError, 'quiz_quizversion'):
                migration.require_empty_versioning_game_data(
                    only_version,
                    SimpleNamespace(connection=connection),
                )
            self.assertIn(('quiz', 'QuizVersion'), only_version.checked)
        finally:
            MigrationExecutor(connection).migrate(latest)

    def test_destructive_reverse_is_rejected_before_schema_changes(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        prepared = self.targets_at(
            executor,
            quiz=self.QUIZ_PREPARE,
            session=self.SESSION_PREPARE,
        )
        final_apps = None
        try:
            executor.migrate(latest)
            final_apps = self.apps_at(MigrationExecutor(connection), latest)
            user = final_apps.get_model('auth', 'User').objects.create(
                username='reverse-guard-owner'
            )
            content = final_apps.get_model('quiz', 'Quiz').objects.create(owner=user)
            version = final_apps.get_model('quiz', 'QuizVersion').objects.create(
                quiz=content,
                number=1,
                status='fixed',
                fixed_at='2026-01-01T00:00:00Z',
                title='Зафиксированная версия',
            )
            question = final_apps.get_model('quiz', 'Question').objects.create(
                quiz_version=version,
                text='Зафиксированный вопрос',
            )
            final_apps.get_model('quiz', 'Choice').objects.create(
                question=question,
                text='Да',
                is_correct=True,
            )
            final_apps.get_model('session', 'LiveSession').objects.create(
                quiz_version=version,
                created_by=user,
                pin='818181',
            )

            with self.assertRaisesMessage(
                RuntimeError,
                'Обратное переключение схемы версий запрещено',
            ):
                MigrationExecutor(connection).migrate(prepared)

            self.assert_switched_schema()
            self.assertTrue(self.migration_is_applied('quiz', self.QUIZ_SWITCH))
            self.assertTrue(self.migration_is_applied('session', self.SESSION_SWITCH))

            self.delete_test_game_data(final_apps)
            MigrationExecutor(connection).migrate(prepared)
            self.assert_prepared_schema()
            MigrationExecutor(connection).migrate(latest)
            self.assert_switched_schema()
        finally:
            if final_apps is not None:
                self.delete_test_game_data(final_apps)
            MigrationExecutor(connection).migrate(latest)
