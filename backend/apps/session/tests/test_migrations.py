from django.contrib.auth import authenticate
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase


class MigrationTransitionTests(TransactionTestCase):
    reset_sequences = True

    @staticmethod
    def targets_with_session(executor, session_migration):
        return [
            node
            for node in executor.loader.graph.leaf_nodes()
            if node[0] != 'session'
        ] + [('session', session_migration)]

    def test_old_schema_requires_explicit_preparation_and_preserves_accounts(self):
        self.assertEqual(connection.vendor, 'postgresql')
        self.assertTrue(connection.settings_dict['NAME'].startswith('test_'))
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        old_targets = [('quiz', '0002_quiz_presentation_settings'), ('session', '0002_live_session_presentation_flow'), ('auth', '0012_alter_user_first_name_max_length'), ('core', None)]
        try:
            executor.migrate(old_targets)
            state = executor.loader.project_state([target for target in old_targets if target[1] is not None]).apps
            user_model = state.get_model('auth', 'User')
            from django.contrib.auth.hashers import make_password
            password_hash = make_password('synthetic-test-password')
            user = user_model.objects.create(username='preserved', password=password_hash, is_active=True, is_staff=True)
            old_quiz = state.get_model('quiz', 'Quiz')
            obj = old_quiz.objects.create(title='Синтетический старый черновик')
            old_question = state.get_model('quiz', 'Question').objects.create(quiz=obj, text='Старый вопрос')
            old_choice = state.get_model('quiz', 'Choice').objects.create(question=old_question, text='Да', is_correct=True)
            state.get_model('quiz', 'Choice').objects.create(question=old_question, text='Нет')
            old_session = state.get_model('session', 'LiveSession').objects.create(quiz=obj, pin='112233', status='finished')
            old_participant_model = state.get_model('session', 'Participant')
            old_participant = old_participant_model.objects.create(name='Синтетический участник', phone='synthetic-only')
            old_link = state.get_model('session', 'SessionParticipant').objects.create(session=old_session, participant=old_participant)
            old_answer_model = state.get_model('session', 'ParticipantAnswer')
            old_answer = old_answer_model.objects.create(session_participant=old_link, question=old_question, choice=old_choice, is_correct=True, score_points=900)
            with self.assertRaisesMessage(RuntimeError, 'Найдены неподготовленные игровые данные'):
                MigrationExecutor(connection).migrate(latest)
            self.assertTrue(old_quiz.objects.filter(pk=obj.pk).exists())
            self.assertEqual(old_answer_model.objects.get(pk=old_answer.pk).score_points, 900)
            self.assertTrue(old_participant_model.objects.filter(pk=old_participant.pk).exists())
            # Только синтетическая тестовая база: явная подготовка на старой схеме.
            old_quiz.objects.all().delete()
            old_participant_model.objects.all().delete()
            MigrationExecutor(connection).migrate(latest)
            restored = user_model.objects.get(pk=user.pk)
            self.assertEqual(restored.username, 'preserved')
            self.assertEqual(restored.password, password_hash)
            self.assertIsNotNone(authenticate(username='preserved', password='synthetic-test-password'))
            from apps.session.tests.helpers import quiz
            from django.contrib.auth import get_user_model
            current = quiz(get_user_model().objects.get(pk=user.pk))
            MigrationExecutor(connection).migrate(latest)
            self.assertTrue(type(current).objects.filter(pk=current.pk).exists())
        finally:
            MigrationExecutor(connection).migrate(latest)

    def test_stage_b_migration_preserves_legacy_history_and_marks_safe_sessions(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        stage_a = self.targets_with_session(executor, '0004_alter_livesession_options_and_more')
        try:
            executor.migrate(stage_a)
            old_apps = executor.loader.project_state(stage_a).apps
            user = old_apps.get_model('auth', 'User').objects.create(username='stage-b-owner')
            quiz_model = old_apps.get_model('quiz', 'Quiz')
            question_model = old_apps.get_model('quiz', 'Question')
            choice_model = old_apps.get_model('quiz', 'Choice')
            session_model = old_apps.get_model('session', 'LiveSession')
            participant_model = old_apps.get_model('session', 'Participant')
            link_model = old_apps.get_model('session', 'SessionParticipant')
            answer_model = old_apps.get_model('session', 'ParticipantAnswer')

            content = quiz_model.objects.create(owner=user, title='Историческая викторина')
            question = question_model.objects.create(quiz=content, text='Исторический вопрос')
            choice = choice_model.objects.create(question=question, text='Верно', is_correct=True)
            safe = session_model.objects.create(quiz=content, created_by=user, pin='121212')
            terminal = session_model.objects.create(
                quiz=content,
                created_by=user,
                pin='343434',
                status='finished',
                phase='final',
            )
            participant = participant_model.objects.create(name='Исторический участник')
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
            executor.migrate(latest)
            new_apps = executor.loader.project_state(latest).apps
            new_session_model = new_apps.get_model('session', 'LiveSession')
            legacy_answer_model = new_apps.get_model('session', 'LegacyParticipantAnswer')
            self.assertEqual(new_session_model.objects.get(pk=safe.pk).gameplay_schema, 'v2')
            self.assertEqual(new_session_model.objects.get(pk=terminal.pk).gameplay_schema, 'legacy')
            preserved = legacy_answer_model.objects.get(pk=old_answer.pk)
            self.assertEqual((preserved.score_points, preserved.elapsed_ms), (900, 1234))
            self.assertFalse(new_apps.get_model('session', 'AnswerAttempt').objects.exists())
            self.assertFalse(new_apps.get_model('session', 'FinalAnswer').objects.exists())
        finally:
            MigrationExecutor(connection).migrate(latest)

    def test_stage_b_migration_stops_on_active_legacy_question(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        stage_a = self.targets_with_session(executor, '0004_alter_livesession_options_and_more')
        old_apps = None
        try:
            executor.migrate(stage_a)
            old_apps = executor.loader.project_state(stage_a).apps
            user = old_apps.get_model('auth', 'User').objects.create(username='blocked-stage-b-owner')
            content = old_apps.get_model('quiz', 'Quiz').objects.create(owner=user, title='Активная викторина')
            question = old_apps.get_model('quiz', 'Question').objects.create(quiz=content, text='Активный вопрос')
            old_apps.get_model('quiz', 'Choice').objects.create(question=question, text='Верно', is_correct=True)
            session = old_apps.get_model('session', 'LiveSession').objects.create(
                quiz=content,
                created_by=user,
                pin='565656',
                status='live',
                phase='reading',
                current_question=question,
            )
            with self.assertRaisesMessage(RuntimeError, 'Найдены активные или противоречивые сессии'):
                MigrationExecutor(connection).migrate(latest)
            self.assertTrue(old_apps.get_model('session', 'LiveSession').objects.filter(pk=session.pk).exists())
        finally:
            if old_apps is not None:
                old_apps.get_model('session', 'LiveSession').objects.all().delete()
                old_apps.get_model('quiz', 'Quiz').objects.all().delete()
                old_apps.get_model('auth', 'User').objects.filter(username='blocked-stage-b-owner').delete()
            MigrationExecutor(connection).migrate(latest)
