from copy import deepcopy
from datetime import timedelta
from unittest.mock import patch
from django.contrib.auth import get_user_model
from django.contrib.admin.sites import site
from django.db import IntegrityError, transaction
from django.db.models.deletion import ProtectedError
from django.test import RequestFactory
from django.utils import timezone
from rest_framework.test import APITestCase

from apps.core.protection import HistoryConflict
from apps.quiz.models import Choice, Question, Quiz, QuizVersion
from apps.session.access import issue_secret
from apps.session.models import LegacyParticipantAnswer, LiveSession, Participant, SessionParticipant, SessionDisplayAccess

ParticipantAnswer = LegacyParticipantAnswer
from apps.session.tests.helpers import teacher, quiz, game, participate, url, quiz_payload


class StageAAccessTests(APITestCase):
    def setUp(self):
        self.owner = teacher()
        self.other = teacher('other')
        self.client.force_authenticate(self.owner)

    def test_registration_never_grants_administrator(self):
        self.client.force_authenticate(None)
        response = self.client.post('/api/auth/register/', {'username': 'new', 'password': 'test-password-123', 'is_staff': True, 'is_superuser': True})
        self.assertEqual(response.status_code, 201, response.data)
        user = get_user_model().objects.get(username='new')
        self.assertFalse(user.is_staff or user.is_superuser)
        self.assertTrue(user.groups.filter(name='teacher').exists())

    def test_owner_and_all_session_actions_are_scoped(self):
        g = game(self.other)
        self.assertEqual(self.client.get('/api/quizzes/').data, [])
        for action in ('state', 'leaderboard', 'results/export'):
            self.assertEqual(self.client.get(url(g.session, action)).status_code, 404)
        for action in ('start', 'finish', 'next-question', 'reveal-answer', 'display-access'):
            self.assertEqual(self.client.post(url(g.session, action)).status_code, 404)
        self.assertEqual(self.client.post('/api/sessions/', {'quiz': g.quiz.pk}).status_code, 400)
        self.assertEqual(self.client.delete(f'/api/quizzes/{g.quiz.pk}/').status_code, 404)
        self.assertEqual(self.client.get(f'/api/sessions/{g.session.pk}/state/').status_code, 404)

    def test_nested_validation_and_partial_updates_are_atomic(self):
        payload = quiz_payload()
        created = self.client.post('/api/quizzes/', payload, format='json')
        self.assertEqual(created.status_code, 201, created.data)
        self.assertNotIn('archived_at', created.data)
        self.assertNotIn('content_revision', created.data)
        self.assertFalse(QuizVersion.objects.exists())
        qid = created.data['id']
        original = deepcopy(created.data)
        broken = deepcopy(original)
        broken['title'] = 'Изменённое'
        broken['questions'][-1]['choices'][-1]['text'] = '  '
        self.assertEqual(self.client.patch(f'/api/quizzes/{qid}/', broken, format='json').status_code, 400)
        self.assertEqual(self.client.get(f'/api/quizzes/{qid}/').data, original)
        response = self.client.patch(f'/api/quizzes/{qid}/', {'questions': [{'id': original['questions'][0]['id'], 'text': 'Другой вопрос'}]}, format='json')
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['questions'][0]['time_limit_sec'], 20)
        self.assertEqual(len(response.data['questions'][0]['choices']), 2)
        self.assertFalse(QuizVersion.objects.exists())

    def test_prepared_version_constraints_do_not_change_the_api_contract(self):
        content = quiz(self.owner)
        first = QuizVersion.objects.create(
            quiz=content,
            number=1,
            title='Подготовленный черновик',
        )

        with self.assertRaises(IntegrityError), transaction.atomic():
            QuizVersion.objects.create(
                quiz=content,
                number=2,
                title='Второй черновик',
            )
        with self.assertRaises(IntegrityError), transaction.atomic():
            QuizVersion.objects.create(
                quiz=content,
                number=1,
                status=QuizVersion.STATUS_FIXED,
                fixed_at=timezone.now(),
                title='Повтор номера',
            )
        with self.assertRaises(IntegrityError), transaction.atomic():
            QuizVersion.objects.create(
                quiz=content,
                number=3,
                status=QuizVersion.STATUS_FIXED,
                title='Фиксация без времени',
            )

        response = self.client.get(f'/api/quizzes/{content.pk}/')
        self.assertEqual(response.status_code, 200, response.data)
        self.assertNotIn('archived_at', response.data)
        self.assertNotIn('content_revision', response.data)
        self.assertNotIn('versions', response.data)
        self.assertEqual(QuizVersion.objects.get(pk=first.pk).status, 'draft')

    def test_validation_boundaries_and_array_order(self):
        for field, invalid in [('reading_time_sec', [2, 121]), ('results_time_sec', [2, 61])]:
            for value in invalid:
                payload = quiz_payload(); payload[field] = value
                self.assertEqual(self.client.post('/api/quizzes/', payload, format='json').status_code, 400)
        for value in (4, 181):
            payload = quiz_payload(); payload['questions'][0]['time_limit_sec'] = value
            self.assertEqual(self.client.post('/api/quizzes/', payload, format='json').status_code, 400)
        for low in (True, False):
            payload = quiz_payload()
            payload.update(reading_time_sec=3 if low else 120, results_time_sec=3 if low else 60)
            payload['questions'][0].update(time_limit_sec=5 if low else 180, order=999)
            payload['questions'][0]['choices'][0]['order'] = 999
            result = self.client.post('/api/quizzes/', payload, format='json')
            self.assertEqual(result.status_code, 201, result.data)
            self.assertEqual(result.data['questions'][0]['order'], 1)
            self.assertEqual(result.data['questions'][0]['choices'][0]['order'], 1)
        for choices in ([], [{'text': 'А', 'is_correct': True}], [{'text': 'А'}, {'text': 'Б'}], [{'text': 'А', 'is_correct': True}, {'text': 'Б', 'is_correct': True}]):
            payload = quiz_payload(); payload['questions'][0]['choices'] = choices
            self.assertEqual(self.client.post('/api/quizzes/', payload, format='json').status_code, 400)
        for payload in ({'title': '  ', 'questions': []}, {'title': 'Название', 'questions': []}):
            self.assertEqual(self.client.post('/api/quizzes/', payload, format='json').status_code, 400)

    def test_registered_lost_token_conflict_preserves_profile_and_results(self):
        g = game(self.owner)
        user = get_user_model().objects.create_user(username='registered', password='test-password-123')
        self.client.force_authenticate(user)
        first = self.client.post('/api/sessions/join/', {'join_token': str(g.session.join_token), 'name': 'Имя'})
        self.assertEqual(first.status_code, 200, first.data)
        second = self.client.post('/api/sessions/join/', {'join_token': str(g.session.join_token), 'name': 'Имя'})
        self.assertEqual(second.status_code, 409)
        g.session.status = 'finished'; g.session.save()
        self.assertEqual(self.client.get('/api/auth/me/').status_code, 200)
        results = self.client.get('/api/sessions/my-results/')
        self.assertEqual(len(results.data), 1)
        self.assertEqual(self.client.post(url(g.session, 'answer'), {}).status_code, 401)
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + first.data['participant_token'])
        restored = self.client.post('/api/sessions/join/', {'join_token': str(g.session.join_token)})
        self.assertEqual(restored.status_code, 200, restored.data)
        self.assertEqual(restored.data['session_participant_id'], first.data['session_participant_id'])
        self.assertNotIn('participant_token', restored.data)

    def test_anonymous_names_and_phones_do_not_merge(self):
        g = game(self.owner)
        self.client.force_authenticate(None)
        bodies = [self.client.post('/api/sessions/join/', {'pin': g.session.pin, 'name': 'Одно имя'}).data for _ in range(2)]
        self.assertNotEqual(bodies[0]['session_participant_id'], bodies[1]['session_participant_id'])
        self.assertTrue(all(phone is None for phone in Participant.objects.values_list('phone', flat=True)))
        for body in bodies:
            record = SessionParticipant.objects.get(pk=body['session_participant_id'])
            self.assertNotEqual(record.token_digest, body['participant_token'])
        g.session.status = 'live'; g.session.save()
        self.assertEqual(self.client.post('/api/sessions/join/', {'pin': g.session.pin, 'name': 'Одно имя'}).status_code, 409)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + bodies[0]['participant_token'])
        self.assertEqual(self.client.post('/api/sessions/join/', {'pin': g.session.pin}).status_code, 200)

    def test_foreign_tokens_ids_and_owner_spoofing_are_rejected(self):
        response = self.client.post('/api/quizzes/', {**quiz_payload(), 'owner': self.other.pk}, format='json')
        content = Quiz.objects.get(pk=response.data['id'])
        self.assertEqual(content.owner_id, self.owner.pk)
        response = self.client.post('/api/sessions/', {'quiz': content.pk, 'created_by': self.other.pk, 'status': 'finished'})
        session = LiveSession.objects.get(join_token=response.data['join_token'])
        self.assertEqual(session.created_by_id, self.owner.pk)
        self.assertEqual(session.status, 'waiting')
        g = game(self.owner, active=True)
        foreign = game(self.other, active=True)
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + foreign.secret)
        self.assertEqual(self.client.get(url(g.session, 'participation')).status_code, 404)
        self.assertEqual(self.client.post(url(g.session, 'answer'), {}).status_code, 404)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + g.secret)
        response = self.client.post(url(g.session, 'answer'), {'question_id': g.question.pk, 'choice_id': g.correct.pk, 'session_participant_id': foreign.link.pk})
        self.assertEqual(response.status_code, 400)
        self.assertFalse(ParticipantAnswer.objects.exists())

    def test_database_failure_rolls_back_entire_nested_update(self):
        response = self.client.post('/api/quizzes/', quiz_payload(), format='json')
        before = deepcopy(response.data)
        changed = deepcopy(before); changed['title'] = 'Не должно сохраниться'
        original_save = Choice.save
        counter = []
        def fail_last(choice, *args, **kwargs):
            counter.append(choice.pk)
            if len(counter) == 2:
                raise RuntimeError('Искусственная ошибка последнего варианта.')
            return original_save(choice, *args, **kwargs)
        with patch.object(Choice, 'save', fail_last), self.assertRaises(RuntimeError):
            self.client.patch(f"/api/quizzes/{before['id']}/", changed, format='json')
        self.assertEqual(self.client.get(f"/api/quizzes/{before['id']}/").data, before)

    def test_expired_teacher_jwt_does_not_expire_display_access(self):
        from rest_framework_simplejwt.tokens import AccessToken
        g = game(self.owner)
        token = AccessToken.for_user(self.owner)
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Bearer ' + str(token))
        response = self.client.post(url(g.session, 'display-access'))
        self.assertEqual(response.status_code, 201, response.data)
        token.set_exp(lifetime=timedelta(seconds=-1))
        self.client.credentials(HTTP_AUTHORIZATION='Bearer ' + str(token))
        self.assertEqual(self.client.get(url(g.session, 'state')).status_code, 401)
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + response.data['display_token'])
        self.assertEqual(self.client.get(url(g.session, 'display-state')).status_code, 200)

    def test_reused_pin_does_not_transfer_old_access(self):
        g = game(self.owner)
        g.session.status = 'finished'; g.session.save()
        new = LiveSession.objects.create(quiz=g.quiz, created_by=self.owner, pin=g.session.pin)
        self.client.force_authenticate(None)
        preview = self.client.get('/api/sessions/join/preview/', {'pin': new.pin})
        self.assertEqual(preview.data['session_uuid'], str(new.join_token))
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + g.secret)
        self.assertEqual(self.client.post('/api/sessions/join/', {'pin': new.pin}).status_code, 401)
        self.assertEqual(self.client.get(url(g.session, 'participation')).status_code, 200)
        self.client.credentials()
        self.assertEqual(self.client.post('/api/sessions/join/', {'pin': new.pin, 'name': 'Новый'}).status_code, 200)

    def test_pin_generation_has_bounded_retries(self):
        g = game(self.owner)
        with patch('apps.session.models.generate_pin', return_value=g.session.pin) as generate:
            with self.assertRaises(HistoryConflict):
                LiveSession.objects.create(quiz=g.quiz, created_by=self.owner)
        self.assertEqual(generate.call_count, 20)
        self.assertEqual(LiveSession.objects.count(), 1)

    def test_display_token_types_revocation_and_exact_expiry(self):
        g = game(self.owner)
        first = self.client.post(url(g.session, 'display-access')).data
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + first['display_token'])
        self.assertEqual(self.client.get(url(g.session, 'display-state')).status_code, 200)
        self.assertEqual(self.client.post(url(g.session, 'start')).status_code, 403)
        self.assertEqual(self.client.post(url(g.session, 'answer'), {}).status_code, 401)
        self.client.credentials(HTTP_AUTHORIZATION='Participant ' + first['display_token'])
        self.assertEqual(self.client.get(url(g.session, 'participation')).status_code, 401)
        self.client.credentials(); self.client.force_authenticate(self.owner)
        second = self.client.post(url(g.session, 'display-access')).data
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + first['display_token'])
        replaced = self.client.get(url(g.session, 'display-state'))
        self.assertEqual(replaced.status_code, 401)
        self.assertEqual(replaced.data['code'], 'access_revoked')
        self.client.credentials(); self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.delete(url(g.session, 'display-access/' + second['id'])).status_code, 204)
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + second['display_token'])
        revoked = self.client.get(url(g.session, 'display-state'))
        self.assertEqual(revoked.status_code, 401)
        self.assertEqual(revoked.data['code'], 'access_revoked')
        self.client.credentials(); self.client.force_authenticate(self.owner)
        third = self.client.post(url(g.session, 'display-access')).data
        self.client.force_authenticate(None)
        self.client.credentials(HTTP_AUTHORIZATION='Display ' + third['display_token'])
        g.session.status = 'finished'; g.session.save()
        boundary = g.session.finished_at + timedelta(hours=1)
        with patch('django.utils.timezone.now', return_value=boundary - timedelta(microseconds=1)):
            self.assertEqual(self.client.get(url(g.session, 'display-state')).status_code, 200)
        with patch('django.utils.timezone.now', return_value=boundary):
            self.assertEqual(self.client.get(url(g.session, 'display-state')).status_code, 401)


class HistoryProtectionTests(APITestCase):
    def setUp(self):
        self.owner = teacher()
        self.client.force_authenticate(self.owner)

    @staticmethod
    def copy_record(record):
        return type(record)(**{
            field.attname: getattr(record, field.attname)
            for field in record._meta.concrete_fields
        })

    @staticmethod
    def record_snapshot(record):
        return {
            field.attname: getattr(record, field.attname)
            for field in record._meta.concrete_fields
        }

    def assert_record_unchanged(self, record, snapshot):
        record.refresh_from_db()
        self.assertEqual(self.record_snapshot(record), snapshot)

    def test_used_content_is_immutable_for_every_status_without_answers(self):
        for state in ('waiting', 'live', 'finished', 'aborted'):
            content = quiz(self.owner)
            session = LiveSession.objects.create(quiz=content, created_by=self.owner, status=state)
            question = content.questions.first(); choice = question.choices.first()
            for obj, attr in ((content, 'title'), (question, 'text'), (choice, 'text')):
                with self.assertRaises(HistoryConflict), transaction.atomic():
                    obj.delete()
                setattr(obj, attr, 'Изменено')
                with self.assertRaises(HistoryConflict), transaction.atomic():
                    obj.save()
                with self.assertRaises((HistoryConflict, ProtectedError)), transaction.atomic():
                    type(obj).objects.filter(pk=obj.pk).delete()
            response = self.client.patch(f'/api/quizzes/{content.pk}/', {'title': 'Изменено'})
            self.assertEqual(response.status_code, 409)
            self.assertEqual(response.data['session_uuid'], str(session.join_token))
            self.assertEqual(self.client.delete(url(session, '').replace('//', '/')).status_code, 409)
            self.assertTrue(LiveSession.objects.filter(pk=session.pk).exists())

    def test_direct_and_cascade_history_delete_and_final_edit(self):
        g = game(self.owner, active=True)
        answer = ParticipantAnswer.objects.create(session_participant=g.link, question=g.question, choice=g.correct, is_correct=True, score_points=900)
        g.session.status = 'finished'; g.session.save()
        for obj in (answer, g.link, g.link.participant, g.session, g.quiz, self.owner):
            with self.assertRaises((HistoryConflict, ProtectedError)), transaction.atomic():
                obj.delete()
            with self.assertRaises((HistoryConflict, ProtectedError)), transaction.atomic():
                type(obj).objects.filter(pk=obj.pk).delete()
        answer.score_points = 0
        with self.assertRaises(HistoryConflict):
            answer.save()
        answer.refresh_from_db(); self.assertEqual(answer.score_points, 900)
        self.assertEqual(answer.choice_id, g.correct.pk)

    def test_bulk_edit_and_relation_transfer_cannot_bypass(self):
        g = game(self.owner)
        other = quiz(self.owner)
        g.question.quiz = other
        with self.assertRaises(HistoryConflict):
            g.question.save()
        for model in (Quiz, Question, Choice, LiveSession, SessionParticipant, ParticipantAnswer):
            with self.assertRaises(HistoryConflict):
                model.objects.all().update(id=1)
            with self.assertRaises(HistoryConflict):
                model.objects.bulk_update([], ['id'])
        g.session.quiz = other
        with self.assertRaises(HistoryConflict):
            g.session.save()

    def test_draft_delete_and_repeated_session_are_allowed(self):
        content = quiz(self.owner)
        content.title = 'Черновик'; content.save()
        content.delete()
        self.assertEqual(Question.objects.count(), 0)
        self.assertEqual(Choice.objects.count(), 0)
        g = game(self.owner)
        g.session.status = 'finished'; g.session.save()
        new = LiveSession.objects.create(quiz=g.quiz, created_by=self.owner, pin=g.session.pin)
        self.assertNotEqual(new.join_token, g.session.join_token)

    def test_partial_terminal_save_persists_time_and_cannot_reopen(self):
        g = game(self.owner, active=True)
        g.session.status = 'finished'
        g.session.save(update_fields=['status'])
        g.session.refresh_from_db()
        self.assertIsNotNone(g.session.finished_at)
        g.session.status = 'live'
        with self.assertRaises(HistoryConflict):
            g.session.save(update_fields=['status'])

    def test_new_instance_with_existing_pk_cannot_reopen_finished_session(self):
        g = game(self.owner, active=True)
        answer = ParticipantAnswer.objects.create(
            session_participant=g.link,
            question=g.question,
            choice=g.correct,
            is_correct=True,
            score_points=900,
        )
        g.session.status = LiveSession.STATUS_FINISHED
        g.session.save()
        session_snapshot = self.record_snapshot(g.session)
        answer_snapshot = self.record_snapshot(answer)

        replacement = self.copy_record(g.session)
        replacement.status = LiveSession.STATUS_LIVE
        replacement.finished_at = None
        with self.assertRaises(HistoryConflict):
            replacement.save()

        self.assert_record_unchanged(g.session, session_snapshot)
        self.assert_record_unchanged(answer, answer_snapshot)

    def test_new_instance_with_existing_pk_cannot_replace_session_quiz(self):
        g = game(self.owner)
        session_snapshot = self.record_snapshot(g.session)
        replacement = self.copy_record(g.session)
        replacement.quiz = quiz(self.owner)

        with self.assertRaises(HistoryConflict):
            replacement.save()

        self.assert_record_unchanged(g.session, session_snapshot)

    def test_new_instance_with_existing_pk_cannot_move_participation(self):
        g = game(self.owner, active=True)
        answer = ParticipantAnswer.objects.create(
            session_participant=g.link,
            question=g.question,
            choice=g.correct,
            is_correct=True,
            score_points=900,
        )
        g.session.status = LiveSession.STATUS_FINISHED
        g.session.save()
        target = LiveSession.objects.create(quiz=g.quiz, created_by=self.owner)
        link_snapshot = self.record_snapshot(g.link)
        answer_snapshot = self.record_snapshot(answer)
        replacement = self.copy_record(g.link)
        replacement.session = target

        with self.assertRaises(HistoryConflict):
            replacement.save()

        self.assert_record_unchanged(g.link, link_snapshot)
        self.assert_record_unchanged(answer, answer_snapshot)

    def test_new_instance_with_existing_pk_cannot_replace_participation_identity(self):
        g = game(self.owner)
        link_snapshot = self.record_snapshot(g.link)
        changes = (
            ('participant', Participant.objects.create(name='Другой участник')),
            ('name_snapshot', 'Подменённое имя'),
            ('token_digest', 'f' * 64),
        )

        for field, value in changes:
            with self.subTest(field=field):
                replacement = self.copy_record(g.link)
                setattr(replacement, field, value)
                with self.assertRaises(HistoryConflict):
                    replacement.save()
                self.assert_record_unchanged(g.link, link_snapshot)

    def test_each_rejected_replacement_preserves_all_linked_history(self):
        g = game(self.owner, active=True)
        answer = ParticipantAnswer.objects.create(
            session_participant=g.link,
            question=g.question,
            choice=g.correct,
            is_correct=True,
            score_points=900,
        )
        g.session.status = LiveSession.STATUS_FINISHED
        g.session.save()
        snapshots = {
            'session': self.record_snapshot(g.session),
            'link': self.record_snapshot(g.link),
            'answer': self.record_snapshot(answer),
        }
        replacement = self.copy_record(g.link)
        replacement.participant = Participant.objects.create(name='Подмена')
        replacement.name_snapshot = 'Подмена'
        replacement.token_digest = 'e' * 64

        with self.assertRaises(HistoryConflict):
            replacement.save()

        self.assert_record_unchanged(g.session, snapshots['session'])
        self.assert_record_unchanged(g.link, snapshots['link'])
        self.assert_record_unchanged(answer, snapshots['answer'])

    def test_normal_session_and_participation_creation_still_work(self):
        content = quiz(self.owner)
        session = LiveSession(quiz=content, created_by=self.owner)
        session.save()
        participant = Participant.objects.create(name='Новый участник')
        link = SessionParticipant(
            session=session,
            participant=participant,
            name_snapshot=participant.name,
            token_digest='d' * 64,
        )
        link.save()

        self.assertTrue(LiveSession.objects.filter(pk=session.pk).exists())
        self.assertIsNone(session.quiz_version_id)
        self.assertTrue(SessionParticipant.objects.filter(pk=link.pk).exists())

    def test_allowed_unfinished_session_transitions_still_work(self):
        content = quiz(self.owner)
        session = LiveSession.objects.create(quiz=content, created_by=self.owner)
        session.status = LiveSession.STATUS_LIVE
        session.phase = LiveSession.PHASE_READING
        session.save()
        session.phase = LiveSession.PHASE_ANSWERING
        session.current_question = content.questions.first()
        session.save()

        session.refresh_from_db()
        self.assertEqual(session.status, LiveSession.STATUS_LIVE)
        self.assertEqual(session.phase, LiveSession.PHASE_ANSWERING)
        self.assertIsNotNone(session.started_at)

    def test_new_instance_with_existing_uuid_cannot_replace_display_access(self):
        first = game(self.owner)
        second = game(self.owner)
        access = SessionDisplayAccess.objects.create(session=first.session, token_digest='c' * 64)
        access_snapshot = self.record_snapshot(access)
        replacement = self.copy_record(access)
        replacement.session = second.session
        replacement.token_digest = 'b' * 64

        with self.assertRaises(HistoryConflict):
            replacement.save()

        self.assert_record_unchanged(access, access_snapshot)

        allowed_update = self.copy_record(access)
        allowed_update.revoked_at = timezone.now()
        allowed_update.save()
        access.refresh_from_db()
        self.assertEqual(access.revoked_at, allowed_update.revoked_at)

    def test_live_session_admin_hides_prepared_version_and_preserves_history_rules(self):
        g = game(self.owner)
        administrator = get_user_model().objects.create_superuser(
            username='admin',
            password='test-password-123',
        )
        request = RequestFactory().get('/admin/')
        request.user = administrator
        model_admin = site._registry[LiveSession]
        expected_fields = [
            field.name
            for field in LiveSession._meta.fields
            if field.name != 'quiz_version'
        ]

        self.assertEqual(model_admin.get_fields(request, g.session), expected_fields)
        self.assertEqual(model_admin.get_readonly_fields(request, g.session), expected_fields)
        self.assertNotIn('quiz_version', model_admin.list_display)
        self.assertFalse(model_admin.has_add_permission(request))
        self.assertFalse(model_admin.has_change_permission(request, g.session))
        self.assertFalse(model_admin.has_delete_permission(request, g.session))

    def test_administrator_forms_and_bulk_operations_do_not_bypass(self):
        g = game(self.owner)
        admin = get_user_model().objects.create_superuser(username='admin', password='test-password-123')
        self.client.force_authenticate(None)
        self.client.force_login(admin)
        for obj in (g.quiz, g.question, g.correct, g.session, g.link):
            model_admin = site._registry[type(obj)]
            request = RequestFactory().get('/admin/'); request.user = admin
            self.assertFalse(model_admin.has_change_permission(request, obj))
            path = f'/admin/{obj._meta.app_label}/{obj._meta.model_name}/{obj.pk}/change/'
            self.assertIn(self.client.post(path, {'text': 'Подмена', 'title': 'Подмена'}).status_code, (403, 409))
        bulk = self.client.post('/admin/quiz/quiz/', {'action': 'delete_selected', '_selected_action': [g.quiz.pk], 'post': 'yes'})
        self.assertIn(bulk.status_code, (200, 403, 409))
        self.assertTrue(Quiz.objects.filter(pk=g.quiz.pk).exists())
