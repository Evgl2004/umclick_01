import 'dart:async';

import '../api/api_client.dart';
import 'session_state_reducer.dart';

typedef CommandDelay = Future<void> Function(Duration duration);
typedef CommandSender = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> body,
  Future<void> abortTrigger,
);

enum SessionCommandResultKind {
  succeeded,
  recoveredAfterNetwork,
  stateConflict,
  conflict,
  cancelled,
  temporarilyFailed,
  uncertain,
  protocolError,
}

class SessionCommandRequest {
  SessionCommandRequest({
    required this.kind,
    required this.commandId,
    required this.context,
  }) : body = Map.unmodifiable({
          'command_id': commandId,
          'state_revision': context.revision,
          'phase': context.phase,
          'question_run_id': context.questionRunId,
        });

  final String kind;
  final String commandId;
  final SessionStateContext context;
  final Map<String, dynamic> body;
}

class SessionCommandResult {
  const SessionCommandResult({
    required this.kind,
    required this.request,
    required this.automaticRetries,
    this.state,
    this.error,
  });

  final SessionCommandResultKind kind;
  final SessionCommandRequest request;
  final int automaticRetries;
  final Map<String, dynamic>? state;
  final Object? error;
}

class SessionCommandController {
  SessionCommandController({
    required this.reducer,
    CommandDelay? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  final SessionStateReducer reducer;
  final CommandDelay _delay;
  int _generation = 0;
  Completer<void>? _cancelSignal;
  Future<Map<String, dynamic>>? _activeTransport;

  void cancelPending() {
    _generation += 1;
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<SessionCommandResult> execute({
    required SessionCommandRequest request,
    required CommandSender send,
    required Future<Map<String, dynamic>> Function() readState,
    required bool Function(Map<String, dynamic> state) isExpectedSuccess,
  }) async {
    cancelPending();
    final operationGeneration = _generation;
    final cancelSignal = Completer<void>();
    _cancelSignal = cancelSignal;
    var automaticRetries = 0;
    Object? lastError;

    bool cancelled() =>
        operationGeneration != _generation ||
        !reducer.matchesContext(request.context);

    while (true) {
      if (cancelled()) {
        return _result(
          SessionCommandResultKind.cancelled,
          request,
          automaticRetries,
          error: lastError,
        );
      }
      try {
        final response = await _sendSerially(
          send,
          request.body,
          cancelSignal.future,
        );
        if (cancelled()) {
          return _result(
            SessionCommandResultKind.cancelled,
            request,
            automaticRetries,
          );
        }
        final reduction = reducer.apply(
          response,
          source: SessionStateSource.command,
        );
        return _result(
          reduction.accepted
              ? SessionCommandResultKind.succeeded
              : SessionCommandResultKind.protocolError,
          request,
          automaticRetries,
          state: reduction.state,
          error: reduction.reason,
        );
      } on ApiException catch (error) {
        if (cancelled()) {
          return _result(
            SessionCommandResultKind.cancelled,
            request,
            automaticRetries,
            error: error,
          );
        }
        lastError = error;
        if (error.statusCode == 409 && error.code == 'state_conflict') {
          final state = error.state;
          final reduction = state == null
              ? null
              : reducer.apply(state, source: SessionStateSource.command);
          return _result(
            reduction?.accepted == true
                ? SessionCommandResultKind.stateConflict
                : SessionCommandResultKind.protocolError,
            request,
            automaticRetries,
            state: reduction?.state,
            error: error,
          );
        }
        if (error.statusCode == 409) {
          Map<String, dynamic>? state;
          try {
            final fresh = await readState();
            if (cancelled()) {
              return _result(
                SessionCommandResultKind.cancelled,
                request,
                automaticRetries,
                error: error,
              );
            }
            final reduction = reducer.apply(
              fresh,
              source: SessionStateSource.accountRead,
            );
            if (reduction.accepted) state = reduction.state;
          } catch (_) {
            // Обычный конфликт допускает только одну попытку чтения состояния.
          }
          return _result(
            SessionCommandResultKind.conflict,
            request,
            automaticRetries,
            state: state,
            error: error,
          );
        }

        final isRateLimit = error.statusCode == 429;
        final isUnavailable = error.statusCode == 503;
        if (!isRateLimit && !isUnavailable) rethrow;
        if (automaticRetries >= 3) {
          return _result(
            SessionCommandResultKind.temporarilyFailed,
            request,
            automaticRetries,
            error: error,
          );
        }
        final wait = Duration(
          seconds: error.retryAfter ?? (isRateLimit ? 1 : 3),
        );
        automaticRetries += 1;
        await Future.any([_delay(wait), cancelSignal.future]);
      } catch (error) {
        if (cancelled()) {
          return _result(
            SessionCommandResultKind.cancelled,
            request,
            automaticRetries,
            error: error,
          );
        }
        lastError = error;
        if (automaticRetries < 3) {
          final wait = Duration(seconds: 1 << automaticRetries);
          automaticRetries += 1;
          await Future.any([_delay(wait), cancelSignal.future]);
          continue;
        }

        try {
          final fresh = await readState();
          if (cancelled()) {
            return _result(
              SessionCommandResultKind.cancelled,
              request,
              automaticRetries,
              error: error,
            );
          }
          final reduction = reducer.apply(
            fresh,
            source: SessionStateSource.accountRead,
          );
          if (reduction.accepted && isExpectedSuccess(reduction.state)) {
            return _result(
              SessionCommandResultKind.recoveredAfterNetwork,
              request,
              automaticRetries,
              state: reduction.state,
              error: error,
            );
          }
          if (!reducer.matchesContext(request.context)) {
            return _result(
              SessionCommandResultKind.cancelled,
              request,
              automaticRetries,
              state: reduction.state,
              error: error,
            );
          }
        } catch (_) {
          // Неудачное контрольное чтение не доказывает исход команды.
        }
        return _result(
          SessionCommandResultKind.uncertain,
          request,
          automaticRetries,
          error: error,
        );
      }
    }
  }

  Future<Map<String, dynamic>> _sendSerially(
    CommandSender send,
    Map<String, dynamic> body,
    Future<void> abortTrigger,
  ) async {
    while (true) {
      final active = _activeTransport;
      if (active != null) {
        try {
          await active;
        } catch (_) {
          // Отмена или ошибка прежней команды обрабатывается её владельцем.
        }
        continue;
      }
      final transport = send(body, abortTrigger);
      _activeTransport = transport;
      try {
        return await transport;
      } finally {
        if (identical(_activeTransport, transport)) {
          _activeTransport = null;
        }
      }
    }
  }

  SessionCommandResult _result(
    SessionCommandResultKind kind,
    SessionCommandRequest request,
    int automaticRetries, {
    Map<String, dynamic>? state,
    Object? error,
  }) {
    return SessionCommandResult(
      kind: kind,
      request: request,
      automaticRetries: automaticRetries,
      state: state,
      error: error,
    );
  }
}
