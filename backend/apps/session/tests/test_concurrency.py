from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier, Event, Lock, get_ident
from time import monotonic
from unittest.mock import patch
import uuid

from django.db import connection, connections, transaction
from django.test import TransactionTestCase
from rest_framework.test import APIClient

from apps.core.protection import HistoryConflict
from apps.core.errors import Conflict, QuizRevisionConflict
from apps.quiz.models import Quiz
from apps.quiz.services import save_quiz_content
from apps.session.advance import advance_session_if_due
from apps.session.gameplay import database_now, execute_manual_command, record_answer_attempt
from apps.session.models import (
    AnswerAttempt,
    FinalAnswer,
    LiveSession,
    SessionCommand,
    SessionDisplayAccess,
    SessionParticipant,
    SessionQuestionRun,
)
from apps.session.tests.helpers import activate_gameplay, command_payload, participate, teacher, quiz, game, url
from apps.session.services import create_live_session


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
            except (HistoryConflict, Quiz.DoesNotExist, QuizRevisionConflict) as exc:
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

    def past_deadline_game(self):
        g = game(self.owner)
        now = database_now()
        run = SessionQuestionRun.objects.create(
            session=g.session,
            question=g.question,
            ordinal=1,
            reading_started_at=now - timedelta(seconds=50),
            reading_ends_at=now - timedelta(seconds=40),
            answering_started_at=now - timedelta(seconds=40),
            planned_answer_deadline_at=now - timedelta(seconds=10),
            planned_delivery_deadline_at=now - timedelta(seconds=7),
            answer_deadline_at=now - timedelta(seconds=10),
            delivery_deadline_at=now - timedelta(seconds=7),
        )
        g.session.status = LiveSession.STATUS_LIVE
        g.session.phase = LiveSession.PHASE_DELIVERY
        g.session.current_question = g.question
        g.session.current_run = run
        g.session.question_started_at = run.answering_started_at
        g.session.phase_started_at = run.answer_deadline_at
        g.session.started_at = run.reading_started_at
        g.session.state_revision = 3
        g.session.save()
        return g, run

    @staticmethod
    def record(g, submission_id=None):
        return record_answer_attempt(
            session_id=g.session.pk,
            participation_id=g.link.pk,
            question_id=g.question.pk,
            choice_id=g.correct.pk,
            submission_id=submission_id or uuid.uuid4(),
        )

    def test_concurrent_saves_allow_exactly_one_revision(self):
        content = quiz(self.owner)
        barrier = Barrier(2)

        def save(title):
            connections.close_all()
            try:
                barrier.wait(5)
                return save_quiz_content(
                    quiz_id=content.pk,
                    actor=self.owner,
                    expected_revision=1,
                    data={'title': title},
                ).pk
            except QuizRevisionConflict as exc:
                return type(exc)
            finally:
                connections.close_all()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = [
                future.result(10)
                for future in (
                    pool.submit(save, 'Первая запись'),
                    pool.submit(save, 'Вторая запись'),
                )
            ]

        self.assertEqual(results.count(content.pk), 1)
        self.assertEqual(results.count(QuizRevisionConflict), 1)
        content.refresh_from_db()
        self.assertEqual(content.content_revision, 2)
        self.assertIn(content.versions.get().title, {'Первая запись', 'Вторая запись'})

    def test_edit_or_delete_committed_first_controls_creation(self):
        content = quiz(self.owner)
        ready, process = Event(), []

        def create():
            return create_live_session(quiz_id=content.pk, actor=self.owner).pk

        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                Quiz.objects.select_for_update().get(pk=content.pk)
                save_quiz_content(
                    quiz_id=content.pk,
                    actor=self.owner,
                    expected_revision=1,
                    data={'title': 'Сохранено до запуска'},
                )
                future = pool.submit(self.worker, ready, process, create)
                self.wait_for_lock(ready, process)
            session = LiveSession.objects.get(pk=future.result(5))

        self.assertEqual(session.quiz_version.title, 'Сохранено до запуска')
        self.assertEqual(session.quiz_version.status, 'fixed')

    def test_session_committed_first_keeps_its_version_and_save_creates_draft(self):
        content = quiz(self.owner)
        ready, process = Event(), []

        def save():
            return save_quiz_content(
                quiz_id=content.pk,
                actor=self.owner,
                expected_revision=1,
                data={'title': 'Черновик после запуска'},
            ).pk

        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                session = create_live_session(quiz_id=content.pk, actor=self.owner)
                fixed_version_id = session.quiz_version_id
                future = pool.submit(self.worker, ready, process, save)
                self.wait_for_lock(ready, process)
            self.assertEqual(future.result(5), content.pk)

        session.refresh_from_db()
        self.assertEqual(session.quiz_version_id, fixed_version_id)
        self.assertEqual(session.quiz_version.title, 'Проверочная викторина')
        draft = content.versions.get(status='draft')
        self.assertEqual(draft.title, 'Черновик после запуска')
        self.assertNotEqual(draft.pk, fixed_version_id)

    def test_delete_committed_first_prevents_session_creation(self):
        content = quiz(self.owner)
        ready, process = Event(), []

        def create():
            return create_live_session(quiz_id=content.pk, actor=self.owner).pk

        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                locked = Quiz.objects.select_for_update().get(pk=content.pk)
                locked.delete()
                future = pool.submit(self.worker, ready, process, create)
                self.wait_for_lock(ready, process)
            self.assertIs(future.result(5), Quiz.DoesNotExist)

        self.assertFalse(Quiz.objects.filter(pk=content.pk).exists())
        self.assertFalse(LiveSession.objects.filter(quiz_version__quiz_id=content.pk).exists())

    def test_session_committed_first_prevents_quiz_deletion(self):
        content = quiz(self.owner)
        ready, process = Event(), []

        def delete():
            Quiz.objects.get(pk=content.pk).delete()
            return 'deleted'

        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                session = create_live_session(quiz_id=content.pk, actor=self.owner)
                future = pool.submit(self.worker, ready, process, delete)
                self.wait_for_lock(ready, process)
            self.assertIs(future.result(5), HistoryConflict)

        self.assertTrue(Quiz.objects.filter(pk=content.pk).exists())
        self.assertTrue(LiveSession.objects.filter(pk=session.pk).exists())

    def test_concurrent_pin_collision_retries_after_transaction_overlap(self):
        first, second = quiz(self.owner), quiz(self.owner)
        first_generation = Barrier(2)
        counter_lock = Lock()
        attempts = {}

        def colliding_pin():
            thread_id = get_ident()
            with counter_lock:
                attempts[thread_id] = attempts.get(thread_id, 0) + 1
                attempt = attempts[thread_id]
            if attempt == 1:
                first_generation.wait(5)
                return '123456'
            return '654321'

        def create(content):
            session = create_live_session(quiz_id=content.pk, actor=self.owner)
            return session.pk, session.pin

        ready = [Event(), Event()]
        process = [[], []]
        with patch('apps.session.models.generate_pin', side_effect=colliding_pin):
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [
                    pool.submit(
                        self.worker,
                        ready[index],
                        process[index],
                        lambda content=content: create(content),
                    )
                    for index, content in enumerate((first, second))
                ]
                results = [future.result(10) for future in futures]

        self.assertEqual({pin for _, pin in results}, {'123456', '654321'})
        self.assertEqual(len({pk for pk, _ in results}), 2)
        self.assertEqual(LiveSession.objects.filter(pk__in=[pk for pk, _ in results]).count(), 2)

    def test_two_concurrent_sessions_share_one_fixed_version(self):
        content = quiz(self.owner)
        start = Barrier(2)
        counter_lock = Lock()
        pins = iter(('111111', '222222'))

        def next_pin():
            with counter_lock:
                return next(pins)

        def create():
            start.wait(5)
            session = create_live_session(quiz_id=content.pk, actor=self.owner)
            return session.pk, session.join_token, session.pin, session.quiz_version_id

        ready = [Event(), Event()]
        process = [[], []]
        with patch('apps.session.models.generate_pin', side_effect=next_pin):
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = [future.result(10) for future in (
                    pool.submit(self.worker, ready[0], process[0], create),
                    pool.submit(self.worker, ready[1], process[1], create),
                )]

        self.assertEqual(len({item[0] for item in results}), 2)
        self.assertEqual(len({item[1] for item in results}), 2)
        self.assertEqual({item[2] for item in results}, {'111111', '222222'})
        self.assertEqual(len({item[3] for item in results}), 1)
        self.assertEqual(content.versions.count(), 1)
        version = content.versions.get()
        self.assertEqual(version.status, 'fixed')
        self.assertEqual({item[3] for item in results}, {version.pk})

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
        client = APIClient(); client.force_login(admin)
        response = client.post(
            f'/admin/quiz/quiz/{content.pk}/change/',
            {'title': 'Подмена'},
        )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(content.versions.get().title, 'Проверочная викторина')

    def test_join_committed_first_survives_registration_close(self):
        g = game(self.owner)
        ready, process = Event(), []
        def start():
            client = APIClient(); client.force_authenticate(self.owner)
            return client.post(url(g.session, 'start'), command_payload(g.session), format='json').status_code
        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                LiveSession.objects.select_for_update().get(pk=g.session.pk)
                response = APIClient().post('/api/sessions/join/', {'join_token': str(g.session.join_token), 'name': 'Вовремя'})
                self.assertEqual(response.status_code, 200)
                future = pool.submit(self.worker, ready, process, start)
                self.wait_for_lock(ready, process)
            self.assertEqual(future.result(5), 200)
        self.assertEqual(SessionParticipant.objects.filter(session=g.session).count(), 2)

    def test_terminal_state_never_unlocks_quiz_and_rejects_new_answer(self):
        for terminal in ('finished', 'aborted'):
            g = game(self.owner, active=True)
            session = LiveSession.objects.get(pk=g.session.pk)
            session.status = terminal
            session.save()
            client = APIClient()
            client.credentials(HTTP_AUTHORIZATION='Participant ' + g.secret)
            response = client.post(
                url(g.session, 'answer'),
                {'question_id': g.question.pk, 'choice_id': g.correct.pk, 'submission_id': str(uuid.uuid4())},
            )
            self.assertEqual(response.status_code, 409)
            self.assertFalse(AnswerAttempt.objects.filter(run=g.session.current_run).exists())
            g.version.title = 'Подмена'
            with self.assertRaises(HistoryConflict):
                g.version.save()

    def test_different_participants_do_not_block_each_other(self):
        g = game(self.owner)
        second, _ = participate(g.session, name='Второй')
        activate_gameplay(g.session, g.question)
        first_ready, first_process = Event(), []
        second_ready, second_process = Event(), []

        def record_for(participation_id):
            return record_answer_attempt(
                session_id=g.session.pk,
                participation_id=participation_id,
                question_id=g.question.pk,
                choice_id=g.correct.pk,
                submission_id=uuid.uuid4(),
            )

        with ThreadPoolExecutor(max_workers=2) as pool:
            with transaction.atomic():
                SessionParticipant.objects.select_for_update().get(pk=g.link.pk)
                blocked = pool.submit(self.worker, first_ready, first_process, lambda: record_for(g.link.pk))
                self.wait_for_lock(first_ready, first_process)
                independent = pool.submit(self.worker, second_ready, second_process, lambda: record_for(second.pk))
                self.assertIsNotNone(independent.result(5)[0])
                self.assertFalse(blocked.done())
            self.assertIsNotNone(blocked.result(5)[0])
        self.assertEqual(AnswerAttempt.objects.filter(run=g.session.current_run).count(), 2)

    def test_same_participant_attempts_are_serialized(self):
        g = game(self.owner, active=True)
        first_ready, first_process = Event(), []
        second_ready, second_process = Event(), []
        first_locked, release_first = Event(), Event()
        barrier_calls = []
        def hold_first_participant_lock(participation_id):
            barrier_calls.append(participation_id)
            if len(barrier_calls) == 1:
                first_locked.set()
                self.assertTrue(release_first.wait(5), 'Не освобождён тестовый барьер участия.')
        with patch('apps.session.gameplay._answer_participant_lock_barrier', side_effect=hold_first_participant_lock):
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(self.worker, first_ready, first_process, lambda: self.record(g))
                self.assertTrue(first_locked.wait(5), 'Первый ответ не получил блокировку участия.')
                second = pool.submit(self.worker, second_ready, second_process, lambda: self.record(g))
                try:
                    self.wait_for_lock(second_ready, second_process)
                finally:
                    release_first.set()
                self.assertIsNotNone(first.result(5)[0])
                self.assertIsNotNone(second.result(5)[0])
        attempts = AnswerAttempt.objects.filter(run=g.session.current_run).order_by('ordinal')
        self.assertEqual(list(attempts.values_list('ordinal', flat=True)), [1, 2])
        self.assertEqual(barrier_calls, [g.link.pk, g.link.pk])

    def test_answer_admitted_first_is_included_before_finalizer(self):
        g, run = self.past_deadline_game()
        answer_ready, answer_process = Event(), []
        final_ready, final_process = Event(), []
        answer_locked, release_answer = Event(), Event()
        admitted_at = run.delivery_deadline_at - timedelta(microseconds=1)
        def hold_answer_lock():
            answer_locked.set()
            self.assertTrue(release_answer.wait(5), 'Не освобождён тестовый барьер ответа.')
        with (
            patch('apps.session.gameplay.database_now', return_value=admitted_at),
            patch('apps.session.gameplay._answer_run_lock_barrier', side_effect=hold_answer_lock),
        ):
            with ThreadPoolExecutor(max_workers=2) as pool:
                answer = pool.submit(self.worker, answer_ready, answer_process, lambda: self.record(g))
                self.assertTrue(answer_locked.wait(5), 'Ответ не получил разделяемую блокировку запуска.')
                finalizer = pool.submit(
                    self.worker,
                    final_ready,
                    final_process,
                    lambda: advance_session_if_due(g.session, now=run.delivery_deadline_at + timedelta(seconds=1)),
                )
                try:
                    self.wait_for_lock(final_ready, final_process)
                finally:
                    release_answer.set()
                attempt = answer.result(5)[0]
                self.assertTrue(finalizer.result(5)[1])
        final = FinalAnswer.objects.get(run=run, session_participant=g.link)
        self.assertEqual(final.selected_attempt_id, attempt.pk)
        self.assertTrue(final.is_correct)

    def test_finalizer_locked_first_keeps_later_attempt_out_of_result(self):
        g, run = self.past_deadline_game()
        final_ready, final_process = Event(), []
        answer_ready, answer_process = Event(), []
        finalizer_locked, release_finalizer = Event(), Event()
        def hold_finalizer_lock():
            finalizer_locked.set()
            self.assertTrue(release_finalizer.wait(5), 'Не освобождён тестовый барьер финализатора.')
        with patch('apps.session.gameplay._finalizer_run_lock_barrier', side_effect=hold_finalizer_lock):
            with ThreadPoolExecutor(max_workers=2) as pool:
                finalizer = pool.submit(
                    self.worker,
                    final_ready,
                    final_process,
                    lambda: advance_session_if_due(g.session, now=run.delivery_deadline_at + timedelta(seconds=1)),
                )
                self.assertTrue(finalizer_locked.wait(5), 'Финализатор не получил исключительную блокировку запуска.')
                answer = pool.submit(self.worker, answer_ready, answer_process, lambda: self.record(g))
                try:
                    self.wait_for_lock(answer_ready, answer_process)
                finally:
                    release_finalizer.set()
                self.assertTrue(finalizer.result(5)[1])
                attempt = answer.result(5)[0]
        final = FinalAnswer.objects.get(run=run, session_participant=g.link)
        self.assertIsNotNone(attempt)
        self.assertEqual(final.outcome, FinalAnswer.OUTCOME_UNANSWERED)
        self.assertIsNone(final.selected_attempt_id)

    def test_twenty_one_concurrent_unique_attempts_store_exactly_twenty(self):
        g = game(self.owner, active=True)
        barrier = Barrier(22)

        def simultaneous(submission_id):
            barrier.wait(timeout=5)
            return self.record(g, submission_id)

        ready = [Event() for _ in range(21)]
        processes = [[] for _ in range(21)]
        with ThreadPoolExecutor(max_workers=21) as pool:
            futures = [
                pool.submit(self.worker, ready[index], processes[index], lambda value=value: simultaneous(value))
                for index, value in enumerate(uuid.uuid4() for _ in range(21))
            ]
            barrier.wait(timeout=5)
            results = [future.result(15) for future in futures]
        self.assertEqual(sum(result[0] is not None for result in results), 20)
        self.assertEqual(AnswerAttempt.objects.filter(run=g.session.current_run).count(), 20)
        self.assertEqual(
            list(AnswerAttempt.objects.filter(run=g.session.current_run).order_by('ordinal').values_list('ordinal', flat=True)),
            list(range(1, 21)),
        )

    def test_concurrent_duplicate_attempt_uses_one_limit_slot(self):
        g = game(self.owner, active=True)
        submission_id = uuid.uuid4()
        barrier = Barrier(3)

        def simultaneous_duplicate():
            barrier.wait(timeout=5)
            return self.record(g, submission_id)

        first_ready, first_process = Event(), []
        second_ready, second_process = Event(), []
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.worker, first_ready, first_process, simultaneous_duplicate)
            second = pool.submit(self.worker, second_ready, second_process, simultaneous_duplicate)
            barrier.wait(timeout=5)
            results = [first.result(5), second.result(5)]
        self.assertEqual({repeated for _, repeated in results}, {False, True})
        self.assertEqual(AnswerAttempt.objects.filter(run=g.session.current_run).count(), 1)

    def test_for_share_locks_only_trusted_current_run_and_plan_is_indexed(self):
        first = game(self.owner, active=True)
        second = game(self.owner, active=True)
        blocked_ready, blocked_process = Event(), []
        free_ready, free_process = Event(), []
        with ThreadPoolExecutor(max_workers=2) as pool:
            with transaction.atomic():
                SessionQuestionRun.objects.select_for_update().get(pk=first.session.current_run_id)
                blocked = pool.submit(self.worker, blocked_ready, blocked_process, lambda: self.record(first))
                self.wait_for_lock(blocked_ready, blocked_process)
                free = pool.submit(self.worker, free_ready, free_process, lambda: self.record(second))
                self.assertIsNotNone(free.result(5)[0])
                self.assertFalse(blocked.done())
            self.assertIsNotNone(blocked.result(5)[0])

        with transaction.atomic(), connection.cursor() as cursor:
            cursor.execute('SET LOCAL enable_seqscan = off')
            cursor.execute(
                '''
                EXPLAIN (FORMAT JSON)
                SELECT run.id
                FROM session_sessionquestionrun AS run
                INNER JOIN session_livesession AS live ON live.current_run_id = run.id
                WHERE live.id = %s
                  AND live.current_run_id = run.id
                  AND run.session_id = live.id
                FOR SHARE OF run
                ''',
                [first.session.pk],
            )
            plan_text = str(cursor.fetchone()[0])
        self.assertIn('LockRows', plan_text)
        self.assertIn('Index Scan', plan_text)
        self.assertIn('session_sessionquestionrun', plan_text)

    def test_concurrent_duplicate_command_changes_state_once(self):
        g = game(self.owner)
        payload = command_payload(g.session)
        barrier = Barrier(3)

        def start_once():
            barrier.wait(timeout=5)
            return execute_manual_command(g.session.pk, 'start_session', {
                **payload,
                'command_id': uuid.UUID(payload['command_id']),
            })

        ready = [Event(), Event()]
        processes = [[], []]
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(self.worker, ready[index], processes[index], start_once)
                for index in range(2)
            ]
            barrier.wait(timeout=5)
            results = [future.result(5) for future in futures]
        g.session.refresh_from_db()
        self.assertEqual({repeated for _, repeated in results}, {False, True})
        self.assertEqual(g.session.state_revision, 1)
        self.assertEqual(SessionCommand.objects.filter(session=g.session).count(), 1)

    def test_timer_and_next_question_open_only_one_run(self):
        g = game(self.owner, active=True)
        first_run = g.session.current_run
        advance_session_if_due(g.session, now=first_run.delivery_deadline_at + timedelta(seconds=1))
        g.session.refresh_from_db()
        first_run.refresh_from_db()
        payload = command_payload(g.session)
        initial_revision = g.session.state_revision
        initial_commands = SessionCommand.objects.filter(session=g.session).count()
        barrier = Barrier(3)

        def manual_next():
            barrier.wait(timeout=5)
            try:
                return execute_manual_command(g.session.pk, 'next_question', {
                    **payload,
                    'command_id': uuid.UUID(payload['command_id']),
                })
            except Conflict:
                return 'conflict'

        def automatic_next():
            barrier.wait(timeout=5)
            return advance_session_if_due(g.session, now=first_run.results_ends_at)

        first_ready, first_process = Event(), []
        second_ready, second_process = Event(), []
        with patch('apps.session.gameplay.database_now', return_value=first_run.results_ends_at):
            with ThreadPoolExecutor(max_workers=2) as pool:
                manual = pool.submit(self.worker, first_ready, first_process, manual_next)
                automatic = pool.submit(self.worker, second_ready, second_process, automatic_next)
                barrier.wait(timeout=5)
                manual_result = manual.result(5)
                automatic_result = automatic.result(5)

        g.session.refresh_from_db()
        self.assertEqual(g.session.phase, LiveSession.PHASE_READING)
        self.assertEqual(g.session.current_question.order, 2)
        self.assertEqual(g.session.state_revision, initial_revision + 1)
        self.assertEqual(SessionQuestionRun.objects.filter(session=g.session).count(), 2)
        self.assertEqual(SessionCommand.objects.filter(session=g.session).count(), initial_commands + 1)
        self.assertTrue(manual_result == 'conflict' or manual_result[1] is False)
        self.assertTrue(automatic_result[1] is False or manual_result == 'conflict')

    def test_early_recovery_preflight_does_not_block_valid_answer(self):
        g = game(self.owner, active=True)
        run = g.session.current_run
        preflight_reached = Event()
        release_preflight = Event()
        recovery_ready, recovery_process = Event(), []
        answer_ready, answer_process = Event(), []

        def hold_preflight():
            preflight_reached.set()
            self.assertTrue(release_preflight.wait(5), 'Не освобождён предварительный этап чтения.')

        with patch(
            'apps.session.gameplay._advance_preflight_barrier',
            side_effect=hold_preflight,
            create=True,
        ):
            with ThreadPoolExecutor(max_workers=2) as pool:
                recovery = pool.submit(
                    self.worker,
                    recovery_ready,
                    recovery_process,
                    lambda: advance_session_if_due(
                        g.session,
                        now=run.answering_started_at + timedelta(seconds=1),
                    ),
                )
                if not preflight_reached.wait(2):
                    release_preflight.set()
                    recovery.result(5)
                    self.fail('Предварительная неблокирующая проверка не была выполнена.')
                answer = pool.submit(self.worker, answer_ready, answer_process, lambda: self.record(g))
                try:
                    self.assertIsNotNone(answer.result(5)[0])
                    self.assertFalse(recovery.done())
                finally:
                    release_preflight.set()
                _, advanced = recovery.result(5)

        self.assertFalse(advanced)
        g.session.refresh_from_db()
        self.assertEqual(g.session.phase, LiveSession.PHASE_ANSWERING)
        self.assertEqual(AnswerAttempt.objects.filter(run=run).count(), 1)

    def test_two_due_recovery_checks_finalize_once(self):
        g, run = self.past_deadline_game()
        initial_revision = g.session.state_revision
        initial_commands = SessionCommand.objects.filter(session=g.session).count()
        barrier = Barrier(3)
        due_at = run.delivery_deadline_at + timedelta(seconds=1)

        def recover():
            barrier.wait(timeout=5)
            return advance_session_if_due(g.session, now=due_at)

        ready = [Event(), Event()]
        processes = [[], []]
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(self.worker, ready[index], processes[index], recover)
                for index in range(2)
            ]
            barrier.wait(timeout=5)
            results = [future.result(10) for future in futures]

        g.session.refresh_from_db()
        run.refresh_from_db()
        self.assertEqual({advanced for _, advanced in results}, {False, True})
        self.assertEqual(g.session.phase, LiveSession.PHASE_RESULTS)
        self.assertEqual(g.session.state_revision, initial_revision + 1)
        self.assertEqual(SessionCommand.objects.filter(session=g.session).count(), initial_commands + 1)
        self.assertEqual(FinalAnswer.objects.filter(run=run).count(), 1)

    def test_supplied_now_keeps_early_recovery_deterministic(self):
        g = game(self.owner, active=True)
        run = g.session.current_run
        with patch('apps.session.gameplay.database_now', side_effect=AssertionError('Часы БД не нужны.')):
            session, advanced = advance_session_if_due(
                g.session,
                now=run.answering_started_at + timedelta(seconds=1),
            )
        self.assertFalse(advanced)
        self.assertEqual(session.phase, LiveSession.PHASE_ANSWERING)

    def test_concurrent_display_grants_leave_only_one_active(self):
        g = game(self.owner)
        ready = Barrier(2)

        def issue_display_grant():
            connections.close_all()
            try:
                client = APIClient()
                client.force_authenticate(self.owner)
                ready.wait(timeout=5)
                response = client.post(url(g.session, 'display-access'))
                return response.status_code, response.data['id']
            finally:
                connections.close_all()

        with ThreadPoolExecutor(max_workers=2) as pool:
            issued = list(pool.map(lambda _: issue_display_grant(), range(2)))

        self.assertEqual([status for status, _ in issued], [201, 201])
        grants = SessionDisplayAccess.objects.filter(session=g.session)
        self.assertEqual(grants.count(), 2)
        self.assertEqual(grants.filter(revoked_at__isnull=True).count(), 1)
        self.assertIn(
            str(grants.get(revoked_at__isnull=True).pk),
            [grant_id for _, grant_id in issued],
        )
