from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.db.models import Count

from apps.session.models import LiveSession, ParticipantAnswer


def session_group_name(session_id: int) -> str:
    return f"session_{session_id}"


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
    return {
        "session_id": session.id,
        "status": session.status,
        "pin": session.pin,
        "participants_count": session.participants.count(),
        "current_question": serialize_question_for_participants(session.current_question),
        "question_started_at": session.question_started_at.isoformat() if session.question_started_at else None,
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
        }

    counts = (
        ParticipantAnswer.objects.filter(
            session_participant__session=session,
            question=question,
        )
        .values("choice_id")
        .annotate(total=Count("id"))
    )
    choice_totals = {item["choice_id"]: item["total"] for item in counts}

    choices_payload = []
    total_answers = 0
    for choice in question.choices.all().order_by("order", "id"):
        answers_count = int(choice_totals.get(choice.id, 0))
        total_answers += answers_count
        choices_payload.append(
            {
                "id": choice.id,
                "text": choice.text,
                "order": choice.order,
                "is_correct": choice.is_correct,
                "answers_count": answers_count,
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
