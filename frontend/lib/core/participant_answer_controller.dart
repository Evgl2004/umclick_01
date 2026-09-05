import 'dart:async';

import '../api/api_client.dart';
import 'session_state_reducer.dart';

typedef AnswerDelay = Future<void> Function(Duration duration);
typedef AnswerSender = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> body,
  Future<void> abortTrigger,
);

enum ParticipantAnswerResultKind {
  submitted,
  recoveredAfterNetwork,
  conflict,
  cancelled,
  temporarilyFailed,
  uncertain,
}

class ParticipantAnswerRequest {
  ParticipantAnswerRequest({
    required this.submissionId,
    required this.questionId,
    required this.choiceId,
    required this.context,
  }) : body = Map.unmodifiable({
          'question_id': questionId,
          'choice_id': choiceId,
          'submission_id': submissionId,
        });

  final String submissionId;
  final int questionId;
  final int choiceId;
  final SessionStateContext context;
  final Map<String, dynamic> body;
}

class ParticipantAnswerResult {
  const ParticipantAnswerResult({
    required this.kind,
    required this.request,
    required this.automaticRetries,
    this.state,
    this.error,
  });

  final ParticipantAnswerResultKind kind;
  final ParticipantAnswerRequest request;
  final int automaticRetries;
  final Map<String, dynamic>? state;
  final Object? error;
}

class _LocalAnswerSelection {
  _LocalAnswerSelection({
    required this.request,
    required this.minimumExpectedVersion,
  });

  final ParticipantAnswerRequest request;
  final int minimumExpectedVersion;
  bool deliveryAcknowledged = false;
}

class ParticipantAnswerController {
  ParticipantAnswerController({
    required this.reducer,
    AnswerDelay? delay,
  }) : _delay = delay ?? ((duration) => Future<void>.delayed(duration));

  final SessionStateReducer reducer;
  final AnswerDelay _delay;
  int _generation = 0;
  Completer<void>? _cancelSignal;
  Future<Map<String, dynamic>>? _activeTransport;
  _LocalAnswerSelection? _localSelection;
  SessionStateContext? _thresholdContext;
  int _lastIssuedThreshold = 0;

  bool get hasLocalSelection => _localSelection != null;

  int? get minimumExpectedAnswerVersion =>
      _localSelection?.minimumExpectedVersion;

  int? get visibleSelectedChoiceId {
    final local = _localSelection;
    if (local != null && reducer.matchesContext(local.request.context)) {
      return local.request.choiceId;
    }
    final answer = reducer.state['answer'];
    return answer is Map ? answer['selected_choice_id'] as int? : null;
  }

  bool get visibleHasAnswer {
    final local = _localSelection;
    if (local != null && reducer.matchesContext(local.request.context)) {
      return local.deliveryAcknowledged;
    }
    final answer = reducer.state['answer'];
    return answer is Map && answer['has_answer'] == true;
  }

  SessionStateReduction applyState(
    Map<String, dynamic> candidate, {
    required SessionStateSource source,
  }) {
    final reduction = reducer.apply(candidate, source: source);
    if (!reduction.accepted) return reduction;

    final local = _localSelection;
    if (local == null) return reduction;
    if (!reducer.matchesContext(local.request.context)) {
      _clearLocalSelection();
      _thresholdContext = null;
      _lastIssuedThreshold = 0;
      return reduction;
    }
    final participantRoleState = source == SessionStateSource.participantRead ||
        source == SessionStateSource.participantWebsocket;
    if (!participantRoleState) return reduction;

    final answer = reduction.state['answer'];
    if (answer is! Map) return reduction;
    final finalized = reduction.state['is_answer_revealed'] == true &&
        answer.containsKey('final');
    final answerVersion = answer['answer_version'];
    if (finalized ||
        answerVersion is int && answerVersion >= local.minimumExpectedVersion) {
      _clearLocalSelection();
    }
    return reduction;
  }

  void cancelPending() {
    _generation += 1;
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<ParticipantAnswerResult> submit({
    required ParticipantAnswerRequest request,
    required AnswerSender send,
    required Future<Map<String, dynamic>> Function() readState,
  }) async {
    cancelPending();
    _beginLocalSelection(request);
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
          ParticipantAnswerResultKind.cancelled,
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
            ParticipantAnswerResultKind.cancelled,
            request,
            automaticRetries,
          );
        }
        _acknowledgeLocalSelection(request);
        return _result(
          ParticipantAnswerResultKind.submitted,
          request,
          automaticRetries,
          state: response,
        );
      } on ApiException catch (error) {
        if (cancelled()) {
          return _result(
            ParticipantAnswerResultKind.cancelled,
            request,
            automaticRetries,
            error: error,
          );
        }
        lastError = error;
        if (error.statusCode == 409) {
          final state = await _readOnce(readState, cancelled: cancelled);
          if (cancelled()) {
            return _result(
              ParticipantAnswerResultKind.cancelled,
              request,
              automaticRetries,
              error: error,
            );
          }
          _clearLocalSelectionFor(request);
          return _result(
            ParticipantAnswerResultKind.conflict,
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
            ParticipantAnswerResultKind.temporarilyFailed,
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
            ParticipantAnswerResultKind.cancelled,
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

        final state = await _readOnce(readState, cancelled: cancelled);
        if (cancelled()) {
          return _result(
            ParticipantAnswerResultKind.cancelled,
            request,
            automaticRetries,
            state: state,
            error: error,
          );
        }
        final answer = state?['answer'];
        if (answer is Map<String, dynamic> &&
            answer['selected_choice_id'] == request.choiceId) {
          _acknowledgeLocalSelection(request);
          return _result(
            ParticipantAnswerResultKind.recoveredAfterNetwork,
            request,
            automaticRetries,
            state: state,
            error: error,
          );
        }
        if (!reducer.matchesContext(request.context)) {
          return _result(
            ParticipantAnswerResultKind.cancelled,
            request,
            automaticRetries,
            state: state,
            error: error,
          );
        }
        return _result(
          ParticipantAnswerResultKind.uncertain,
          request,
          automaticRetries,
          state: state,
          error: error,
        );
      }
    }
  }

  Future<Map<String, dynamic>> _sendSerially(
    AnswerSender send,
    Map<String, dynamic> body,
    Future<void> abortTrigger,
  ) async {
    while (true) {
      final active = _activeTransport;
      if (active != null) {
        try {
          await active;
        } catch (_) {
          // Ошибка предыдущего намерения обрабатывается его владельцем.
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

  Future<Map<String, dynamic>?> _readOnce(
      Future<Map<String, dynamic>> Function() readState,
      {bool Function()? cancelled}) async {
    try {
      final state = await readState();
      if (cancelled?.call() == true) return null;
      final reduction = applyState(
        state,
        source: SessionStateSource.participantRead,
      );
      return reduction.accepted ? reduction.state : null;
    } catch (_) {
      return null;
    }
  }

  void _beginLocalSelection(ParticipantAnswerRequest request) {
    final current = _localSelection;
    if (current != null &&
        current.request.submissionId == request.submissionId &&
        current.request.context.sameAs(request.context)) {
      return;
    }

    if (!(_thresholdContext?.sameAs(request.context) ?? false)) {
      _thresholdContext = request.context;
      _lastIssuedThreshold = 0;
    }
    final answer = reducer.state['answer'];
    final serverVersion = answer is Map && answer['answer_version'] is int
        ? answer['answer_version'] as int
        : 0;
    final baseline = serverVersion > _lastIssuedThreshold
        ? serverVersion
        : _lastIssuedThreshold;
    _lastIssuedThreshold = baseline + 1;
    _localSelection = _LocalAnswerSelection(
      request: request,
      minimumExpectedVersion: _lastIssuedThreshold,
    );
  }

  void _acknowledgeLocalSelection(ParticipantAnswerRequest request) {
    final local = _localSelection;
    if (local != null &&
        local.request.submissionId == request.submissionId &&
        local.request.context.sameAs(request.context)) {
      local.deliveryAcknowledged = true;
    }
  }

  void _clearLocalSelectionFor(ParticipantAnswerRequest request) {
    final local = _localSelection;
    if (local != null &&
        local.request.submissionId == request.submissionId &&
        local.request.context.sameAs(request.context)) {
      _clearLocalSelection();
    }
  }

  void _clearLocalSelection() {
    _localSelection = null;
  }

  ParticipantAnswerResult _result(
    ParticipantAnswerResultKind kind,
    ParticipantAnswerRequest request,
    int automaticRetries, {
    Map<String, dynamic>? state,
    Object? error,
  }) {
    return ParticipantAnswerResult(
      kind: kind,
      request: request,
      automaticRetries: automaticRetries,
      state: state,
      error: error,
    );
  }
}
