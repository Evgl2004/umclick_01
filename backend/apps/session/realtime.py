from datetime import timedelta

from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.db.models import Count, Sum
from django.db.models.functions import Coalesce

from apps.session.models import LiveSession, ParticipantAnswer, SessionParticipant


def session_group_name(session_id: int) -> str:
    return f"session_{session_id}"


def compute_question_ends_at(session: LiveSession, question):
    if session.question_started_at is None or question is None:
        return None
    return session.question_started_at + timedelta(seconds=question.time_limit_sec)


def serialize_question_for_participants(question):
    if question is None:
        return None

    return {
        "id": question.id,
        "text": question.text,
        "order": question.order,
        "time_limit_sec": question.time_limit_sec,
        "choices": [
            {
                "id": choice.id,
                "text": choice.text,
                "order": choice.order,
            }
            for choice in question.choices.all().order_by("order", "id")
        ],
    }


def build_public_session_state(session: LiveSession) -> dict:
    question_ends_at = compute_question_ends_at(session, session.current_question)
    return {
        "session_id": session.id,
        "status": session.status,
        "pin": session.pin,
        "participants_count": SessionParticipant.objects.filter(session=session).count(),
        "current_question": serialize_question_for_participants(session.current_question),
        "question_started_at": session.question_started_at.isoformat() if session.question_started_at else None,
        "question_ends_at": question_ends_at.isoformat() if question_ends_at else None,
        "is_answer_revealed": session.current_question_id is not None
        and session.revealed_question_id == session.current_question_id,
    }


def get_next_question(session: LiveSession):
    questions = list(session.quiz.questions.all().order_by("order", "id"))
    if not questions:
        return None

    if session.current_question_id is None:
        return questions[0]

    for index, question in enumerate(questions):
        if question.id == session.current_question_id:
            if index + 1 < len(questions):
                return questions[index + 1]
            return None

    return questions[0]


def build_answer_reveal_payload(session: LiveSession) -> dict:
    question = session.current_question
    if question is None:
        return {
            "session_id": session.id,
            "question": None,
            "choices": [],
            "total_answers": 0,
            "total_points_awarded": 0,
        }

    counts = (
        ParticipantAnswer.objects.filter(
            session_participant__session=session,
            question=question,
        )
        .values("choice_id")
        .annotate(
            total=Count("id"),
            points_awarded=Coalesce(Sum("score_points"), 0),
        )
    )
    by_choice = {item["choice_id"]: item for item in counts}

    choices_payload = []
    total_answers = 0
    total_points_awarded = 0
    for choice in question.choices.all().order_by("order", "id"):
        choice_data = by_choice.get(choice.id, {})
        answers_count = int(choice_data.get("total", 0))
        awarded_points = int(choice_data.get("points_awarded", 0))

        total_answers += answers_count
        total_points_awarded += awarded_points
        choices_payload.append(
            {
                "id": choice.id,
                "text": choice.text,
                "order": choice.order,
                "is_correct": choice.is_correct,
                "answers_count": answers_count,
                "points_awarded": awarded_points,
            }
        )

    return {
        "session_id": session.id,
        "question": {
            "id": question.id,
            "text": question.text,
            "order": question.order,
            "time_limit_sec": question.time_limit_sec,
        },
        "choices": choices_payload,
        "total_answers": total_answers,
        "total_points_awarded": total_points_awarded,
    }


def broadcast_session_event(session_id: int, event: str, payload: dict) -> None:
    channel_layer = get_channel_layer()
    if channel_layer is None:
        return

    async_to_sync(channel_layer.group_send)(
        session_group_name(session_id),
        {
            "type": "session.event",
            "event": event,
            "payload": payload,
        },
    )
