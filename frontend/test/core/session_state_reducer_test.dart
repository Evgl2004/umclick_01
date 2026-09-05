import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/core/session_state_reducer.dart';

void main() {
  const uuid = '123e4567-e89b-42d3-a456-426614174000';

  Map<String, dynamic> state({
    int revision = 1,
    String phase = 'lobby',
    int? runId,
    Map<String, dynamic>? answer,
    int? participantsCount,
    int? answeredParticipantsCount,
    Map<String, dynamic>? reveal,
    List<dynamic>? leaderboard,
  }) {
    return {
      'schema_version': 2,
      'session_id': uuid,
      'state_revision': revision,
      'status': 'live',
      'phase': phase,
      'question_run_id': runId,
      'question_id': runId == null ? null : 11,
      if (answer != null) 'answer': answer,
      if (participantsCount != null) 'participants_count': participantsCount,
      if (answeredParticipantsCount != null)
        'answered_participants_count': answeredParticipantsCount,
      if (reveal != null) 'reveal': reveal,
      if (leaderboard != null) 'leaderboard': leaderboard,
    };
  }

  test('accepts only schema 2, expected UUID and monotonic revisions', () {
    final reducer = SessionStateReducer(uuid);

    expect(
      reducer.apply(state(), source: SessionStateSource.accountRead).accepted,
      isTrue,
    );
    expect(
      reducer.apply(
        {...state(revision: 2), 'schema_version': 1},
        source: SessionStateSource.websocket,
      ).accepted,
      isFalse,
    );
    expect(
      reducer
          .apply(
            state(revision: 0),
            source: SessionStateSource.websocket,
          )
          .accepted,
      isFalse,
    );
  });

  test('does not roll phase back at equal revision', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      state(revision: 2, phase: 'answering', runId: 7),
      source: SessionStateSource.accountRead,
    );

    final result = reducer.apply(
      state(revision: 2, phase: 'reading', runId: 6),
      source: SessionStateSource.websocket,
    );

    expect(result.accepted, isTrue);
    expect(result.state['phase'], 'answering');
    expect(result.state['question_run_id'], 7);
  });

  test('same-context role read enriches a partial command state', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      state(revision: 2, phase: 'reading', runId: 7),
      source: SessionStateSource.command,
    );

    final result = reducer.apply(
      {
        ...state(revision: 2, phase: 'reading', runId: 7),
        'current_question': {'id': 11, 'text': 'Вопрос'},
      },
      source: SessionStateSource.accountRead,
    );

    expect(result.accepted, isTrue);
    expect(
      (result.state['current_question'] as Map<String, dynamic>)['id'],
      11,
    );
  });

  test('accepts participant answer only from an authoritative role read', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(state(), source: SessionStateSource.accountRead);

    reducer.apply(
      state(answer: {'selected_choice_id': 10}),
      source: SessionStateSource.websocket,
    );
    expect(reducer.state.containsKey('answer'), isFalse);

    reducer.apply(
      state(answer: {'selected_choice_id': 20}),
      source: SessionStateSource.participantRead,
    );
    expect(
      (reducer.state['answer'] as Map<String, dynamic>)['selected_choice_id'],
      20,
    );
  });

  test('reports a higher revision as a changed operation context', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(state(), source: SessionStateSource.accountRead);

    final result = reducer.apply(
      state(revision: 2, phase: 'reading', runId: 8),
      source: SessionStateSource.websocket,
    );

    expect(result.accepted, isTrue);
    expect(result.contextChanged, isTrue);
  });

  test('late equal revision keeps only the two monotonic counters', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      state(
        revision: 2,
        phase: 'answering',
        runId: 7,
        participantsCount: 12,
        answeredParticipantsCount: 8,
        reveal: {
          'total_answers': 8,
          'choices': [
            {'id': 1, 'answers_count': 8},
          ],
        },
      ),
      source: SessionStateSource.participantRead,
    );

    final result = reducer.apply(
      state(
        revision: 2,
        phase: 'answering',
        runId: 7,
        participantsCount: 10,
        answeredParticipantsCount: 6,
        reveal: {
          'total_answers': 6,
          'choices': [
            {'id': 1, 'answers_count': 6},
          ],
        },
      ),
      source: SessionStateSource.participantRead,
    );

    expect(result.state['participants_count'], 12);
    expect(result.state['answered_participants_count'], 8);
    expect(
      (result.state['reveal'] as Map<String, dynamic>)['total_answers'],
      6,
    );
  });

  test('старый блок ответа не смешивается с новой подтверждённой версией', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      {
        ...state(revision: 2, phase: 'answering', runId: 7),
        'answer': {
          'has_answer': true,
          'selected_choice_id': 22,
          'answer_version': 2,
        },
      },
      source: SessionStateSource.participantRead,
    );

    final result = reducer.apply(
      {
        ...state(revision: 2, phase: 'answering', runId: 7),
        'phase_ends_at': '2026-09-05T12:00:00Z',
        'answer': {
          'has_answer': true,
          'selected_choice_id': 21,
          'answer_version': 1,
        },
      },
      source: SessionStateSource.participantWebsocket,
    );

    expect(result.state['phase_ends_at'], '2026-09-05T12:00:00Z');
    expect(result.state['answer'], {
      'has_answer': true,
      'selected_choice_id': 22,
      'answer_version': 2,
    });
  });

  test('новый запуск принимает исходную версию ответа 0', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      {
        ...state(revision: 2, phase: 'results', runId: 7),
        'answer': {
          'has_answer': true,
          'selected_choice_id': 22,
          'answer_version': 2,
        },
      },
      source: SessionStateSource.participantRead,
    );

    final result = reducer.apply(
      {
        ...state(revision: 3, phase: 'reading', runId: 8),
        'answer': {
          'has_answer': false,
          'selected_choice_id': null,
          'answer_version': 0,
        },
      },
      source: SessionStateSource.participantWebsocket,
    );

    expect(result.contextChanged, isTrue);
    expect(result.state['answer'], {
      'has_answer': false,
      'selected_choice_id': null,
      'answer_version': 0,
    });
  });

  test('окончательный ответ сервера имеет приоритет над большей версией', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      {
        ...state(revision: 2, phase: 'results', runId: 7),
        'is_answer_revealed': false,
        'answer': {
          'has_answer': true,
          'selected_choice_id': 22,
          'answer_version': 2,
        },
      },
      source: SessionStateSource.participantRead,
    );

    final result = reducer.apply(
      {
        ...state(revision: 2, phase: 'results', runId: 7),
        'is_answer_revealed': true,
        'answer': {
          'has_answer': true,
          'selected_choice_id': 21,
          'answer_version': 1,
          'final': {'outcome': 'answered'},
        },
      },
      source: SessionStateSource.participantWebsocket,
    );

    expect(result.state['is_answer_revealed'], isTrue);
    expect((result.state['answer'] as Map)['selected_choice_id'], 21);
    expect((result.state['answer'] as Map)['answer_version'], 1);
    expect((result.state['answer'] as Map).containsKey('final'), isTrue);
  });

  test('higher revision may authoritatively lower counters', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      state(
        revision: 2,
        phase: 'answering',
        runId: 7,
        participantsCount: 12,
        answeredParticipantsCount: 8,
      ),
      source: SessionStateSource.participantRead,
    );

    final result = reducer.apply(
      state(
        revision: 3,
        phase: 'delivery',
        runId: 7,
        participantsCount: 10,
        answeredParticipantsCount: 6,
      ),
      source: SessionStateSource.participantRead,
    );

    expect(result.state['participants_count'], 10);
    expect(result.state['answered_participants_count'], 6);
  });

  test('new question run clears prior answer reveal and leaderboard', () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      state(
        revision: 2,
        phase: 'results',
        runId: 7,
        answer: {'selected_choice_id': 20, 'answer_version': 1},
        reveal: {'total_answers': 1},
        leaderboard: const [
          {'rank': 1},
        ],
      ),
      source: SessionStateSource.participantRead,
    );

    final result = reducer.apply(
      state(revision: 3, phase: 'reading', runId: 8),
      source: SessionStateSource.participantWebsocket,
    );

    expect(result.contextChanged, isTrue);
    expect(result.state.containsKey('answer'), isFalse);
    expect(result.state.containsKey('reveal'), isFalse);
    expect(result.state.containsKey('leaderboard'), isFalse);
  });

  test('equal revision with a different stable context does not mix fields',
      () {
    final reducer = SessionStateReducer(uuid);
    reducer.apply(
      {
        ...state(revision: 2, phase: 'answering', runId: 7),
        'current_question': {'id': 11},
        'participants_count': 5,
      },
      source: SessionStateSource.participantRead,
    );

    final result = reducer.apply(
      {
        ...state(revision: 2, phase: 'results', runId: 8),
        'current_question': {'id': 22},
        'participants_count': 99,
      },
      source: SessionStateSource.participantWebsocket,
    );

    expect(result.state['phase'], 'answering');
    expect(result.state['question_run_id'], 7);
    expect(result.state['participants_count'], 5);
    expect(
      (result.state['current_question'] as Map<String, dynamic>)['id'],
      11,
    );
  });
}
