import 'session_uuid.dart';

enum SessionStateSource {
  accountRead,
  participantRead,
  participantWebsocket,
  displayRead,
  websocket,
  command,
}

class SessionStateContext {
  const SessionStateContext({
    required this.revision,
    required this.status,
    required this.phase,
    required this.questionRunId,
  });

  final int revision;
  final String status;
  final String phase;
  final int? questionRunId;

  bool sameAs(SessionStateContext other) =>
      revision == other.revision &&
      status == other.status &&
      phase == other.phase &&
      questionRunId == other.questionRunId;
}

class SessionStateReduction {
  const SessionStateReduction({
    required this.accepted,
    required this.contextChanged,
    required this.state,
    this.reason,
  });

  final bool accepted;
  final bool contextChanged;
  final Map<String, dynamic> state;
  final String? reason;
}

class SessionStateReducer {
  SessionStateReducer(String sessionUuid)
      : sessionUuid = normalizeSessionUuid(sessionUuid);

  final String sessionUuid;
  Map<String, dynamic> _state = <String, dynamic>{};

  Map<String, dynamic> get state => Map.unmodifiable(_state);
  bool get hasState => _state.isNotEmpty;

  SessionStateContext? get context => hasState ? _contextFrom(_state) : null;

  bool matchesContext(SessionStateContext expected) =>
      context?.sameAs(expected) ?? false;

  SessionStateReduction apply(
    Map<String, dynamic> candidate, {
    required SessionStateSource source,
  }) {
    if (candidate['schema_version'] != 2) {
      return _rejected('Поддерживается только схема состояния 2.');
    }
    String candidateUuid;
    try {
      candidateUuid = normalizeSessionUuid(
        candidate['session_id']?.toString() ?? '',
      );
    } on FormatException {
      return _rejected('Снимок не содержит корректный UUID сессии.');
    }
    if (candidateUuid != sessionUuid) {
      return _rejected('Снимок относится к другой сессии.');
    }
    final revision = candidate['state_revision'];
    if (revision is! int || revision < 0) {
      return _rejected('Снимок не содержит корректную ревизию.');
    }

    if (!hasState) {
      _state = Map<String, dynamic>.from(candidate);
      if (!_isParticipantRoleSource(source)) {
        _state.remove('answer');
      }
      return SessionStateReduction(
        accepted: true,
        contextChanged: true,
        state: state,
      );
    }

    final currentRevision = _state['state_revision'] as int;
    if (revision < currentRevision) {
      return _rejected('Устаревшая ревизия состояния.');
    }

    final previousContext = _contextFrom(_state);
    final sameStableContext = _sameStableContext(_state, candidate);
    if (revision == currentRevision) {
      if (!sameStableContext) {
        return SessionStateReduction(
          accepted: true,
          contextChanged: false,
          state: state,
        );
      }

      final next = Map<String, dynamic>.from(_state)..addAll(candidate);
      for (final field in const [
        'participants_count',
        'answered_participants_count',
      ]) {
        final currentValue = _state[field];
        final candidateValue = candidate[field];
        if (currentValue is int && candidateValue is int) {
          next[field] =
              currentValue > candidateValue ? currentValue : candidateValue;
        }
      }

      _preserveOrReplaceParticipantAnswer(next, candidate, source);
      _state = next;
      return SessionStateReduction(
        accepted: true,
        contextChanged: false,
        state: state,
      );
    }

    final next = Map<String, dynamic>.from(_state)..addAll(candidate);
    for (final field in const ['reveal', 'leaderboard']) {
      if (!candidate.containsKey(field)) next.remove(field);
    }
    final sameQuestion = _sameQuestionContext(_state, candidate);
    if (!sameQuestion) {
      for (final field in const [
        'answer',
        'current_question',
        'display_question',
      ]) {
        if (!candidate.containsKey(field)) next.remove(field);
      }
    }
    _preserveOrReplaceParticipantAnswer(
      next,
      candidate,
      source,
      preserveExisting: sameQuestion,
    );
    _state = next;
    final nextContext = _contextFrom(_state);
    return SessionStateReduction(
      accepted: true,
      contextChanged: !previousContext.sameAs(nextContext),
      state: state,
    );
  }

  void _preserveOrReplaceParticipantAnswer(
    Map<String, dynamic> next,
    Map<String, dynamic> candidate,
    SessionStateSource source, {
    bool preserveExisting = true,
  }) {
    if (_isParticipantRoleSource(source)) {
      if (!candidate.containsKey('answer')) next.remove('answer');
      if (!preserveExisting) return;

      final currentAnswer = _answerMap(_state['answer']);
      final candidateAnswer = _answerMap(candidate['answer']);
      if (currentAnswer == null || candidateAnswer == null) return;

      if (_isFinalParticipantAnswer(candidate, candidateAnswer)) return;
      if (_isFinalParticipantAnswer(_state, currentAnswer)) {
        next['answer'] = Map<String, dynamic>.from(currentAnswer);
        next['is_answer_revealed'] = true;
        if (_state.containsKey('reveal')) next['reveal'] = _state['reveal'];
        return;
      }

      final currentVersion = currentAnswer['answer_version'];
      final candidateVersion = candidateAnswer['answer_version'];
      if (currentVersion is int &&
          (candidateVersion is! int || candidateVersion < currentVersion)) {
        next['answer'] = Map<String, dynamic>.from(currentAnswer);
      }
      return;
    }
    if (preserveExisting && _state.containsKey('answer')) {
      next['answer'] = _state['answer'];
    } else {
      next.remove('answer');
    }
  }

  bool _isParticipantRoleSource(SessionStateSource source) =>
      source == SessionStateSource.participantRead ||
      source == SessionStateSource.participantWebsocket;

  Map<String, dynamic>? _answerMap(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  bool _isFinalParticipantAnswer(
    Map<String, dynamic> state,
    Map<String, dynamic> answer,
  ) =>
      state['is_answer_revealed'] == true && answer['final'] is Map;

  bool _sameStableContext(
    Map<String, dynamic> current,
    Map<String, dynamic> candidate,
  ) =>
      candidate['status'] == current['status'] &&
      candidate['phase'] == current['phase'] &&
      _sameQuestionContext(current, candidate);

  bool _sameQuestionContext(
    Map<String, dynamic> current,
    Map<String, dynamic> candidate,
  ) =>
      candidate['question_run_id'] == current['question_run_id'] &&
      _questionId(candidate) == _questionId(current);

  int? _questionId(Map<String, dynamic> value) {
    final direct = value['question_id'];
    if (direct is int) return direct;
    for (final field in const ['current_question', 'display_question']) {
      final question = value[field];
      if (question is Map && question['id'] is int) {
        return question['id'] as int;
      }
    }
    return null;
  }

  SessionStateReduction _rejected(String reason) {
    return SessionStateReduction(
      accepted: false,
      contextChanged: false,
      state: state,
      reason: reason,
    );
  }

  SessionStateContext _contextFrom(Map<String, dynamic> value) {
    return SessionStateContext(
      revision: value['state_revision'] as int,
      status: value['status']?.toString() ?? '',
      phase: value['phase']?.toString() ?? '',
      questionRunId: value['question_run_id'] as int?,
    );
  }
}
