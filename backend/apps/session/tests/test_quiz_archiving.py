from copy import deepcopy
from datetime import timedelta
from unittest.mock import patch
import uuid

from django.contrib import admin
from django.contrib.auth import get_user_model
from django.db import connection
from django.test import RequestFactory, TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APITestCase

from apps.core.protection import HistoryConflict
from apps.quiz.models import Choice, Question, Quiz, QuizVersion
from apps.quiz.services import save_quiz_content, version_data
from apps.session.advance import advance_session_if_due
from apps.session.gameplay import record_answer_attempt
from apps.session.models import (
    AnswerAttempt,
    FinalAnswer,
    LiveSession,
    SessionParticipant,
)
from apps.session.services import create_live_session
from apps.session.tests.helpers import game, quiz, teacher


class QuizArchiveApiTests(APITestCase):
    def setUp(self):
        self.owner = teacher('archive-owner')
        self.other = teacher('archive-other')
        self.admin = get_user_model().objects.create_superuser(
            username='archive-admin',
            password='test-password-123',
        )
        self.client.force_authenticate(self.owner)

    def test_open_session_of_non_latest_version_blocks_archive_exactly(self):
        for session_status in (LiveSession.STATUS_WAITING, LiveSession.STATUS_LIVE):
            with self.subTest(status=session_status):
                content = quiz(self.owner, title=f'Открытая {session_status}')
                session = create_live_session(quiz_id=content.pk, actor=self.owner)
                fixed_version_id = session.quiz_version_id
                save_quiz_content(
                    quiz_id=content.pk,
                    actor=self.owner,
                    expected_revision=1,
                    data={'title': f'Новый черновик {session_status}'},
                )
                if session_status == LiveSession.STATUS_LIVE:
                    session.status = session_status
                    session.save(update_fields=['status'])

                response = self.client.post(f'/api/quizzes/{content.pk}/archive/')

                self.assertEqual(response.status_code, 409, response.data)
                self.assertEqual(response.data, {
                    'code': 'quiz_open_session_conflict',
                    'detail': 'Сначала завершите или остановите открытую сессию',
                })
                content.refresh_from_db()
                self.assertIsNone(content.archived_at)
                self.assertEqual(content.content_revision, 2)
                self.assertEqual(content.versions.count(), 2)
                self.assertEqual(
                    LiveSession.objects.get(pk=session.pk).quiz_version_id,
                    fixed_version_id,
                )

    def test_terminal_sessions_allow_idempotent_archive_restore_and_new_work(self):
        for terminal_status in (
            LiveSession.STATUS_FINISHED,
            LiveSession.STATUS_ABORTED,
        ):
            with self.subTest(status=terminal_status):
                content = quiz(self.owner, title=f'Терминальная {terminal_status}')
                session = create_live_session(quiz_id=content.pk, actor=self.owner)
                session.status = terminal_status
                session.save(update_fields=['status'])
                revision = content.content_revision
                version_ids = list(content.versions.values_list('pk', flat=True))

                archived = self.client.post(f'/api/quizzes/{content.pk}/archive/')
                self.assertEqual(archived.status_code, 200, archived.data)
                self.assertIsNotNone(archived.data['archived_at'])
                self.assertFalse(archived.data['can_delete'])
                archived_at = archived.data['archived_at']
                updated_at = archived.data['updated_at']

                repeated = self.client.post(f'/api/quizzes/{content.pk}/archive/')
                self.assertEqual(repeated.status_code, 200, repeated.data)
                self.assertEqual(repeated.data['archived_at'], archived_at)
                self.assertEqual(repeated.data['updated_at'], updated_at)
                self.assertEqual(repeated.data['content_revision'], revision)

                save_response = self.client.patch(
                    f'/api/quizzes/{content.pk}/',
                    {'content_revision': revision, 'title': 'Не записывать'},
                    format='json',
                )
                self.assertEqual(save_response.status_code, 409, save_response.data)
                self.assertEqual(save_response.data['code'], 'quiz_archived')
                session_response = self.client.post(
                    '/api/sessions/',
                    {'quiz': content.pk},
                    format='json',
                )
                self.assertEqual(session_response.status_code, 409, session_response.data)
                self.assertEqual(session_response.data['code'], 'quiz_archived')

                restored = self.client.post(f'/api/quizzes/{content.pk}/restore/')
                self.assertEqual(restored.status_code, 200, restored.data)
                self.assertIsNone(restored.data['archived_at'])
                restored_updated_at = restored.data['updated_at']
                repeated_restore = self.client.post(
                    f'/api/quizzes/{content.pk}/restore/'
                )
                self.assertEqual(repeated_restore.status_code, 200)
                self.assertEqual(repeated_restore.data['updated_at'], restored_updated_at)
                self.assertEqual(repeated_restore.data['content_revision'], revision)
                self.assertEqual(
                    list(content.versions.values_list('pk', flat=True)),
                    version_ids,
                )

                saved = self.client.patch(
                    f'/api/quizzes/{content.pk}/',
                    {'content_revision': revision, 'title': 'После восстановления'},
                    format='json',
                )
                self.assertEqual(saved.status_code, 200, saved.data)
                launched = self.client.post(
                    '/api/sessions/',
                    {'quiz': content.pk},
                    format='json',
                )
                self.assertEqual(launched.status_code, 201, launched.data)

    def test_lists_detail_permissions_and_can_delete_contract(self):
        active = quiz(self.owner, title='Рабочая')
        archived = quiz(self.owner, title='Архивная')
        archive_response = self.client.post(f'/api/quizzes/{archived.pk}/archive/')
        self.assertEqual(archive_response.status_code, 200, archive_response.data)

        default_list = self.client.get('/api/quizzes/')
        active_list = self.client.get('/api/quizzes/', {'archived': 'false'})
        archive_list = self.client.get('/api/quizzes/', {'archived': 'true'})
        self.assertEqual([item['id'] for item in default_list.data], [active.pk])
        self.assertEqual(active_list.data, default_list.data)
        self.assertEqual([item['id'] for item in archive_list.data], [archived.pk])
        self.assertTrue(default_list.data[0]['can_delete'])
        self.assertTrue(archive_list.data[0]['can_delete'])
        self.assertIsNone(default_list.data[0]['archived_at'])
        self.assertIsNotNone(archive_list.data[0]['archived_at'])
        self.assertEqual(
            self.client.get(f'/api/quizzes/{archived.pk}/').status_code,
            200,
        )
        self.assertEqual(
            self.client.get('/api/quizzes/', {'archived': 'all'}).status_code,
            400,
        )

        self.client.force_authenticate(self.other)
        for method, path in (
            ('post', f'/api/quizzes/{active.pk}/archive/'),
            ('post', f'/api/quizzes/{archived.pk}/restore/'),
            ('delete', f'/api/quizzes/{active.pk}/'),
        ):
            self.assertEqual(getattr(self.client, method)(path).status_code, 404)

        self.client.force_authenticate(self.admin)
        self.assertEqual(
            self.client.post(f'/api/quizzes/{active.pk}/archive/').status_code,
            200,
        )
        self.assertEqual(
            self.client.post(f'/api/quizzes/{active.pk}/restore/').status_code,
            200,
        )

    def test_delete_unused_cascades_and_used_card_is_fully_preserved(self):
        unused = quiz(self.owner, title='Неиспользованная')
        unused_version_ids = list(unused.versions.values_list('pk', flat=True))
        unused_question_ids = list(
            Question.objects.filter(quiz_version__quiz=unused).values_list('pk', flat=True)
        )
        unused_choice_ids = list(
            Choice.objects.filter(question__quiz_version__quiz=unused).values_list('pk', flat=True)
        )

        response = self.client.delete(f'/api/quizzes/{unused.pk}/')
        self.assertEqual(response.status_code, 204)
        self.assertFalse(Quiz.objects.filter(pk=unused.pk).exists())
        self.assertFalse(QuizVersion.objects.filter(pk__in=unused_version_ids).exists())
        self.assertFalse(Question.objects.filter(pk__in=unused_question_ids).exists())
        self.assertFalse(Choice.objects.filter(pk__in=unused_choice_ids).exists())

        used = game(self.owner)
        quiz_snapshot = Quiz.objects.values().get(pk=used.quiz.pk)
        version_snapshot = version_data(used.version)
        session_snapshot = LiveSession.objects.values().get(pk=used.session.pk)
        for actor in (self.owner, self.admin):
            with self.subTest(actor=actor.username):
                self.client.force_authenticate(actor)
                protected = self.client.delete(f'/api/quizzes/{used.quiz.pk}/')
                self.assertEqual(protected.status_code, 409, protected.data)
                self.assertEqual(protected.data['code'], 'quiz_history_protected')
                self.assertEqual(
                    Quiz.objects.values().get(pk=used.quiz.pk),
                    quiz_snapshot,
                )
                self.assertEqual(version_data(used.version), version_snapshot)
                self.assertEqual(
                    LiveSession.objects.values().get(pk=used.session.pk),
                    session_snapshot,
                )

    def test_can_delete_uses_one_exists_annotation_for_the_whole_list(self):
        unused = quiz(self.owner, title='Без запусков')

        def load_list():
            with CaptureQueriesContext(connection) as captured:
                response = self.client.get('/api/quizzes/')
            self.assertEqual(response.status_code, 200, response.data)
            selects = [
                query['sql']
                for query in captured.captured_queries
                if query['sql'].lstrip().upper().startswith('SELECT')
            ]
            return response, selects

        _, baseline_selects = load_list()
        used_ids = []
        for index in range(5):
            content = quiz(self.owner, title=f'С запуском {index}')
            create_live_session(quiz_id=content.pk, actor=self.owner)
            used_ids.append(content.pk)
        response, expanded_selects = load_list()

        self.assertEqual(len(expanded_selects), len(baseline_selects))
        self.assertTrue(any('EXISTS' in sql.upper() for sql in expanded_selects))
        by_id = {item['id']: item['can_delete'] for item in response.data}
        self.assertTrue(by_id[unused.pk])
        self.assertTrue(all(by_id[quiz_id] is False for quiz_id in used_ids))

    def test_archive_and_restore_leave_answers_ranking_and_csv_unchanged(self):
        for terminal_status in (
            LiveSession.STATUS_FINISHED,
            LiveSession.STATUS_ABORTED,
        ):
            with self.subTest(status=terminal_status):
                historical = game(
                    self.owner,
                    active=True,
                    title=f'История {terminal_status}',
                )
                run = historical.session.current_run
                record_answer_attempt(
                    session_id=historical.session.pk,
                    participation_id=historical.link.pk,
                    question_id=historical.question.pk,
                    choice_id=historical.correct.pk,
                    submission_id=uuid.uuid4(),
                )
                advance_session_if_due(
                    historical.session,
                    now=run.delivery_deadline_at + timedelta(seconds=1),
                )
                historical.session.refresh_from_db()
                historical.session.status = terminal_status
                historical.session.phase = LiveSession.PHASE_FINAL
                historical.session.current_question = None
                historical.session.current_run = None
                historical.session.save()

                def history_snapshot():
                    fresh_version = QuizVersion.objects.get(pk=historical.version.pk)
                    detail = self.client.get(
                        f'/api/sessions/{historical.session.join_token}/'
                    )
                    sessions = self.client.get('/api/sessions/')
                    leaderboard = self.client.get(
                        f'/api/sessions/{historical.session.join_token}/leaderboard/'
                    )
                    export = self.client.get(
                        f'/api/sessions/{historical.session.join_token}/results/export/'
                    )

                    self.assertEqual(detail.status_code, 200, detail.data)
                    self.assertEqual(sessions.status_code, 200, sessions.data)
                    self.assertEqual(leaderboard.status_code, 200, leaderboard.data)
                    self.assertEqual(export.status_code, 200)
                    self.assertEqual(detail.data['id'], str(historical.session.join_token))
                    self.assertEqual(detail.data['quiz']['id'], historical.quiz.pk)
                    self.assertEqual(detail.data['status'], terminal_status)
                    self.assertEqual(detail.data['participants_count'], 1)
                    listed = next(
                        item
                        for item in sessions.data
                        if item['id'] == str(historical.session.join_token)
                    )
                    self.assertEqual(listed['quiz']['title'], f'История {terminal_status}')
                    self.assertEqual(len(leaderboard.data), 1)
                    self.assertEqual(
                        leaderboard.data[0]['participant_name'],
                        'Участник',
                    )
                    self.assertEqual(leaderboard.data[0]['correct_answers'], 1)
                    self.assertIn('Участник', export.content.decode('utf-8-sig'))

                    return {
                        'version': QuizVersion.objects.values().get(
                            pk=fresh_version.pk
                        ),
                        'content': deepcopy(version_data(fresh_version)),
                        'questions': list(
                            Question.objects.filter(quiz_version=fresh_version)
                            .order_by('pk')
                            .values()
                        ),
                        'choices': list(
                            Choice.objects.filter(
                                question__quiz_version=fresh_version,
                            )
                            .order_by('pk')
                            .values()
                        ),
                        'session': LiveSession.objects.values().get(
                            pk=historical.session.pk
                        ),
                        'participations': list(
                            SessionParticipant.objects.filter(
                                session=historical.session,
                            )
                            .order_by('pk')
                            .values()
                        ),
                        'attempts': list(
                            AnswerAttempt.objects.filter(
                                run__session=historical.session,
                            )
                            .order_by('pk')
                            .values()
                        ),
                        'final_answers': list(
                            FinalAnswer.objects.filter(run=run)
                            .order_by('pk')
                            .values()
                        ),
                        'detail': deepcopy(detail.data),
                        'listed': deepcopy(listed),
                        'leaderboard': deepcopy(leaderboard.data),
                        'csv': export.content,
                    }

                before_archive = history_snapshot()
                archive_response = self.client.post(
                    f'/api/quizzes/{historical.quiz.pk}/archive/'
                )
                self.assertEqual(archive_response.status_code, 200, archive_response.data)
                self.assertIsNotNone(archive_response.data['archived_at'])

                while_archived = history_snapshot()
                self.assertEqual(while_archived, before_archive)

                restore_response = self.client.post(
                    f'/api/quizzes/{historical.quiz.pk}/restore/'
                )
                self.assertEqual(restore_response.status_code, 200, restore_response.data)
                self.assertIsNone(restore_response.data['archived_at'])

                after_restore = history_snapshot()
                self.assertEqual(after_restore, before_archive)


class QuizArchiveProtectionAndAdminTests(TestCase):
    def setUp(self):
        self.owner = teacher('archive-protection-owner')
        self.admin_user = get_user_model().objects.create_superuser(
            username='archive-protection-admin',
            password='test-password-123',
        )

    def test_direct_and_bulk_writes_cannot_archive_or_restore(self):
        content = quiz(self.owner)
        original_updated_at = content.updated_at
        content.archived_at = timezone.now()
        with self.assertRaises(HistoryConflict):
            content.save(update_fields=['archived_at', 'updated_at'])
        with self.assertRaises(HistoryConflict):
            Quiz.objects.filter(pk=content.pk).update(archived_at=timezone.now())
        content.refresh_from_db()
        self.assertIsNone(content.archived_at)
        self.assertEqual(content.updated_at, original_updated_at)

    def test_admin_actions_use_domain_rules_and_do_not_partially_delete(self):
        unused = quiz(self.owner, title='Удаляемая')
        blocked = game(self.owner)
        request = RequestFactory().post('/admin/quiz/quiz/')
        request.user = self.admin_user
        model_admin = admin.site._registry[Quiz]

        with patch.object(model_admin, 'message_user') as message_user:
            model_admin.archive_selected(
                request,
                Quiz.objects.filter(pk__in=[blocked.quiz.pk, unused.pk]),
            )
        blocked.quiz.refresh_from_db()
        unused.refresh_from_db()
        self.assertIsNone(blocked.quiz.archived_at)
        self.assertIsNone(unused.archived_at)
        self.assertIn('Сначала завершите', message_user.call_args.args[1])

        blocked.session.status = LiveSession.STATUS_FINISHED
        blocked.session.save(update_fields=['status'])
        with patch.object(model_admin, 'message_user'):
            model_admin.archive_selected(
                request,
                Quiz.objects.filter(pk__in=[blocked.quiz.pk, unused.pk]),
            )
        blocked.quiz.refresh_from_db()
        unused.refresh_from_db()
        self.assertIsNotNone(blocked.quiz.archived_at)
        self.assertIsNotNone(unused.archived_at)

        with patch.object(model_admin, 'message_user'):
            model_admin.restore_selected(
                request,
                Quiz.objects.filter(pk__in=[blocked.quiz.pk, unused.pk]),
            )
        blocked.quiz.refresh_from_db()
        unused.refresh_from_db()
        self.assertIsNone(blocked.quiz.archived_at)
        self.assertIsNone(unused.archived_at)

        with patch.object(model_admin, 'message_user'):
            model_admin.delete_unused_selected(
                request,
                Quiz.objects.filter(pk__in=[blocked.quiz.pk, unused.pk]),
            )
        self.assertTrue(Quiz.objects.filter(pk=blocked.quiz.pk).exists())
        self.assertTrue(Quiz.objects.filter(pk=unused.pk).exists())

        with patch.object(model_admin, 'message_user'):
            model_admin.delete_unused_selected(
                request,
                Quiz.objects.filter(pk=unused.pk),
            )
        self.assertFalse(Quiz.objects.filter(pk=unused.pk).exists())
        self.assertTrue(Quiz.objects.filter(pk=blocked.quiz.pk).exists())
