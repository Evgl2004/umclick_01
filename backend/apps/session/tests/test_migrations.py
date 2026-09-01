from django.contrib.auth import authenticate
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase


class MigrationTransitionTests(TransactionTestCase):
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
