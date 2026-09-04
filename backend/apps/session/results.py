from django.db.models import Count, Q, Sum
from django.db.models.functions import Coalesce

from apps.session.models import LiveSession, SessionParticipant


GUEST_PHONE_PREFIX = 'guest:'


def display_participant_phone(phone: str | None) -> str:
    return '' if not phone or phone.startswith(GUEST_PHONE_PREFIX) else phone


def _with_places(rows: list[dict]) -> list[dict]:
    previous_key = None
    previous_rank = None
    for index, row in enumerate(rows, start=1):
        key = (row['correct_answers'], row['correct_time_ms'])
        if key != previous_key:
            previous_rank = index
            previous_key = key
        row['rank'] = previous_rank
        row['is_podium'] = previous_rank <= 3
    return rows


def build_stage_b_leaderboard(session: LiveSession, *, include_phone: bool = False) -> list[dict]:
    records = (
        SessionParticipant.objects.filter(session=session)
        .select_related('participant')
        .annotate(
            correct_answers=Count('final_answers', filter=Q(final_answers__is_correct=True)),
            correct_time_ms=Coalesce(
                Sum(
                    'final_answers__ranking_elapsed_ms',
                    filter=Q(final_answers__is_correct=True),
                ),
                0,
            ),
        )
        .order_by('-correct_answers', 'correct_time_ms', 'id')
    )
    rows = []
    for record in records:
        row = {
            'session_participant_id': record.pk,
            'participant_name': record.name_snapshot,
            'correct_answers': record.correct_answers,
            'correct_time_ms': int(record.correct_time_ms or 0),
        }
        if include_phone:
            row['phone'] = display_participant_phone(record.participant.phone)
        rows.append(row)
    return _with_places(rows)


def build_legacy_leaderboard(session: LiveSession, *, include_phone: bool = False) -> list[dict]:
    records = (
        SessionParticipant.objects.filter(session=session)
        .select_related('participant')
        .annotate(
            points=Coalesce(Sum('answers__score_points'), 0),
            correct_answers=Count('answers', filter=Q(answers__is_correct=True)),
            answer_time_ms=Coalesce(Sum('answers__elapsed_ms'), 0),
        )
        .order_by('-points', '-correct_answers', 'answer_time_ms', 'id')
    )
    rows = []
    for index, record in enumerate(records, start=1):
        row = {
            'rank': index,
            'session_participant_id': record.pk,
            'participant_name': record.name_snapshot,
            'points': int(record.points or 0),
            'correct_answers': record.correct_answers,
            'answer_time_ms': int(record.answer_time_ms or 0),
            'is_podium': index <= 3,
        }
        if include_phone:
            row['phone'] = display_participant_phone(record.participant.phone)
        rows.append(row)
    return rows


def build_leaderboard(session: LiveSession, *, include_phone: bool = False) -> list[dict]:
    if session.gameplay_schema == LiveSession.GAMEPLAY_SCHEMA_LEGACY:
        return build_legacy_leaderboard(session, include_phone=include_phone)
    return build_stage_b_leaderboard(session, include_phone=include_phone)
