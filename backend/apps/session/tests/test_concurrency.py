from concurrent.futures import ThreadPoolExecutor
from threading import Event
from time import monotonic
from unittest.mock import patch

from django.db import connection, connections, transaction
from django.test import TransactionTestCase
from rest_framework.test import APIClient

from apps.core.protection import HistoryConflict
from apps.quiz.models import Quiz
from apps.session.models import LiveSession, SessionParticipant
from apps.session.tests.helpers import teacher, quiz, game, url


class PostgreSQLConcurrencyTests(TransactionTestCase):
    def setUp(self):
        self.assertEqual(connection.vendor, 'postgresql', 'Конкурентные проверки А требуют PostgreSQL.')
        self.owner = teacher()

    def worker(self, ready, process, operation):
        connections.close_all()
        try:
            with connection.cursor() as cursor:
                cursor.execute('SELECT pg_backend_pid()')
                process.append(cursor.fetchone()[0])
            ready.set()
            try:
                return operation()
            except (HistoryConflict, Quiz.DoesNotExist) as exc:
                return type(exc)
        finally:
            connections.close_all()

    def wait_for_lock(self, ready, process):
        self.assertTrue(ready.wait(5), 'Второе соединение не открылось.')
        deadline = monotonic() + 5
        while monotonic() < deadline:
            with connection.cursor() as cursor:
                cursor.execute('SELECT wait_event_type FROM pg_stat_activity WHERE pid = %s', [process[0]])
                row = cursor.fetchone()
            if row and row[0] == 'Lock':
                return
            Event().wait(0.01)
        self.fail('Не подтверждено ожидание блокировки вторым соединением.')

    def test_creation_committed_first_blocks_edit_and_delete(self):
        for operation in ('edit', 'delete'):
            content = quiz(self.owner)
            ready, process = Event(), []
            def change():
                obj = Quiz.objects.get(pk=content.pk)
                if operation == 'delete':
                    obj.delete()
                else:
                    obj.title = 'Подмена'; obj.save()
            with ThreadPoolExecutor(max_workers=1) as pool:
                with transaction.atomic():
                    Quiz.objects.select_for_update().get(pk=content.pk)
                    LiveSession.objects.create(quiz=content, created_by=self.owner)
                    future = pool.submit(self.worker, ready, process, change)
                    self.wait_for_lock(ready, process)
                self.assertIs(future.result(5), HistoryConflict)
            content.refresh_from_db()
            self.assertEqual(content.title, 'Проверочная викторина')

    def test_edit_or_delete_committed_first_controls_creation(self):
        for operation in ('edit', 'delete'):
            content = quiz(self.owner)
            content_id = content.pk
            ready, process = Event(), []
            def create():
                return LiveSession.objects.create(quiz_id=content_id, created_by=self.owner).pk
            with ThreadPoolExecutor(max_workers=1) as pool:
                with transaction.atomic():
                    locked = Quiz.objects.select_for_update().get(pk=content_id)
                    future = pool.submit(self.worker, ready, process, create)
                    self.wait_for_lock(ready, process)
                    if operation == 'delete':
                        locked.delete()
                    else:
                        locked.title = 'Полностью сохранено'; locked.save()
                result = future.result(5)
            if operation == 'delete':
                self.assertIs(result, Quiz.DoesNotExist)
                self.assertFalse(LiveSession.objects.filter(quiz_id=content_id).exists())
            else:
                self.assertEqual(LiveSession.objects.get(pk=result).quiz.title, 'Полностью сохранено')

    def test_pin_collision_retries_after_concurrent_commit(self):
        first, second = quiz(self.owner), quiz(self.owner)
        ready, process = Event(), []
        with ThreadPoolExecutor(max_workers=1) as pool:
            with patch('apps.session.models.generate_pin', side_effect=['123456', '654321']):
                with transaction.atomic():
                    LiveSession.objects.create(quiz=first, created_by=self.owner, pin='123456')
                    future = pool.submit(self.worker, ready, process, lambda: LiveSession.objects.create(quiz=second, created_by=self.owner).pin)
                    self.wait_for_lock(ready, process)
                self.assertEqual(future.result(5), '654321')

    def test_registration_close_wins_against_join(self):
        g = game(self.owner)
        ready, process = Event(), []
        def join():
            return APIClient().post('/api/sessions/join/', {'join_token': str(g.session.join_token), 'name': 'Поздний'}).status_code
        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                session = LiveSession.objects.select_for_update().get(pk=g.session.pk)
                future = pool.submit(self.worker, ready, process, join)
                self.wait_for_lock(ready, process)
                session.status = 'live'; session.save()
            self.assertEqual(future.result(5), 409)
        self.assertEqual(SessionParticipant.objects.filter(session=g.session).count(), 1)

    def test_administrator_cannot_edit_during_first_session_creation(self):
        from django.contrib.auth import get_user_model
        admin = get_user_model().objects.create_superuser(username='race_admin', password='test-password-123')
        content = quiz(self.owner)
        ready, process = Event(), []
        def edit():
            client = APIClient(); client.force_login(admin)
            return client.post(f'/admin/quiz/quiz/{content.pk}/change/', {'title': 'Подмена', 'reading_time_sec': 15, 'results_time_sec': 10}).status_code
        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                Quiz.objects.select_for_update().get(pk=content.pk)
                LiveSession.objects.create(quiz=content, created_by=self.owner)
                future = pool.submit(self.worker, ready, process, edit)
                self.wait_for_lock(ready, process)
            self.assertEqual(future.result(5), 409)
        content.refresh_from_db()
        self.assertEqual(content.title, 'Проверочная викторина')

    def test_join_committed_first_survives_registration_close(self):
        g = game(self.owner)
        ready, process = Event(), []
        def start():
            client = APIClient(); client.force_authenticate(self.owner)
            return client.post(url(g.session, 'start')).status_code
        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                LiveSession.objects.select_for_update().get(pk=g.session.pk)
                response = APIClient().post('/api/sessions/join/', {'join_token': str(g.session.join_token), 'name': 'Вовремя'})
                self.assertEqual(response.status_code, 200)
                future = pool.submit(self.worker, ready, process, start)
                self.wait_for_lock(ready, process)
            self.assertEqual(future.result(5), 200)
        self.assertEqual(SessionParticipant.objects.filter(session=g.session).count(), 2)

    def test_finish_never_unlocks_quiz_and_rejects_waiting_answer(self):
        for terminal in ('finished', 'aborted'):
            g = game(self.owner, active=True)
            ready, process = Event(), []
            def answer():
                client = APIClient(); client.credentials(HTTP_AUTHORIZATION='Participant ' + g.secret)
                return client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': g.correct.pk}).status_code
            with ThreadPoolExecutor(max_workers=1) as pool:
                with transaction.atomic():
                    session = LiveSession.objects.select_for_update().get(pk=g.session.pk)
                    future = pool.submit(self.worker, ready, process, answer)
                    self.wait_for_lock(ready, process)
                    session.status = terminal; session.save()
                self.assertEqual(future.result(5), 409)
            g.quiz.title = 'Подмена'
            with self.assertRaises(HistoryConflict):
                g.quiz.save()
