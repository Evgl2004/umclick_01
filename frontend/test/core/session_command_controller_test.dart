import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/api/api_client.dart';
import 'package:umclick_frontend/core/session_command_controller.dart';
import 'package:umclick_frontend/core/session_state_reducer.dart';

void main() {
  const uuid = '123e4567-e89b-42d3-a456-426614174000';

  Map<String, dynamic> state({
    int revision = 1,
    String status = 'live',
    String phase = 'lobby',
    int? runId,
  }) =>
      {
        'schema_version': 2,
        'session_id': uuid,
        'state_revision': revision,
        'status': status,
        'phase': phase,
        'question_run_id': runId,
      };

  SessionStateReducer reducer() {
    final value = SessionStateReducer(uuid);
    value.apply(state(), source: SessionStateSource.accountRead);
    return value;
  }

  SessionCommandRequest request(
    SessionStateReducer reducer, {
    String commandId = '9ecbded8-1962-46a2-9861-b17f0464d3ac',
  }) =>
      SessionCommandRequest(
        kind: 'start_quiz',
        commandId: commandId,
        context: reducer.context!,
      );

  ApiException apiError(int status, String code, {int? retryAfter}) =>
      ApiException(
        statusCode: status,
        message: 'Ошибка запроса',
        body: '{}',
        code: code,
        retryAfter: retryAfter,
      );

  test('returns 200 state after one send with the original command id',
      () async {
    final value = reducer();
    final sent = <Map<String, dynamic>>[];
    final controller = SessionCommandController(reducer: value);
    final command = request(value);

    final result = await controller.execute(
      request: command,
      send: (body, _) async {
        sent.add(body);
        return state(revision: 2, phase: 'reading', runId: 8);
      },
      readState: () async => fail('Контрольное чтение не требуется.'),
      isExpectedSuccess: (_) => false,
    );

    expect(result.kind, SessionCommandResultKind.succeeded);
    expect(sent, hasLength(1));
    expect(sent.single['command_id'], command.commandId);
  });

  test('applies StateConflict without automatic repeat', () async {
    final value = reducer();
    var sends = 0;
    final controller = SessionCommandController(reducer: value);
    final result = await controller.execute(
      request: request(value),
      send: (_, __) async {
        sends += 1;
        throw ApiException(
          statusCode: 409,
          message: 'Конфликт состояния',
          body: '{}',
          code: 'state_conflict',
          state: state(revision: 2, phase: 'reading', runId: 9),
        );
      },
      readState: () async => fail('Чтение не требуется.'),
      isExpectedSuccess: (_) => false,
    );

    expect(result.kind, SessionCommandResultKind.stateConflict);
    expect(sends, 1);
    expect(value.state['state_revision'], 2);
  });

  test('ordinary 409 performs one state read and no repeat', () async {
    final value = reducer();
    var sends = 0;
    var reads = 0;
    final controller = SessionCommandController(reducer: value);
    final result = await controller.execute(
      request: request(value),
      send: (_, __) async {
        sends += 1;
        throw apiError(409, 'conflict');
      },
      readState: () async {
        reads += 1;
        return state();
      },
      isExpectedSuccess: (_) => false,
    );

    expect(result.kind, SessionCommandResultKind.conflict);
    expect((sends, reads), (1, 1));
  });

  test('429 uses every Retry-After and keeps the command body', () async {
    final value = reducer();
    final waits = <Duration>[];
    final ids = <Object?>[];
    var sends = 0;
    final controller = SessionCommandController(
      reducer: value,
      delay: (duration) async => waits.add(duration),
    );
    final result = await controller.execute(
      request: request(value),
      send: (body, _) async {
        ids.add(body['command_id']);
        sends += 1;
        if (sends < 4) {
          throw apiError(429, 'rate_limited', retryAfter: sends);
        }
        return state(revision: 2, phase: 'reading', runId: 8);
      },
      readState: () async => fail('Чтение не требуется.'),
      isExpectedSuccess: (_) => false,
    );

    expect(result.kind, SessionCommandResultKind.succeeded);
    expect(waits, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
    ]);
    expect(ids.toSet(), hasLength(1));
  });

  test('503 uses every server Retry-After before the same fourth request',
      () async {
    final value = reducer();
    final waits = <Duration>[];
    var sends = 0;
    final controller = SessionCommandController(
      reducer: value,
      delay: (duration) async => waits.add(duration),
    );
    final result = await controller.execute(
      request: request(value),
      send: (_, __) async {
        sends += 1;
        if (sends < 4) {
          throw apiError(503, 'limiter_unavailable', retryAfter: 3);
        }
        return state(revision: 2, phase: 'reading', runId: 8);
      },
      readState: () async => fail('Чтение не требуется.'),
      isExpectedSuccess: (_) => false,
    );

    expect(result.kind, SessionCommandResultKind.succeeded);
    expect(waits, const [
      Duration(seconds: 3),
      Duration(seconds: 3),
      Duration(seconds: 3),
    ]);
  });

  test('network uncertainty retries at 1, 2, 4 and checks state once',
      () async {
    final value = reducer();
    final waits = <Duration>[];
    final ids = <Object?>[];
    var reads = 0;
    final controller = SessionCommandController(
      reducer: value,
      delay: (duration) async => waits.add(duration),
    );
    final result = await controller.execute(
      request: request(value),
      send: (body, _) async {
        ids.add(body['command_id']);
        throw StateError('Сетевой разрыв');
      },
      readState: () async {
        reads += 1;
        return state(revision: 2, phase: 'reading', runId: 8);
      },
      isExpectedSuccess: (current) => current['question_run_id'] == 8,
    );

    expect(result.kind, SessionCommandResultKind.recoveredAfterNetwork);
    expect(waits, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ]);
    expect(ids, hasLength(4));
    expect(ids.toSet(), hasLength(1));
    expect(reads, 1);
  });

  test('context change during wait cancels the pending repeat', () async {
    final value = reducer();
    var sends = 0;
    final controller = SessionCommandController(
      reducer: value,
      delay: (_) async {
        value.apply(
          state(revision: 2, phase: 'reading', runId: 8),
          source: SessionStateSource.websocket,
        );
      },
    );
    final result = await controller.execute(
      request: request(value),
      send: (_, __) async {
        sends += 1;
        throw apiError(429, 'rate_limited', retryAfter: 1);
      },
      readState: () async => fail('Чтение не требуется.'),
      isExpectedSuccess: (_) => false,
    );

    expect(result.kind, SessionCommandResultKind.cancelled);
    expect(sends, 1);
  });

  test('new command aborts a hung transport and ignores its late 200',
      () async {
    final value = reducer();
    final firstResponse = Completer<Map<String, dynamic>>();
    var active = 0;
    var maxActive = 0;
    var sends = 0;
    final controller = SessionCommandController(reducer: value);

    Future<Map<String, dynamic>> send(
      Map<String, dynamic> body,
      Future<void> abortTrigger,
    ) async {
      sends += 1;
      active += 1;
      if (active > maxActive) maxActive = active;
      try {
        if (body['command_id'] == 'first-command') {
          return await Future.any([
            firstResponse.future,
            abortTrigger.then<Map<String, dynamic>>(
              (_) => throw StateError('Запрос отменён.'),
            ),
          ]);
        }
        return state(revision: 2, phase: 'reading', runId: 8);
      } finally {
        active -= 1;
      }
    }

    final first = controller.execute(
      request: request(value, commandId: 'first-command'),
      send: send,
      readState: () async => fail('Чтение не требуется.'),
      isExpectedSuccess: (_) => false,
    );
    await Future<void>.delayed(Duration.zero);
    final second = controller.execute(
      request: request(value, commandId: 'second-command'),
      send: send,
      readState: () async => fail('Чтение не требуется.'),
      isExpectedSuccess: (_) => false,
    );
    final results = await Future.wait([first, second]);
    firstResponse.complete(state(revision: 99, phase: 'final', runId: 99));
    await Future<void>.delayed(Duration.zero);

    expect(results[0].kind, SessionCommandResultKind.cancelled);
    expect(results[1].kind, SessionCommandResultKind.succeeded);
    expect(sends, 2);
    expect(maxActive, 1);
    expect(value.state['state_revision'], 2);
  });
}
