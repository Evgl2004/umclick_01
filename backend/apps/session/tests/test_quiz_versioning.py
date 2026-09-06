from copy import deepcopy
from datetime import timedelta
from unittest.mock import patch
import uuid

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient, APITestCase
from rest_framework.exceptions import PermissionDenied

from apps.core.errors import Conflict, QuizRevisionConflict
from apps.core.protection import HistoryConflict
from apps.quiz.models import Choice, Question, Quiz, QuizVersion
from apps.quiz.services import (
    _quiz_content_write,
    create_quiz_with_draft,
    get_effective_version,
    save_quiz_content,
    version_data,
)
from apps.session.advance import advance_session_if_due
from apps.session.gameplay import record_answer_attempt
from apps.session.models import AnswerAttempt, FinalAnswer, LiveSession
from apps.session.services import create_live_session
from apps.session.tests.helpers import game, quiz, quiz_payload, teacher


class QuizVersioningServiceTests(TestCase):
    def setUp(self):
        self.owner = teacher('versioning-owner')

    def test_create_builds_one_draft_and_direct_writes_are_rejected(self):
        content = quiz(self.owner)
        version = content.versions.get()

        self.assertEqual(content.content_revision, 1)
        self.assertEqual((version.number, version.status, version.fixed_at), (1, 'draft', None))
        self.assertEqual(version.questions.count(), 2)
        self.assertEqual(Choice.objects.filter(question__quiz_version=version).count(), 4)

        with self.assertRaises(HistoryConflict):
            Quiz.objects.create(owner=self.owner)
        with self.assertRaises(HistoryConflict):
            QuizVersion.objects.create(quiz=content, number=2, title='Обход')
        with self.assertRaises(HistoryConflict):
            Question.objects.create(quiz_version=version, text='Обход')
        with self.assertRaises(HistoryConflict):
            Choice.objects.create(question=version.questions.first(), text='Обход')
        with self.assertRaises(HistoryConflict):
            LiveSession.objects.create(quiz_version=version, created_by=self.owner)
        with self.assertRaises(HistoryConflict):
            version.questions.all().delete()

    def test_identical_save_is_noop_and_stale_identical_save_conflicts(self):
        content = quiz(self.owner)
        draft = content.versions.get()
        original = version_data(draft)
        question_ids = list(draft.questions.values_list('id', flat=True))
        choice_ids = list(
            Choice.objects.filter(question__quiz_version=draft).values_list('id', flat=True)
        )
        revision = content.content_revision
        quiz_updated_at = content.updated_at
        version_updated_at = draft.updated_at

        save_quiz_content(
            quiz_id=content.pk,
            actor=self.owner,
            expected_revision=revision,
            data=deepcopy(original),
        )
        content.refresh_from_db()
        draft.refresh_from_db()
        self.assertEqual(content.content_revision, revision)
        self.assertEqual(content.updated_at, quiz_updated_at)
        self.assertEqual(draft.updated_at, version_updated_at)
        self.assertEqual(list(draft.questions.values_list('id', flat=True)), question_ids)
        self.assertEqual(
            list(Choice.objects.filter(question__quiz_version=draft).values_list('id', flat=True)),
            choice_ids,
        )

        changed = deepcopy(original)
        changed['title'] = 'Новая редакция'
        save_quiz_content(
            quiz_id=content.pk,
            actor=self.owner,
            expected_revision=revision,
            data=changed,
        )
        with self.assertRaises(QuizRevisionConflict):
            save_quiz_content(
                quiz_id=content.pk,
                actor=self.owner,
                expected_revision=revision,
                data=changed,
            )

    def test_changed_draft_is_updated_in_place_with_same_child_ids(self):
        content = quiz(self.owner)
        draft = content.versions.get()
        data = version_data(draft)
        version_id = draft.pk
        question_ids = [question['id'] for question in data['questions']]
        choice_ids = [
            choice['id']
            for question in data['questions']
            for choice in question['choices']
        ]
        data['title'] = 'Изменённый черновик'
        data['questions'][0]['text'] = 'Изменённый вопрос'

        save_quiz_content(
            quiz_id=content.pk,
            actor=self.owner,
            expected_revision=1,
            data=data,
        )

        content.refresh_from_db()
        draft = content.versions.get()
        current = version_data(draft)
        self.assertEqual((draft.pk, content.content_revision), (version_id, 2))
        self.assertEqual([question['id'] for question in current['questions']], question_ids)
        self.assertEqual(
            [choice['id'] for question in current['questions'] for choice in question['choices']],
            choice_ids,
        )

    def test_partial_save_normalizes_new_items_and_preserves_existing_fields(self):
        content = quiz(self.owner)
        original = version_data(content.versions.get())
        second_question = original['questions'][1]

        save_quiz_content(
            quiz_id=content.pk,
            actor=self.owner,
            expected_revision=1,
            data={
                'questions': [
                    {
                        'id': original['questions'][0]['id'],
                        'text': 'Частично изменённый вопрос',
                    },
                    {'id': second_question['id']},
                    {
                        'text': 'Новый вопрос',
                        'choices': [
                            {'text': 'Да', 'is_correct': True},
                            {'text': 'Нет'},
                        ],
                    },
                ],
            },
        )

        content.refresh_from_db()
        current = version_data(content.versions.get(status='draft'))
        self.assertEqual(content.content_revision, 2)
        self.assertEqual(current['questions'][0]['text'], 'Частично изменённый вопрос')
        self.assertEqual(
            current['questions'][0]['time_limit_sec'],
            original['questions'][0]['time_limit_sec'],
        )
        self.assertEqual(
            current['questions'][0]['choices'],
            original['questions'][0]['choices'],
        )
        self.assertEqual(current['questions'][1], second_question)
        self.assertEqual(current['questions'][2]['time_limit_sec'], 20)
        self.assertEqual(
            [choice['is_correct'] for choice in current['questions'][2]['choices']],
            [True, False],
        )

        revision = content.content_revision
        updated_at = content.updated_at
        save_quiz_content(
            quiz_id=content.pk,
            actor=self.owner,
            expected_revision=revision,
            data={'questions': deepcopy(current['questions'])},
        )
        content.refresh_from_db()
        self.assertEqual(content.content_revision, revision)
        self.assertEqual(content.updated_at, updated_at)

    def test_invalid_partial_content_does_not_change_graph_or_revision(self):
        content = quiz(self.owner)
        draft = content.versions.get()
        original = version_data(draft)

        with self.assertRaises(ValidationError):
            save_quiz_content(
                quiz_id=content.pk,
                actor=self.owner,
                expected_revision=1,
                data={
                    'questions': [{
                        'text': 'Ошибочный вопрос',
                        'choices': [{'text': 'Да'}, {'text': 'Нет'}],
                    }],
                },
            )

        content.refresh_from_db()
        draft.refresh_from_db()
        self.assertEqual(content.content_revision, 1)
        self.assertEqual(version_data(draft), original)

    def test_identical_save_without_draft_reuses_fixed_version_without_writes(self):
        fixed_game = game(self.owner)
        fixed = fixed_game.version
        content_updated_at = fixed_game.quiz.updated_at
        version_updated_at = fixed.updated_at

        save_quiz_content(
            quiz_id=fixed_game.quiz.pk,
            actor=self.owner,
            expected_revision=1,
            data=version_data(fixed),
        )

        fixed_game.quiz.refresh_from_db()
        fixed.refresh_from_db()
        self.assertEqual(fixed_game.quiz.content_revision, 1)
        self.assertEqual(fixed_game.quiz.updated_at, content_updated_at)
        self.assertEqual(fixed.updated_at, version_updated_at)
        self.assertEqual(fixed_game.quiz.versions.count(), 1)
        self.assertFalse(fixed_game.quiz.versions.filter(status='draft').exists())

    def test_first_change_after_fix_creates_new_ids_and_keeps_session_history(self):
        first_game = game(self.owner)
        fixed = first_game.version
        fixed_snapshot = version_data(fixed)
        fixed_question_ids = {item['id'] for item in fixed_snapshot['questions']}
        fixed_choice_ids = {
            choice['id']
            for question in fixed_snapshot['questions']
            for choice in question['choices']
        }

        save_quiz_content(
            quiz_id=first_game.quiz.pk,
            actor=self.owner,
            expected_revision=1,
            data={'title': 'Следующий черновик'},
        )

        draft = first_game.quiz.versions.get(status='draft')
        draft_data = version_data(draft)
        self.assertEqual(first_game.quiz.versions.count(), 2)
        self.assertTrue(fixed_question_ids.isdisjoint(
            {item['id'] for item in draft_data['questions']}
        ))
        self.assertTrue(fixed_choice_ids.isdisjoint({
            choice['id']
            for question in draft_data['questions']
            for choice in question['choices']
        }))
        fixed.refresh_from_db()
        first_game.session.refresh_from_db()
        self.assertEqual(version_data(fixed), fixed_snapshot)
        self.assertEqual(first_game.session.quiz_version_id, fixed.pk)

        second = create_live_session(quiz_id=first_game.quiz.pk, actor=self.owner)
        draft.refresh_from_db()
        self.assertEqual(draft.status, 'fixed')
        self.assertEqual(second.quiz_version_id, draft.pk)
        self.assertEqual(first_game.session.quiz_version_id, fixed.pk)

    def test_equal_draft_reuses_latest_fixed_and_remains_a_draft(self):
        first_game = game(self.owner)
        fixed_data = version_data(first_game.version)
        save_quiz_content(
            quiz_id=first_game.quiz.pk,
            actor=self.owner,
            expected_revision=1,
            data={'title': 'Временно отличается'},
        )
        for question in fixed_data['questions']:
            question.pop('id')
            for choice in question['choices']:
                choice.pop('id')
        save_quiz_content(
            quiz_id=first_game.quiz.pk,
            actor=self.owner,
            expected_revision=2,
            data=fixed_data,
        )
        draft = first_game.quiz.versions.get(status='draft')

        second = create_live_session(quiz_id=first_game.quiz.pk, actor=self.owner)

        draft.refresh_from_db()
        self.assertEqual(second.quiz_version_id, first_game.version.pk)
        self.assertEqual(draft.status, 'draft')
        self.assertIsNone(draft.fixed_at)

    def test_pin_failure_rolls_back_version_fixing(self):
        blocker = game(self.owner)
        target = quiz(self.owner)
        draft = target.versions.get()

        with patch('apps.session.models.generate_pin', return_value=blocker.session.pin):
            with self.assertRaises(HistoryConflict):
                create_live_session(quiz_id=target.pk, actor=self.owner)

        draft.refresh_from_db()
        self.assertEqual(draft.status, 'draft')
        self.assertIsNone(draft.fixed_at)
        self.assertFalse(LiveSession.objects.filter(quiz_version=draft).exists())

    def test_role_checks_are_identical_for_supported_services(self):
        plain = get_user_model().objects.create_user(
            username='versioning-plain',
            password='test-password-123',
        )
        with self.assertRaises(PermissionDenied):
            create_quiz_with_draft(actor=plain, data=quiz_payload())
        self.assertFalse(Quiz.objects.filter(owner=plain).exists())

        content = quiz(self.owner)
        original = version_data(content.versions.get())
        self.owner.groups.clear()
        with self.assertRaises(PermissionDenied):
            save_quiz_content(
                quiz_id=content.pk,
                actor=self.owner,
                expected_revision=1,
                data={'title': 'Запрещённая запись'},
            )
        with self.assertRaises(PermissionDenied):
            create_live_session(quiz_id=content.pk, actor=self.owner)

        other = teacher('versioning-role-other')
        with self.assertRaises(PermissionDenied):
            save_quiz_content(
                quiz_id=content.pk,
                actor=other,
                expected_revision=1,
                data={'title': 'Чужая запись'},
            )
        with self.assertRaises(PermissionDenied):
            create_live_session(quiz_id=content.pk, actor=other)

        content.refresh_from_db()
        self.assertEqual(content.content_revision, 1)
        self.assertEqual(version_data(content.versions.get()), original)
        self.assertEqual(content.versions.get().status, 'draft')
        self.assertFalse(LiveSession.objects.filter(quiz_version__quiz=content).exists())

        admin = get_user_model().objects.create_superuser(
            username='versioning-role-admin',
            password='test-password-123',
        )
        save_quiz_content(
            quiz_id=content.pk,
            actor=admin,
            expected_revision=1,
            data={'title': 'Изменено администратором'},
        )
        session = create_live_session(quiz_id=content.pk, actor=admin)
        self.assertEqual(session.quiz_version.title, 'Изменено администратором')

        owned = quiz(other)
        save_quiz_content(
            quiz_id=owned.pk,
            actor=other,
            expected_revision=1,
            data={'title': 'Изменено владельцем'},
        )
        self.assertEqual(
            create_live_session(quiz_id=owned.pk, actor=other).quiz_version.title,
            'Изменено владельцем',
        )

    def test_save_rolls_back_partial_draft_update_and_allows_retry(self):
        content = quiz(self.owner)
        draft = content.versions.get()
        original = version_data(draft)
        changed = deepcopy(original)
        changed['title'] = 'Атомарный черновик'
        changed['questions'][0]['text'] = 'Изменение до сбоя'
        changed['questions'][0]['choices'][0]['text'] = 'Вариант до сбоя'
        original_choice_save = Choice.save
        calls = 0

        def fail_after_first_choice(choice, *args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise RuntimeError('Управляемый сбой после дочерних записей')
            return original_choice_save(choice, *args, **kwargs)

        with patch.object(Choice, 'save', fail_after_first_choice):
            with self.assertRaisesMessage(RuntimeError, 'Управляемый сбой'):
                save_quiz_content(
                    quiz_id=content.pk,
                    actor=self.owner,
                    expected_revision=1,
                    data=changed,
                )

        content.refresh_from_db()
        draft.refresh_from_db()
        self.assertEqual(content.content_revision, 1)
        self.assertEqual(version_data(draft), original)

        save_quiz_content(
            quiz_id=content.pk,
            actor=self.owner,
            expected_revision=1,
            data=changed,
        )
        content.refresh_from_db()
        draft.refresh_from_db()
        self.assertEqual(content.content_revision, 2)
        self.assertEqual(version_data(draft)['title'], 'Атомарный черновик')

    def test_save_rolls_back_new_draft_graph_and_allows_retry(self):
        fixed_game = game(self.owner)
        fixed_snapshot = version_data(fixed_game.version)
        changed = deepcopy(fixed_snapshot)
        changed['title'] = 'Новый атомарный черновик'
        changed['questions'][0]['text'] = 'Новый вопрос после фиксации'
        original_question_save = Question.save
        calls = 0

        def fail_after_version(question, *args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise RuntimeError('Управляемый сбой внутри нового графа')
            return original_question_save(question, *args, **kwargs)

        with patch.object(Question, 'save', fail_after_version):
            with self.assertRaisesMessage(RuntimeError, 'Управляемый сбой'):
                save_quiz_content(
                    quiz_id=fixed_game.quiz.pk,
                    actor=self.owner,
                    expected_revision=1,
                    data=changed,
                )

        fixed_game.quiz.refresh_from_db()
        self.assertEqual(fixed_game.quiz.content_revision, 1)
        self.assertEqual(fixed_game.quiz.versions.count(), 1)
        self.assertEqual(version_data(fixed_game.version), fixed_snapshot)

        save_quiz_content(
            quiz_id=fixed_game.quiz.pk,
            actor=self.owner,
            expected_revision=1,
            data=changed,
        )
        fixed_game.quiz.refresh_from_db()
        self.assertEqual(fixed_game.quiz.content_revision, 2)
        self.assertEqual(fixed_game.quiz.versions.count(), 2)
        self.assertEqual(
            fixed_game.quiz.versions.get(status='draft').title,
            'Новый атомарный черновик',
        )

    def test_history_answers_results_and_csv_keep_fixed_content_after_full_edit(self):
        historical = game(self.owner, active=True)
        run = historical.session.current_run
        attempt, _ = record_answer_attempt(
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
        final = FinalAnswer.objects.get(
            run=run,
            session_participant=historical.link,
        )
        version_snapshot = version_data(historical.version)
        attempt_snapshot = AnswerAttempt.objects.values().get(pk=attempt.pk)
        final_snapshot = FinalAnswer.objects.values().get(pk=final.pk)

        api = APIClient()
        api.force_authenticate(self.owner)
        leaderboard_before = api.get(
            f'/api/sessions/{historical.session.join_token}/leaderboard/'
        ).json()
        csv_before = api.get(
            f'/api/sessions/{historical.session.join_token}/results/export/'
        ).content

        changed = deepcopy(version_snapshot)
        changed.update(
            title='Новая карточка',
            description='Новое описание',
            question_only_on_display=True,
            show_choices_on_participant=False,
            reading_time_sec=25,
            results_time_sec=20,
        )
        changed['questions'][0]['text'] = 'Новый текст вопроса'
        changed['questions'][0]['time_limit_sec'] = 45
        changed['questions'][0]['choices'][0]['text'] = 'Новый вариант'
        save_quiz_content(
            quiz_id=historical.quiz.pk,
            actor=self.owner,
            expected_revision=1,
            data=changed,
        )

        historical.session.refresh_from_db()
        self.assertEqual(historical.session.quiz_version_id, historical.version.pk)
        self.assertEqual(version_data(historical.version), version_snapshot)
        self.assertEqual(AnswerAttempt.objects.values().get(pk=attempt.pk), attempt_snapshot)
        self.assertEqual(FinalAnswer.objects.values().get(pk=final.pk), final_snapshot)
        self.assertEqual(
            api.get(f'/api/sessions/{historical.session.join_token}/leaderboard/').json(),
            leaderboard_before,
        )
        self.assertEqual(
            api.get(
                f'/api/sessions/{historical.session.join_token}/results/export/'
            ).content,
            csv_before,
        )

    def test_select_count_does_not_grow_with_children_or_history(self):
        def select_count(operation):
            with CaptureQueriesContext(connection) as captured:
                operation()
            return sum(
                query['sql'].lstrip().upper().startswith('SELECT')
                for query in captured.captured_queries
            )

        small = quiz(self.owner)
        small_data = version_data(small.versions.get())
        small_save_selects = select_count(lambda: save_quiz_content(
            quiz_id=small.pk,
            actor=self.owner,
            expected_revision=1,
            data=small_data,
        ))
        create_live_session(quiz_id=small.pk, actor=self.owner)
        small_session_selects = select_count(lambda: create_live_session(
            quiz_id=small.pk,
            actor=self.owner,
        ))

        many_questions = [
            {
                'text': f'Вопрос {index}',
                'choices': [
                    {
                        'text': f'Вариант {index}-{choice}',
                        'is_correct': choice == 0,
                    }
                    for choice in range(6)
                ],
            }
            for index in range(8)
        ]
        historical = quiz(self.owner, questions=many_questions)
        for number in range(5):
            create_live_session(quiz_id=historical.pk, actor=self.owner)
            historical.refresh_from_db()
            save_quiz_content(
                quiz_id=historical.pk,
                actor=self.owner,
                expected_revision=historical.content_revision,
                data={'title': f'История {number}'},
            )
        create_live_session(quiz_id=historical.pk, actor=self.owner)
        historical.refresh_from_db()
        effective_data = version_data(
            historical.versions.order_by('-number').first()
        )
        large_save_selects = select_count(lambda: save_quiz_content(
            quiz_id=historical.pk,
            actor=self.owner,
            expected_revision=historical.content_revision,
            data=effective_data,
        ))
        session_selects = select_count(lambda: create_live_session(
            quiz_id=historical.pk,
            actor=self.owner,
        ))

        self.assertEqual(large_save_selects, small_save_selects)
        self.assertEqual(session_selects, small_session_selects)

        with CaptureQueriesContext(connection) as captured:
            effective = get_effective_version(historical)
            self.assertEqual(len(version_data(effective)['questions']), 8)
        self.assertEqual(
            sum(
                query['sql'].lstrip().upper().startswith('SELECT')
                for query in captured.captured_queries
            ),
            3,
        )

    def test_rights_archive_and_nested_identifier_checks_precede_writes(self):
        other = teacher('versioning-other')
        content = quiz(self.owner)
        foreign = quiz(self.owner)
        original_revision = content.content_revision

        with self.assertRaises(ValidationError):
            save_quiz_content(
                quiz_id=content.pk,
                actor=self.owner,
                expected_revision=original_revision,
                data={'questions': [{'id': foreign.versions.get().questions.first().pk}]},
            )
        self.assertEqual(content.versions.count(), 1)

        with self.assertRaises(PermissionDenied):
            save_quiz_content(
                quiz_id=content.pk,
                actor=other,
                expected_revision=original_revision,
                data={'title': 'Чужая запись'},
            )

        with _quiz_content_write():
            content.archived_at = content.updated_at
            content.save(update_fields=['archived_at', 'updated_at'])
        with self.assertRaises(Conflict):
            save_quiz_content(
                quiz_id=content.pk,
                actor=self.owner,
                expected_revision=original_revision,
                data={'title': 'Архивная запись'},
            )
        with self.assertRaises(Conflict):
            create_live_session(quiz_id=content.pk, actor=self.owner)


class QuizVersioningApiTests(APITestCase):
    def setUp(self):
        self.owner = teacher('versioning-api-owner')
        self.client.force_authenticate(self.owner)

    def test_api_keeps_stable_shape_and_reports_stale_revision(self):
        created = self.client.post('/api/quizzes/', quiz_payload(), format='json')
        self.assertEqual(created.status_code, 201, created.data)
        self.assertEqual(created.data['content_revision'], 1)
        self.assertNotIn('versions', created.data)
        self.assertIn('id', created.data['questions'][0])
        self.assertIn('id', created.data['questions'][0]['choices'][0])

        changed = deepcopy(created.data)
        changed['title'] = 'Сохранено другим окном'
        saved = self.client.put(
            f"/api/quizzes/{created.data['id']}/",
            changed,
            format='json',
        )
        self.assertEqual(saved.status_code, 200, saved.data)
        stale = self.client.put(
            f"/api/quizzes/{created.data['id']}/",
            created.data,
            format='json',
        )
        self.assertEqual(stale.status_code, 409, stale.data)
        self.assertEqual(
            stale.data,
            {
                'code': 'quiz_revision_conflict',
                'detail': 'Викторина уже изменена. Обновите данные и повторите сохранение.',
                'current_content_revision': 2,
            },
        )

    def test_patch_normalizes_optional_nested_defaults_and_invalid_body_is_atomic(self):
        created = self.client.post('/api/quizzes/', quiz_payload(), format='json')
        response = self.client.patch(
            f"/api/quizzes/{created.data['id']}/",
            {
                'content_revision': 1,
                'questions': [{
                    'text': 'Новый вопрос',
                    'choices': [
                        {'text': 'Да', 'is_correct': True},
                        {'text': 'Нет'},
                    ],
                }],
            },
            format='json',
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['questions'][0]['time_limit_sec'], 20)
        self.assertEqual(
            [choice['is_correct'] for choice in response.data['questions'][0]['choices']],
            [True, False],
        )

        invalid = self.client.patch(
            f"/api/quizzes/{created.data['id']}/",
            {
                'content_revision': 2,
                'questions': [{
                    'text': 'Ошибочный вопрос',
                    'choices': [{'text': 'Да'}, {'text': 'Нет'}],
                }],
            },
            format='json',
        )
        self.assertEqual(invalid.status_code, 400, invalid.data)
        stored = self.client.get(f"/api/quizzes/{created.data['id']}/")
        self.assertEqual(stored.data, response.data)

    def test_quiz_list_select_count_does_not_grow_with_version_history(self):
        content = quiz(self.owner)
        self.client.get('/api/quizzes/')

        def list_result():
            with CaptureQueriesContext(connection) as captured:
                response = self.client.get('/api/quizzes/')
            self.assertEqual(response.status_code, 200, response.data)
            selects = [
                query['sql']
                for query in captured.captured_queries
                if query['sql'].lstrip().upper().startswith('SELECT')
            ]
            return response, selects

        _, baseline_selects = list_result()
        for number in range(5):
            create_live_session(quiz_id=content.pk, actor=self.owner)
            content.refresh_from_db()
            save_quiz_content(
                quiz_id=content.pk,
                actor=self.owner,
                expected_revision=content.content_revision,
                data={'title': f'Версия списка {number}'},
            )
        content.refresh_from_db()
        response, historical_selects = list_result()

        self.assertEqual(len(historical_selects), len(baseline_selects))
        self.assertEqual(response.data[0]['title'], 'Версия списка 4')
        self.assertTrue(any('ROW_NUMBER()' in sql for sql in historical_selects))
