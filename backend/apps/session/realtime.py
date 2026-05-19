from datetime import timedelta
import random

from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.db.models import Count, Q, Sum
from django.db.models.functions import Coalesce

from apps.session.models import LiveSession, ParticipantAnswer, SessionParticipant


def session_group_name(session_id: int) -> str:
    return f"session_{session_id}"


def compute_question_ends_at(session: LiveSession, question):
    if session.question_started_at is None or question is None:
        return None
    return session.question_started_at + timedelta(seconds=question.time_limit_sec)


def compute_phase_ends_at(session: LiveSession):
    if session.phase_started_at is None:
        return None
    if session.phase == LiveSession.PHASE_READING:
        return session.phase_started_at + timedelta(seconds=session.quiz.reading_time_sec)
    if session.phase == LiveSession.PHASE_RESULTS:
        return session.phase_started_at + timedelta(seconds=session.quiz.results_time_sec)
    return None


def _ordered_choices_for_session(question, session: LiveSession | None):
    choices = list(question.choices.all().order_by("order", "id"))
    if session is None:
        return choices

    rng = random.Random(f"{session.id}:{question.id}:{session.join_token}")
    rng.shuffle(choices)
    return choices


def serialize_question_for_participants(question, session: LiveSession | None = None):
    if question is None:
        return None

    quiz = question.quiz
    show_question = not quiz.question_only_on_display
    show_choices = quiz.show_choices_on_participant

    return {
        "id": question.id,
        "text": question.text if show_question else "",
        "text_hidden": not show_question,
        "order": question.order,
        "time_limit_sec": question.time_limit_sec,
        "choices_text_hidden": not show_choices,
        "choices": [
            {
                "id": choice.id,
                "text": choice.text if show_choices else "",
                "order": index + 1,
                "original_order": choice.order,
            }
            for index, choice in enumerate(_ordered_choices_for_session(question, session))
        ],
    }


def serialize_question_for_display(question, session: LiveSession | None = None, *, include_correct: bool = False):
    if question is None:
        return None

    choices = []
    for index, choice in enumerate(_ordered_choices_for_session(question, session)):
        payload = {
            "id": choice.id,
            "text": choice.text,
            "order": index + 1,
            "original_order": choice.order,
        }
        if include_correct:
            payload["is_correct"] = choice.is_correct
        choices.append(payload)

    return {
        "id": question.id,
        "text": question.text,
        "order": question.order,
        "time_limit_sec": question.time_limit_sec,
        "choices": choices,
    }


def build_public_session_state(session: LiveSession) -> dict:
    question_ends_at = compute_question_ends_at(session, session.current_question)
    phase_ends_at = compute_phase_ends_at(session)
    state = {
        "session_id": session.id,
        "status": session.status,
        "phase": session.phase,
        "pin": session.pin,
        "participants_count": SessionParticipant.objects.filter(session=session).count(),
        "current_question": serialize_question_for_participants(session.current_question, session),
        "phase_started_at": session.phase_started_at.isoformat() if session.phase_started_at else None,
        "phase_ends_at": phase_ends_at.isoformat() if phase_ends_at else None,
        "question_started_at": session.question_started_at.isoformat() if session.question_started_at else None,
        "question_ends_at": question_ends_at.isoformat() if question_ends_at else None,
        "is_answer_revealed": session.current_question_id is not None
        and session.revealed_question_id == session.current_question_id,
        "reading_time_sec": session.quiz.reading_time_sec,
        "results_time_sec": session.quiz.results_time_sec,
    }
    if session.phase == LiveSession.PHASE_RESULTS and session.current_question_id is not None:
        state["reveal"] = build_answer_reveal_payload(session)
    return state


def build_public_leaderboard(session: LiveSession) -> list[dict]:
    rows = (
        SessionParticipant.objects.filter(session=session)
        .select_related("participant")
        .annotate(
            points=Coalesce(Sum("answers__score_points"), 0),
            correct_answers=Count("answers", filter=Q(answers__is_correct=True)),
            answer_time_ms=Coalesce(Sum("answers__elapsed_ms"), 0),
        )
        .order_by("-points", "-correct_answers", "answer_time_ms", "joined_at", "id")
    )
    return [
        {
            "rank": index + 1,
            "session_participant_id": row.id,
            "participant_name": row.participant.name,
            "points": int(row.points or 0),
            "correct_answers": row.correct_answers,
            "answer_time_ms": int(row.answer_time_ms or 0),
            "is_podium": index < 3,
        }
        for index, row in enumerate(rows)
    ]


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


def build_answer_reveal_payload(session: LiveSession, *, for_display: bool = False) -> dict:
    question = session.current_question
    phase_ends_at = compute_phase_ends_at(session)
    if question is None:
        return {
            "session_id": session.id,
            "status": session.status,
            "phase": session.phase,
            "question": None,
            "choices": [],
            "total_answers": 0,
            "total_points_awarded": 0,
            "phase_ends_at": phase_ends_at.isoformat() if phase_ends_at else None,
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
    show_choices = for_display or session.quiz.show_choices_on_participant
    for index, choice in enumerate(_ordered_choices_for_session(question, session)):
        choice_data = by_choice.get(choice.id, {})
        answers_count = int(choice_data.get("total", 0))
        awarded_points = int(choice_data.get("points_awarded", 0))

        total_answers += answers_count
        total_points_awarded += awarded_points
        choices_payload.append(
            {
                "id": choice.id,
                "text": choice.text if show_choices else "",
                "order": index + 1,
                "original_order": choice.order,
                "is_correct": choice.is_correct,
                "answers_count": answers_count,
                "points_awarded": awarded_points,
            }
        )

    return {
        "session_id": session.id,
        "status": session.status,
        "phase": session.phase,
        "phase_started_at": session.phase_started_at.isoformat() if session.phase_started_at else None,
        "phase_ends_at": phase_ends_at.isoformat() if phase_ends_at else None,
        "question": {
            "id": question.id,
            "text": question.text if (for_display or not session.quiz.question_only_on_display) else "",
            "text_hidden": not for_display and session.quiz.question_only_on_display,
            "order": question.order,
            "time_limit_sec": question.time_limit_sec,
        },
        "choices": choices_payload,
        "total_answers": total_answers,
        "total_points_awarded": total_points_awarded,
        "leaderboard": build_public_leaderboard(session),
    }


def build_display_session_state(session: LiveSession) -> dict:
    state = build_public_session_state(session)
    state["display_question"] = serialize_question_for_display(
        session.current_question,
        session,
        include_correct=session.phase == LiveSession.PHASE_RESULTS
        or session.status in {LiveSession.STATUS_FINISHED, LiveSession.STATUS_ABORTED},
    )
    state["quiz"] = {
        "id": session.quiz_id,
        "title": session.quiz.title,
        "description": session.quiz.description,
        "reading_time_sec": session.quiz.reading_time_sec,
        "results_time_sec": session.quiz.results_time_sec,
        "question_only_on_display": session.quiz.question_only_on_display,
        "show_choices_on_participant": session.quiz.show_choices_on_participant,
    }
    if session.phase == LiveSession.PHASE_RESULTS and session.current_question_id is not None:
        state["reveal"] = build_answer_reveal_payload(session, for_display=True)
    if session.status in {LiveSession.STATUS_FINISHED, LiveSession.STATUS_ABORTED}:
        state["leaderboard"] = build_public_leaderboard(session)
    return state


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
