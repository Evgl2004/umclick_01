from datetime import timedelta
from types import SimpleNamespace
import uuid
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.utils import timezone

from apps.quiz.services import create_quiz_with_draft
from apps.session.access import issue_secret
from apps.session.models import Participant, SessionParticipant, SessionQuestionRun
from apps.session.services import create_live_session


def teacher(name='teacher'):
    user = get_user_model().objects.create_user(username=name, password='test-password-123')
    user.groups.add(Group.objects.get_or_create(name='teacher')[0])
    return user


def quiz(owner, **options):
    data = {
        'title': 'Проверочная викторина',
        'description': '',
        'question_only_on_display': False,
        'show_choices_on_participant': True,
        'reading_time_sec': 15,
        'results_time_sec': 10,
        'questions': [
            {
                'text': f'Вопрос {index + 1}',
                'order': index + 1,
                'time_limit_sec': 30,
                'choices': [
                    {'text': 'Да', 'is_correct': True, 'order': 1},
                    {'text': 'Нет', 'is_correct': False, 'order': 2},
                ],
            }
            for index in range(2)
        ],
    }
    data.update(options)
    return create_quiz_with_draft(actor=owner, data=data)


def participate(session, name='Участник', user=None):
    participant = Participant.objects.create(name=name, user=user)
    secret, digest = issue_secret('participant')
    link = SessionParticipant.objects.create(session=session, participant=participant, name_snapshot=name, token_digest=digest)
    return link, secret


def activate_gameplay(session, question):
    now = timezone.now()
    run = SessionQuestionRun.objects.create(
        session=session,
        question=question,
        ordinal=1,
        reading_started_at=now - timedelta(seconds=1),
        reading_ends_at=now,
        answering_started_at=now,
        planned_answer_deadline_at=now + timedelta(seconds=question.time_limit_sec),
        planned_delivery_deadline_at=now + timedelta(seconds=question.time_limit_sec + 3),
        answer_deadline_at=now + timedelta(seconds=question.time_limit_sec),
        delivery_deadline_at=now + timedelta(seconds=question.time_limit_sec + 3),
    )
    session.status = 'live'
    session.phase = 'answering'
    session.current_question = question
    session.current_run = run
    session.question_started_at = now
    session.phase_started_at = now
    session.started_at = now
    session.state_revision = 2
    session.save()
    return run


def game(owner, active=False, **options):
    content = quiz(owner, **options)
    session = create_live_session(quiz_id=content.pk, actor=owner)
    link, secret = participate(session)
    question = session.quiz_version.questions.first()
    if active:
        activate_gameplay(session, question)
    return SimpleNamespace(quiz=content, version=session.quiz_version, session=session, link=link, secret=secret, question=question,
                           correct=question.choices.get(is_correct=True), wrong=question.choices.get(is_correct=False))


def url(session, action):
    return f'/api/sessions/{session.join_token}/{action}/'


def command_payload(session, *, command_id=None):
    session.refresh_from_db()
    return {
        'command_id': str(command_id or uuid.uuid4()),
        'state_revision': session.state_revision,
        'phase': session.phase,
        'question_run_id': session.current_run_id,
    }


def quiz_payload():
    return {'title': 'Новая викторина', 'questions': [{'text': 'Вопрос', 'time_limit_sec': 20,
            'choices': [{'text': 'Да', 'is_correct': True}, {'text': 'Нет', 'is_correct': False}]}]}
