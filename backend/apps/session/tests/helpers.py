from datetime import timedelta
from types import SimpleNamespace
import uuid
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.utils import timezone

from apps.quiz.models import Quiz, Question, Choice
from apps.session.access import issue_secret
from apps.session.models import LiveSession, Participant, SessionParticipant, SessionQuestionRun


def teacher(name='teacher'):
    user = get_user_model().objects.create_user(username=name, password='test-password-123')
    user.groups.add(Group.objects.get_or_create(name='teacher')[0])
    return user


def quiz(owner, **options):
    obj = Quiz.objects.create(owner=owner, title='Проверочная викторина', **options)
    for index in range(2):
        question = Question.objects.create(quiz=obj, text=f'Вопрос {index + 1}', order=index + 1, time_limit_sec=30)
        Choice.objects.create(question=question, text='Да', is_correct=True, order=1)
        Choice.objects.create(question=question, text='Нет', order=2)
    return obj


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
    session = LiveSession.objects.create(quiz=content, created_by=owner)
    link, secret = participate(session)
    question = content.questions.first()
    if active:
        activate_gameplay(session, question)
    return SimpleNamespace(quiz=content, session=session, link=link, secret=secret, question=question,
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
