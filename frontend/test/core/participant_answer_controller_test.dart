import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/api/api_client.dart';
import 'package:umclick_frontend/core/participant_answer_controller.dart';
import 'package:umclick_frontend/core/session_state_reducer.dart';

void main() {
  const uuid = '123e4567-e89b-42d3-a456-426614174000';

  Map<String, dynamic> state({
    int revision = 1,
    String phase = 'answering',
    int runId = 7,
    int? selectedChoiceId,
    int answerVersion = 0,
    bool finalized = false,
  }) =>
      {
        'schema_version': 2,
        'session_id': uuid,
        'state_revision': revision,
        'status': 'live',
        'phase': phase,
        'question_run_id': runId,
        'current_question': {'id': 11},
        'is_answer_revealed': finalized,
        'answer': {
          'has_answer': selectedChoiceId != null,
          'selected_choice_id': selectedChoiceId,
          'answer_version': answerVersion,
          if (finalized) 'final': {'outcome': 'answered'},
        },
      };

  SessionStateReducer reducer() {
    final value = SessionStateReducer(uuid);
    value.apply(
      state(),
      source: SessionStateSource.participantRead,
    );
    return value;
  }

  ParticipantAnswerRequest request(
    SessionStateReducer reducer, {
    int choiceId = 21,
    String submissionId = '9ecbded8-1962-46a2-9861-b17f0464d3ac',
  }) =>
      ParticipantAnswerRequest(
        submissionId: submissionId,
        questionId: 11,
        choiceId: choiceId,
        context: reducer.context!,
      );

  ApiException apiError(int status, String code, {int? retryAfter}) =>
      ApiException(
        statusCode: status,
        message: 'Ошибка ответа',
        body: '{}',
        code: code,
        retryAfter: retryAfter,
      );

  test('200 is a neutral submission acknowledgement', () async {
    final value = reducer();
    final answer = request(value);
    final sent = <Map<String, dynamic>>[];
    final controller = ParticipantAnswerController(reducer: value);

    final result = await controller.submit(
      request: answer,
      send: (body, _) async {
        sent.add(body);
        return {'accepted': true, 'message': 'Ответ зафиксирован'};
      },
      readState: () async => fail('Чтение не требуется.'),
    );

    expect(result.kind, ParticipantAnswerResultKind.submitted);
    expect(sent.single['submission_id'], answer.submissionId);
    expect(result.state, isNot(contains('is_correct')));
  });

  test('ordinary 409 performs one participant read without repeat', () async {
    final value = reducer();
    var sends = 0;
    var reads = 0;
    final controller = ParticipantAnswerController(reducer: value);
    final result = await controller.submit(
      request: request(value),
      send: (_, __) async {
        sends += 1;
        throw apiError(409, 'conflict');
      },
      readState: () async {
        reads += 1;
        return state();
      },
    );

    expect(result.kind, ParticipantAnswerResultKind.conflict);
    expect((sends, reads), (1, 1));
  });

  test('429 and 503 use bounded delays with the same submission id', () async {
    for (final scenario in [
      (429, 'rate_limited', <int>[1, 2, 3]),
      (503, 'limiter_unavailable', <int>[3, 3, 3]),
    ]) {
      final value = reducer();
      final waits = <int>[];
      final ids = <Object?>[];
      var sends = 0;
      final controller = ParticipantAnswerController(
        reducer: value,
        delay: (duration) async => waits.add(duration.inSeconds),
      );
      final result = await controller.submit(
        request: request(value),
        send: (body, _) async {
          ids.add(body['submission_id']);
          sends += 1;
          if (sends < 4) {
            throw apiError(
              scenario.$1,
              scenario.$2,
              retryAfter: scenario.$1 == 503 ? 3 : sends,
            );
          }
          return {'accepted': true};
        },
        readState: () async => fail('Чтение не требуется.'),
      );

      expect(result.kind, ParticipantAnswerResultKind.submitted);
      expect(waits, scenario.$3);
      expect(ids.toSet(), hasLength(1));
    }
  });

  test('network retries at 1, 2, 4 and confirms selection with one read',
      () async {
    final value = reducer();
    final waits = <int>[];
    final ids = <Object?>[];
    var reads = 0;
    final controller = ParticipantAnswerController(
      reducer: value,
      delay: (duration) async => waits.add(duration.inSeconds),
    );
    final result = await controller.submit(
      request: request(value),
      send: (body, _) async {
        ids.add(body['submission_id']);
        throw StateError('Сетевой разрыв');
      },
      readState: () async {
        reads += 1;
        return state(selectedChoiceId: 21);
      },
    );

    expect(result.kind, ParticipantAnswerResultKind.recoveredAfterNetwork);
    expect(waits, [1, 2, 4]);
    expect(ids, hasLength(4));
    expect(ids.toSet(), hasLength(1));
    expect(reads, 1);
  });

  test('new choice cancels old result and transports are not parallel',
      () async {
    final value = reducer();
    final firstResponse = Completer<Map<String, dynamic>>();
    var active = 0;
    var maxActive = 0;
    var sends = 0;
    final controller = ParticipantAnswerController(reducer: value);

    Future<Map<String, dynamic>> send(
      Map<String, dynamic> body,
      Future<void> abortTrigger,
    ) async {
      sends += 1;
      active += 1;
      if (active > maxActive) maxActive = active;
      try {
        if (body['choice_id'] == 21) {
          return await Future.any([
            firstResponse.future,
            abortTrigger.then<Map<String, dynamic>>(
              (_) => throw StateError('Запрос отменён.'),
            ),
          ]);
        }
        return {'accepted': true};
      } finally {
        active -= 1;
      }
    }

    final first = controller.submit(
      request: request(value, choiceId: 21),
      send: send,
      readState: () async => state(),
    );
    await Future<void>.delayed(Duration.zero);
    final second = controller.submit(
      request: request(
        value,
        choiceId: 22,
        submissionId: '4fc2228a-f412-40a7-a8b1-c635c8e31c86',
      ),
      send: send,
      readState: () async => state(),
    );
    await Future<void>.delayed(Duration.zero);
    expect(sends, 2);

    final results = await Future.wait([first, second]);
    firstResponse.complete({'accepted': true});
    await Future<void>.delayed(Duration.zero);

    expect(results[0].kind, ParticipantAnswerResultKind.cancelled);
    expect(results[1].kind, ParticipantAnswerResultKind.submitted);
    expect(maxActive, 1);
    expect(sends, 2);
  });

  test('question context change cancels a scheduled repeat', () async {
    final value = reducer();
    var sends = 0;
    final controller = ParticipantAnswerController(
      reducer: value,
      delay: (_) async {
        value.apply(
          state(revision: 2, phase: 'results'),
          source: SessionStateSource.websocket,
        );
      },
    );

    final result = await controller.submit(
      request: request(value),
      send: (_, __) async {
        sends += 1;
        throw apiError(429, 'rate_limited', retryAfter: 1);
      },
      readState: () async => state(),
    );

    expect(result.kind, ParticipantAnswerResultKind.cancelled);
    expect(sends, 1);
  });

  test('late same-revision snapshot does not roll back acknowledged choice',
      () async {
    final value = reducer();
    final response = Completer<Map<String, dynamic>>();
    final controller = ParticipantAnswerController(reducer: value);
    final pending = controller.submit(
      request: request(value),
      send: (_, __) => response.future,
      readState: () async => fail('Чтение не требуется.'),
    );

    expect(controller.visibleSelectedChoiceId, 21);
    expect(controller.visibleHasAnswer, isFalse);
    controller.applyState(
      state(selectedChoiceId: null, answerVersion: 0),
      source: SessionStateSource.participantRead,
    );
    expect(controller.visibleSelectedChoiceId, 21);

    response.complete({'accepted': true, 'message': 'Ответ зафиксирован'});
    await pending;
    expect(controller.visibleHasAnswer, isTrue);
    controller.applyState(
      state(selectedChoiceId: null, answerVersion: 0),
      source: SessionStateSource.participantWebsocket,
    );
    expect(controller.visibleSelectedChoiceId, 21);
    expect(controller.hasLocalSelection, isTrue);

    controller.applyState(
      state(selectedChoiceId: 21, answerVersion: 1),
      source: SessionStateSource.participantRead,
    );
    expect(controller.hasLocalSelection, isFalse);
    expect(controller.visibleSelectedChoiceId, 21);
  });

  test('запоздавший ролевой снимок не откатывает подтверждённый выбор',
      () async {
    for (final sources in const [
      (
        SessionStateSource.participantRead,
        SessionStateSource.participantWebsocket,
      ),
      (
        SessionStateSource.participantWebsocket,
        SessionStateSource.participantRead,
      ),
    ]) {
      final value = SessionStateReducer(uuid);
      value.apply(
        state(selectedChoiceId: 21, answerVersion: 1),
        source: sources.$1,
      );
      final controller = ParticipantAnswerController(reducer: value);

      await controller.submit(
        request: request(
          value,
          choiceId: 22,
          submissionId: '4fc2228a-f412-40a7-a8b1-c635c8e31c86',
        ),
        send: (_, __) async => {
          'accepted': true,
          'message': 'Ответ зафиксирован',
        },
        readState: () async => fail('Чтение не требуется.'),
      );
      controller.applyState(
        state(selectedChoiceId: 22, answerVersion: 2),
        source: sources.$1,
      );
      expect(controller.hasLocalSelection, isFalse);

      controller.applyState(
        {
          ...state(selectedChoiceId: 21, answerVersion: 1),
          'phase_ends_at': '2026-09-05T12:00:00Z',
        },
        source: sources.$2,
      );

      expect(controller.hasLocalSelection, isFalse);
      expect(controller.visibleSelectedChoiceId, 22);
      expect(controller.visibleHasAnswer, isTrue);
      expect((value.state['answer'] as Map)['answer_version'], 2);
      expect(value.state['phase_ends_at'], '2026-09-05T12:00:00Z');
    }
  });

  test('запоздавшая версия 0 не откатывает ответ без локального наложения', () {
    final value = SessionStateReducer(uuid);
    final controller = ParticipantAnswerController(reducer: value);
    controller.applyState(
      state(selectedChoiceId: 22, answerVersion: 2),
      source: SessionStateSource.participantRead,
    );
    expect(controller.hasLocalSelection, isFalse);

    controller.applyState(
      state(selectedChoiceId: null, answerVersion: 0),
      source: SessionStateSource.participantWebsocket,
    );

    expect(controller.visibleSelectedChoiceId, 22);
    expect(controller.visibleHasAnswer, isTrue);
    expect((value.state['answer'] as Map)['answer_version'], 2);
  });

  test('snapshot for first of two quick choices cannot erase the second',
      () async {
    final value = reducer();
    final firstResponse = Completer<Map<String, dynamic>>();
    final controller = ParticipantAnswerController(reducer: value);

    final first = controller.submit(
      request: request(value, choiceId: 21),
      send: (_, __) => firstResponse.future,
      readState: () async => fail('Чтение не требуется.'),
    );
    final second = controller.submit(
      request: request(
        value,
        choiceId: 22,
        submissionId: '4fc2228a-f412-40a7-a8b1-c635c8e31c86',
      ),
      send: (_, __) async => {'accepted': true},
      readState: () async => fail('Чтение не требуется.'),
    );

    expect(controller.visibleSelectedChoiceId, 22);
    controller.applyState(
      state(selectedChoiceId: 21, answerVersion: 1),
      source: SessionStateSource.participantRead,
    );
    expect(controller.visibleSelectedChoiceId, 22);
    expect(controller.minimumExpectedAnswerVersion, 2);

    firstResponse.complete({'accepted': true});
    await Future.wait([first, second]);
    expect(controller.visibleSelectedChoiceId, 22);
  });

  test('new question run immediately clears the prior local choice', () async {
    final value = reducer();
    final response = Completer<Map<String, dynamic>>();
    final controller = ParticipantAnswerController(reducer: value);
    final pending = controller.submit(
      request: request(value),
      send: (_, __) => response.future,
      readState: () async => fail('Чтение не требуется.'),
    );
    expect(controller.visibleSelectedChoiceId, 21);

    controller.applyState(
      state(revision: 2, phase: 'reading', runId: 8),
      source: SessionStateSource.participantWebsocket,
    );
    expect(controller.visibleSelectedChoiceId, isNull);
    expect(controller.hasLocalSelection, isFalse);
    expect((value.state['answer'] as Map)['answer_version'], 0);

    response.complete({'accepted': true});
    expect((await pending).kind, ParticipantAnswerResultKind.cancelled);
    expect(controller.visibleSelectedChoiceId, isNull);
  });

  test('final role snapshot overrides an unreachable local version threshold',
      () async {
    final value = reducer();
    final controller = ParticipantAnswerController(reducer: value);

    await controller.submit(
      request: request(value, choiceId: 21),
      send: (_, __) async => {'accepted': true},
      readState: () async => fail('Чтение не требуется.'),
    );
    await controller.submit(
      request: request(
        value,
        choiceId: 22,
        submissionId: '4fc2228a-f412-40a7-a8b1-c635c8e31c86',
      ),
      send: (_, __) async => {'accepted': true},
      readState: () async => fail('Чтение не требуется.'),
    );
    expect(controller.minimumExpectedAnswerVersion, 2);

    controller.applyState(
      state(
        selectedChoiceId: 21,
        answerVersion: 1,
        finalized: true,
      ),
      source: SessionStateSource.participantRead,
    );

    expect(controller.hasLocalSelection, isFalse);
    expect(controller.visibleSelectedChoiceId, 21);
    expect((value.state['answer'] as Map)['answer_version'], 1);
    expect((value.state['answer'] as Map).containsKey('final'), isTrue);
  });
}
