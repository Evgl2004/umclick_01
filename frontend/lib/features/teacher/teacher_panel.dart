import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../core/app_config.dart';
import '../../core/countdown_ticker.dart';
import '../../core/csv_download.dart';
import '../../core/display_window.dart';
import '../../core/live_event_log.dart';
import '../../core/live_socket_supervisor.dart';
import '../../core/ranking_format.dart';
import '../../core/request_id.dart';
import '../../core/role_access_token_store.dart';
import '../../core/session_command_controller.dart';
import '../../core/session_state_reducer.dart';
import '../../core/session_uuid.dart';
import '../../core/value_utils.dart';
import '../../l10n/app_strings.dart';
import '../../shared/user_error_text.dart';
import '../../shared/widgets/app_surfaces.dart';
import 'quiz_draft.dart';
import 'quiz_draft_mapper.dart';
import 'teacher_auth_session.dart';
import 'widgets/quiz_preview_dialog.dart';
import 'widgets/teacher_auth_card.dart';
import 'widgets/teacher_live_events_card.dart';
import 'widgets/teacher_live_session_card.dart';
import 'widgets/teacher_quiz_builder_card.dart';
import 'widgets/teacher_session_setup_card.dart';

bool hasNextQuestionInSessionQuiz({
  required Map<String, dynamic> session,
  required Map<String, dynamic>? currentQuestion,
}) {
  if (currentQuestion == null) return false;
  final currentQuestionId = asInt(currentQuestion['id'], -1);
  if (currentQuestionId < 0) return false;

  final quiz = mapOrNull(session['quiz']);
  final rawQuestions = quiz?['questions'];
  if (rawQuestions is! List) return false;
  final questions = rawQuestions
      .map(mapOrNull)
      .whereType<Map<String, dynamic>>()
      .toList(growable: false);
  final currentIndex = questions.indexWhere(
    (question) => asInt(question['id'], -1) == currentQuestionId,
  );
  return currentIndex >= 0 && currentIndex + 1 < questions.length;
}

typedef TeacherApiClientFactory = ApiClient Function(
  String baseUrl, {
  String? accessToken,
});

class TeacherPanel extends StatefulWidget {
  const TeacherPanel({
    super.key,
    this.apiClientFactory,
    this.sessionSocketOpener,
  });

  final TeacherApiClientFactory? apiClientFactory;
  final SupervisedSocketOpener? sessionSocketOpener;

  @override
  State<TeacherPanel> createState() => _TeacherPanelState();
}

class _TeacherPanelState extends State<TeacherPanel> {
  final _apiController = TextEditingController(text: defaultApiBaseUrl);
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailController = TextEditingController();
  final _signupCodeController = TextEditingController();
  final _quizTitleController = TextEditingController();
  final _quizDescriptionController = TextEditingController();
  final _readingTimeController = TextEditingController(text: '15');
  final _resultsTimeController = TextEditingController(text: '10');
  final _authSessionStore = const TeacherAuthSessionStore();
  final _roleAccessStore = const RoleAccessTokenStore();
  final _quizDraftMapper = const QuizDraftMapper();
  final _tokenRefresh = SingleFlightTokenRefresh();

  final List<QuizDraftQuestion> _draftQuestions = [];
  int? _editingQuizId;
  int? _editingQuizRevision;
  bool _editingQuizArchived = false;

  List<dynamic> _quizzes = [];
  List<dynamic> _sessionHistory = [];
  int? _selectedQuizId;
  bool _archiveMode = false;
  Map<String, dynamic>? _session;
  Map<String, dynamic>? _teacher;
  Map<String, dynamic>? _activeQuestion;
  Map<String, dynamic>? _revealPayload;
  String? _accessToken;
  String? _refreshToken;
  String? _pendingDisplayToken;
  String? _pendingDisplayGrantId;
  String? _pendingDisplaySessionUuid;
  bool _displayActionInProgress = false;
  SessionStateReducer? _sessionStateReducer;
  SessionCommandController? _sessionCommandController;
  SessionCommandRequest? _uncertainCommand;
  SessionCommandRequest? _latestCommandRequest;
  bool _loading = false;
  String? _error;
  int _answeredCount = 0;

  LiveSocketSupervisor? _sessionSocketSupervisor;
  bool _wsConnected = false;
  final _countdownTicker = const CountdownTicker();
  final _eventLog = const LiveEventLog();
  final List<String> _events = [];

  Timer? _questionTimer;
  String _questionTimeLeftLabel = '--:--';
  bool _restoringSession = true;
  bool _questionOnlyOnDisplay = false;
  bool _showChoicesOnParticipant = true;

  ApiClient _client({bool withToken = true}) {
    final accessToken = withToken ? _accessToken : null;
    if (widget.apiClientFactory != null) {
      return widget.apiClientFactory!(
        _apiController.text.trim(),
        accessToken: accessToken,
      );
    }
    return ApiClient(
      _apiController.text.trim(),
      accessToken: accessToken,
    );
  }

  bool get _isLoggedIn => _accessToken != null && _accessToken!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _resetQuizDraft(withState: false);
    _restoreAuthSession();
  }

  @override
  void dispose() {
    _questionTimer?.cancel();
    _sessionCommandController?.cancelPending();
    _closeSessionSocket();
    _disposeQuizDraft();
    _apiController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _emailController.dispose();
    _signupCodeController.dispose();
    _quizTitleController.dispose();
    _quizDescriptionController.dispose();
    _readingTimeController.dispose();
    _resultsTimeController.dispose();
    super.dispose();
  }

  void _appendEvent(String text) {
    if (!mounted) return;
    setState(() {
      _eventLog.prepend(_events, text);
    });
  }

  void _disposeQuizDraft() {
    for (final question in _draftQuestions) {
      question.dispose();
    }
    _draftQuestions.clear();
  }

  void _resetQuizDraft({bool withState = true}) {
    void apply() {
      _disposeQuizDraft();
      _editingQuizId = null;
      _editingQuizRevision = null;
      _editingQuizArchived = false;
      _quizTitleController.clear();
      _quizDescriptionController.clear();
      _readingTimeController.text = '15';
      _resultsTimeController.text = '10';
      _questionOnlyOnDisplay = false;
      _showChoicesOnParticipant = true;
      _draftQuestions.add(_quizDraftMapper.createQuestion());
    }

    if (withState && mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  Map<String, dynamic>? _quizById(int quizId) {
    for (final rawQuiz in _quizzes) {
      final quiz = mapOrNull(rawQuiz);
      if (quiz == null) continue;
      if (asInt(quiz['id'], -1) == quizId) {
        return quiz;
      }
    }
    return null;
  }

  void _loadQuizDraftFromMap(Map<String, dynamic> quiz) {
    setState(() {
      _disposeQuizDraft();

      final draft = _quizDraftMapper.fromMap(quiz);
      _editingQuizId = draft.quizId;
      _editingQuizRevision = draft.contentRevision;
      _editingQuizArchived = quiz['archived_at'] != null;
      if (_editingQuizId != null) {
        _selectedQuizId = _editingQuizId;
      }
      _quizTitleController.text = draft.title;
      _quizDescriptionController.text = draft.description;
      _questionOnlyOnDisplay = draft.displaySettings.questionOnlyOnDisplay;
      _showChoicesOnParticipant =
          draft.displaySettings.showChoicesOnParticipant;
      _readingTimeController.text = '${draft.displaySettings.readingTimeSec}';
      _resultsTimeController.text = '${draft.displaySettings.resultsTimeSec}';
      _draftQuestions.addAll(draft.questions);
    });
  }

  void _setQuestionOnlyOnDisplay(bool value) {
    setState(() {
      _questionOnlyOnDisplay = value;
    });
  }

  void _setShowChoicesOnParticipant(bool value) {
    setState(() {
      _showChoicesOnParticipant = value;
    });
  }

  void _loadSelectedQuizIntoDraft() {
    final quizId = _selectedQuizId;
    if (quizId == null) return;
    final quiz = _quizById(quizId);
    if (quiz == null) return;
    _loadQuizDraftFromMap(quiz);
    _appendEvent('Quiz #$quizId loaded into builder.');
  }

  void _addDraftQuestion() {
    setState(() {
      _draftQuestions.add(_quizDraftMapper.createQuestion());
    });
  }

  void _removeDraftQuestion(int questionIndex) {
    if (_draftQuestions.length <= 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appText(AppText.quizRequiresOneQuestionSnack))),
      );
      return;
    }

    setState(() {
      final removed = _draftQuestions.removeAt(questionIndex);
      removed.dispose();
    });
  }

  void _addDraftChoice(QuizDraftQuestion question) {
    setState(() {
      question.choices.add(QuizDraftChoice());
    });
  }

  void _removeDraftChoice(QuizDraftQuestion question, int choiceIndex) {
    if (question.choices.length <= 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(appText(AppText.questionRequiresTwoChoicesSnack))),
      );
      return;
    }

    setState(() {
      final removed = question.choices.removeAt(choiceIndex);
      removed.dispose();
      if (!question.choices.any((choice) => choice.isCorrect)) {
        question.choices.first.isCorrect = true;
      }
    });
  }

  void _setDraftCorrectChoice(
      QuizDraftQuestion question, int selectedChoiceIndex) {
    setState(() {
      for (var i = 0; i < question.choices.length; i++) {
        question.choices[i].isCorrect = i == selectedChoiceIndex;
      }
    });
  }

  Future<void> _persistAuthSession() async {
    await _authSessionStore.persist(
      accessToken: _accessToken,
      refreshToken: _refreshToken,
      apiBaseUrl: _apiController.text.trim(),
      username: _usernameController.text.trim(),
    );
  }

  Future<void> _clearPersistedAuthSession() async {
    await _authSessionStore.clearTokens();
  }

  Future<void> _restoreAuthSession() async {
    try {
      final savedSession = await _authSessionStore.restore();

      if (savedSession.apiBaseUrl != null &&
          savedSession.apiBaseUrl!.isNotEmpty) {
        _apiController.text = savedSession.apiBaseUrl!;
      }
      if (savedSession.username != null && savedSession.username!.isNotEmpty) {
        _usernameController.text = savedSession.username!;
      }

      if (!savedSession.hasAccessToken) {
        if (mounted) {
          setState(() {
            _restoringSession = false;
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _accessToken = savedSession.accessToken;
          _refreshToken = savedSession.refreshToken;
        });
      }

      final me = await _runTeacherRequest((client) => client.getMe());
      final quizzes = await _runTeacherRequest((client) => client.getQuizzes());
      final sessions =
          await _runTeacherRequest((client) => client.getSessions());

      if (mounted) {
        setState(() {
          _teacher = me;
          _quizzes = quizzes;
          _sessionHistory = sessions;
          if (_quizzes.isNotEmpty) {
            _selectedQuizId = _selectedQuizId ?? _quizzes.first['id'] as int;
          }
          _restoringSession = false;
        });
      }
      _appendEvent('Teacher session restored from local storage.');
    } catch (e) {
      await _clearPersistedAuthSession();
      if (mounted) {
        setState(() {
          _accessToken = null;
          _refreshToken = null;
          _teacher = null;
          _quizzes = [];
          _sessionHistory = [];
          _selectedQuizId = null;
          _archiveMode = false;
          _restoringSession = false;
        });
      }
      _appendEvent('Stored session is invalid and was cleared.');
    }
  }

  Future<bool> _refreshAccessToken() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      return false;
    }

    try {
      final payload = await _client(withToken: false).refreshTeacherToken(
        refreshToken: refreshToken,
      );
      final newAccessToken = payload['access'] as String?;
      final rotatedRefresh = payload['refresh'] as String?;

      if (newAccessToken == null || newAccessToken.isEmpty) {
        return false;
      }

      if (!mounted) return false;
      setState(() {
        _accessToken = newAccessToken;
        if (rotatedRefresh != null && rotatedRefresh.isNotEmpty) {
          _refreshToken = rotatedRefresh;
        }
      });
      await _persistAuthSession();
      _appendEvent('Access token refreshed automatically.');
      return true;
    } catch (_) {
      await _logout();
      if (!mounted) return false;
      setState(() {
        _error = appText(AppText.sessionExpiredLoginAgainError);
      });
      _appendEvent('Refresh token expired, teacher logged out.');
      return false;
    }
  }

  Future<T> _runTeacherRequest<T>(
      Future<T> Function(ApiClient client) request) async {
    final client = _client();
    final tokenUsed = client.accessToken;
    try {
      return await request(client);
    } on ApiException catch (e) {
      if (e.statusCode != 401 || tokenUsed == null || tokenUsed.isEmpty) {
        rethrow;
      }

      final refreshed = await _recoverAccessTokenFor(tokenUsed);
      if (!refreshed) {
        rethrow;
      }
      return request(_client());
    }
  }

  Future<bool> _recoverAccessTokenFor(String tokenUsed) {
    return _tokenRefresh.recover(
      tokenUsed: tokenUsed,
      currentToken: () => _accessToken,
      refresh: _refreshAccessToken,
    );
  }

  void _startTeacherTimer(DateTime? endsAt) {
    _questionTimer = _countdownTicker.restart(
      currentTimer: _questionTimer,
      endsAt: endsAt,
      isActive: () => mounted,
      onTick: (tick) {
        setState(() {
          _questionTimeLeftLabel = tick.label;
        });
      },
    );
  }

  Future<void> _connectSessionSocket(String sessionUuid) async {
    await _closeSessionSocket();
    final token = _accessToken;
    if (token == null || token.isEmpty) return;
    final url = _client().sessionWebSocketUrl(sessionUuid);

    try {
      _sessionSocketSupervisor = LiveSocketSupervisor(
        url: url,
        authentication: {
          'event': 'auth',
          'access_type': 'account',
          'token': token,
        },
        recoverAuthentication: (usedAuthentication) async {
          final tokenUsed = usedAuthentication['token']?.toString();
          if (tokenUsed == null || tokenUsed.isEmpty) return null;
          final refreshed = await _recoverAccessTokenFor(tokenUsed);
          final currentToken = _accessToken;
          if (!refreshed ||
              !mounted ||
              currentToken == null ||
              currentToken.isEmpty) {
            return null;
          }
          return {
            'event': 'auth',
            'access_type': 'account',
            'token': currentToken,
          };
        },
        onMessage: _handleTeacherSocketEvent,
        onInvalidPayload: () =>
            _appendEvent('Получено некорректное сообщение WebSocket.'),
        onTransportError: (_) {
          _appendEvent('Ошибка транспорта WebSocket.');
          _setSessionSocketConnected(false);
        },
        onConnectionError: (error) {
          final code = error['code']?.toString();
          _appendEvent(
            'Соединение отклонено: ${code ?? 'неизвестная причина'}',
          );
        },
        onStopped: (_, reason) {
          _appendEvent(
            'Повтор WebSocket прекращён: ${reason ?? 'соединение закрыто'}',
          );
          _setSessionSocketConnected(false);
        },
        opener: widget.sessionSocketOpener,
      );
      await _sessionSocketSupervisor!.start();
      _appendEvent('WebSocket преподавателя открыт, ожидается доступ.');
    } catch (e) {
      _setSessionSocketConnected(false);
      _appendEvent('Не удалось открыть WebSocket преподавателя.');
    }
  }

  Future<void> _closeSessionSocket() async {
    await _sessionSocketSupervisor?.stop();
    _sessionSocketSupervisor = null;
    _setSessionSocketConnected(false);
  }

  void _setSessionSocketConnected(bool connected) {
    if (!mounted) return;
    setState(() {
      _wsConnected = connected;
    });
  }

  void _initializeSessionRuntime(
    String sessionUuid,
    Map<String, dynamic> state,
  ) {
    final reducer = SessionStateReducer(sessionUuid);
    final reduction = reducer.apply(
      state,
      source: SessionStateSource.accountRead,
    );
    if (!reduction.accepted) {
      throw StateError(reduction.reason ?? 'Некорректное состояние сессии.');
    }
    _sessionStateReducer = reducer;
    _sessionCommandController = SessionCommandController(reducer: reducer);
    _uncertainCommand = null;
    _latestCommandRequest = null;
  }

  void _applyReducedTeacherState() {
    final reducer = _sessionStateReducer;
    if (reducer == null || !reducer.hasState) return;
    final state = reducer.state;
    final updated = Map<String, dynamic>.from(_session ?? const {});
    updated.addAll(state);
    updated['id'] = reducer.sessionUuid;
    setState(() {
      _session = updated;
      _activeQuestion = mapOrNull(state['current_question']);
      _revealPayload = mapOrNull(state['reveal']);
      _answeredCount = asInt(
        state['answered_participants_count'],
        _answeredCount,
      );
    });
    _startTeacherTimer(parseDateTimeLocal(
      state['question_ends_at'] ?? state['phase_ends_at'],
    ));
  }

  void _handleTeacherSocketEvent(Map<String, dynamic> message) {
    _setSessionSocketConnected(true);
    final event = message['event']?.toString() ?? 'unknown';
    final payload = mapOrNull(message['payload']) ?? <String, dynamic>{};

    final reducer = _sessionStateReducer;
    if (reducer == null) return;
    final reduction = reducer.apply(
      payload,
      source: SessionStateSource.websocket,
    );
    if (!reduction.accepted) {
      _appendEvent('Отклонено состояние WebSocket: ${reduction.reason}');
      return;
    }
    if (reduction.contextChanged) {
      _sessionCommandController?.cancelPending();
      _uncertainCommand = null;
      _latestCommandRequest = null;
    }
    _applyReducedTeacherState();
    if (payload['is_answer_revealed'] == true) {
      _questionTimer?.cancel();
      setState(() {
        _questionTimeLeftLabel = '00:00';
      });
    }
    final status = payload['status']?.toString();
    if (status == 'finished' || status == 'aborted') {
      _questionTimer?.cancel();
      unawaited(_refreshSessionHistory());
    }
    _appendEvent('Событие: $event');
  }

  Future<void> _registerTeacher() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _client(withToken: false).registerTeacher(
        username: _usernameController.text.trim(),
        password: _passwordController.text.trim(),
        email: _emailController.text.trim(),
        signupCode: _signupCodeController.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(appText(AppText.teacherRegisteredSnack))),
        );
      }
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _loginTeacher() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final tokenPayload = await _client(withToken: false).loginTeacher(
        username: _usernameController.text.trim(),
        password: _passwordController.text.trim(),
      );

      setState(() {
        _accessToken = tokenPayload['access'] as String?;
        _refreshToken = tokenPayload['refresh'] as String?;
      });

      await _persistAuthSession();
      await _loadMe();
      await _refreshQuizzes();
      await _refreshSessionHistory();
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _loadMe() async {
    if (!_isLoggedIn) return;
    try {
      final me = await _runTeacherRequest((client) => client.getMe());
      setState(() {
        _teacher = me;
      });
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _refreshQuizzes({
    int? selectQuizId,
    bool reportError = true,
    bool? archiveMode,
  }) async {
    if (!_isLoggedIn) {
      setState(() {
        _error = appText(AppText.teacherLoginRequiredError);
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final targetArchiveMode = archiveMode ?? _archiveMode;
      final quizzes = await _runTeacherRequest(
        (client) => client.getQuizzes(archived: targetArchiveMode),
      );
      final preferredQuizId = selectQuizId ?? _selectedQuizId;

      int? nextSelectedQuizId;
      if (quizzes.isNotEmpty) {
        final hasPreferred = preferredQuizId != null &&
            quizzes.any((rawQuiz) =>
                asInt(mapOrNull(rawQuiz)?['id'], -1) == preferredQuizId);
        nextSelectedQuizId = hasPreferred
            ? preferredQuizId
            : asInt(mapOrNull(quizzes.first)?['id'], 0);
      }

      setState(() {
        _quizzes = quizzes;
        _selectedQuizId = nextSelectedQuizId;
        _archiveMode = targetArchiveMode;
      });
    } catch (e) {
      if (!reportError) {
        rethrow;
      }
      if (mounted) {
        setState(() {
          _error = userErrorText(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _setQuizArchiveMode(bool archiveMode) async {
    if (archiveMode == _archiveMode) return;
    await _refreshQuizzes(archiveMode: archiveMode);
  }

  Future<void> _refreshSessionHistory() async {
    if (!_isLoggedIn) return;
    try {
      final sessions =
          await _runTeacherRequest((client) => client.getSessions());
      if (!mounted) return;
      setState(() {
        _sessionHistory = sessions;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _saveQuizDraft() async {
    if (_archiveMode || _editingQuizArchived) {
      return;
    }
    if (!_isLoggedIn) {
      setState(() {
        _error = appText(AppText.teacherLoginRequiredError);
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final payload = _quizDraftPayload();
      final editingQuizId = _editingQuizId;

      final savedQuiz = editingQuizId == null
          ? await _runTeacherRequest((client) => client.createQuiz(payload))
          : await _runTeacherRequest(
              (client) => client.updateQuiz(editingQuizId, payload));

      final savedQuizId = asInt(savedQuiz['id'], 0);
      _loadQuizDraftFromMap(savedQuiz);
      Object? refreshError;
      try {
        await _refreshQuizzes(
          selectQuizId: savedQuizId,
          reportError: false,
        );
      } catch (e) {
        refreshError = e;
      }
      if (refreshError != null && mounted) {
        final refreshErrorText = userErrorText(refreshError);
        setState(() {
          _error = appText(
            AppText.quizSavedListRefreshError,
            args: {'error': refreshErrorText},
          );
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              editingQuizId == null
                  ? appText(AppText.quizCreatedNextStepSnack)
                  : appText(AppText.quizUpdatedSnack),
            ),
          ),
        );
      }
      _appendEvent(
        editingQuizId == null
            ? 'Quiz #$savedQuizId created from builder.'
            : 'Quiz #$savedQuizId updated from builder.',
      );
    } on FormatException catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Map<String, dynamic> _quizDraftPayload() {
    return _quizDraftMapper.toPayload(
      contentRevision: _editingQuizId == null ? null : _editingQuizRevision,
      title: _quizTitleController.text,
      description: _quizDescriptionController.text,
      displaySettings: QuizDisplaySettings(
        questionOnlyOnDisplay: _questionOnlyOnDisplay,
        showChoicesOnParticipant: _showChoicesOnParticipant,
        readingTimeSec: asInt(_readingTimeController.text, 15),
        resultsTimeSec: asInt(_resultsTimeController.text, 10),
      ),
      questions: _draftQuestions,
    );
  }

  Future<void> _openQuizPreview() async {
    if (_archiveMode || _editingQuizArchived) return;
    try {
      final previewQuiz = _quizDraftPayload();
      if (!mounted) return;
      setState(() => _error = null);
      await showDialog<void>(
        context: context,
        builder: (context) => QuizPreviewDialog(quiz: previewQuiz),
      );
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() => _error = userErrorText(error));
    }
  }

  void _removeQuizFromCurrentList(int quizId) {
    final wasEditingRemovedQuiz = _editingQuizId == quizId;
    setState(() {
      _quizzes = _quizzes.where((rawQuiz) {
        return asInt(mapOrNull(rawQuiz)?['id'], -1) != quizId;
      }).toList(growable: false);
      _selectedQuizId =
          _quizzes.isEmpty ? null : asInt(mapOrNull(_quizzes.first)?['id'], 0);
    });
    if (wasEditingRemovedQuiz) {
      _resetQuizDraft();
    }
  }

  Future<void> _archiveSelectedQuiz() async {
    final quizId = _selectedQuizId;
    if (quizId == null || !_isLoggedIn || _archiveMode) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _runTeacherRequest((client) => client.archiveQuiz(quizId));
      _removeQuizFromCurrentList(quizId);
      _appendEvent('Викторина №$quizId перемещена в архив.');
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = userErrorText(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _restoreSelectedQuiz() async {
    final quizId = _selectedQuizId;
    if (quizId == null || !_isLoggedIn || !_archiveMode) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _runTeacherRequest((client) => client.restoreQuiz(quizId));
      _removeQuizFromCurrentList(quizId);
      _appendEvent('Викторина №$quizId восстановлена из архива.');
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = userErrorText(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _deleteSelectedQuiz() async {
    final quizId = _selectedQuizId;
    if (quizId == null || !_isLoggedIn) {
      return;
    }

    final quizTitle = _quizById(quizId)?['title']?.toString() ??
        appText(AppText.untitledQuiz);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(appText(AppText.deleteQuizDialogTitle)),
          content: Text(appText(
            AppText.deleteQuizDialogBody,
            args: {'title': quizTitle},
          )),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(appText(AppText.cancelButton)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(appText(AppText.deleteButton)),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _runTeacherRequest((client) => client.deleteQuiz(quizId));
      _removeQuizFromCurrentList(quizId);
      _appendEvent('Quiz #$quizId deleted.');
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _createSession() async {
    if (!_isLoggedIn || _selectedQuizId == null || _archiveMode) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final session = await _runTeacherRequest(
          (client) => client.createSession(_selectedQuizId!));
      final sessionUuid = session['id']?.toString() ?? '';
      final state = await _runTeacherRequest(
        (client) => client.getSessionState(sessionUuid),
      );
      setState(() {
        _session = session;
        _revealPayload = null;
        _answeredCount = 0;
      });
      _initializeSessionRuntime(sessionUuid, state);
      _applyReducedTeacherState();
      await _connectSessionSocket(sessionUuid);
      await _refreshSessionHistory();
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<Map<String, dynamic>> _sendSessionCommand(
    String kind,
    Map<String, dynamic> body,
    Future<void> abortTrigger,
  ) {
    final sessionUuid = _sessionStateReducer!.sessionUuid;
    return _runTeacherRequest((client) {
      return switch (kind) {
        'start' => client.startSession(
            sessionUuid,
            command: body,
            abortTrigger: abortTrigger,
          ),
        'start-quiz' => client.startQuiz(
            sessionUuid,
            command: body,
            abortTrigger: abortTrigger,
          ),
        'end-question' => client.endQuestion(
            sessionUuid,
            command: body,
            abortTrigger: abortTrigger,
          ),
        'next-question' => client.nextQuestion(
            sessionUuid,
            command: body,
            abortTrigger: abortTrigger,
          ),
        'finish' => client.finishSession(
            sessionUuid,
            command: body,
            abortTrigger: abortTrigger,
          ),
        _ => throw StateError('Неизвестная управляющая команда.'),
      };
    });
  }

  bool _isExpectedCommandState(
    String kind,
    SessionStateContext original,
    Map<String, dynamic> state,
  ) {
    return switch (kind) {
      'start' => state['status'] == 'live',
      'start-quiz' => state['question_run_id'] != null &&
          state['question_run_id'] != original.questionRunId,
      'end-question' =>
        state['phase'] == 'delivery' || state['phase'] == 'results',
      'next-question' => state['question_run_id'] != original.questionRunId ||
          state['status'] == 'finished',
      'finish' => state['status'] == 'aborted' || state['status'] == 'finished',
      _ => false,
    };
  }

  Future<bool> _runSessionCommand(String kind) async {
    final reducer = _sessionStateReducer;
    final controller = _sessionCommandController;
    final context = reducer?.context;
    if (reducer == null || controller == null || context == null) {
      setState(() {
        _error = 'Актуальное состояние сессии ещё не получено.';
      });
      return false;
    }

    final retained = _uncertainCommand;
    final request = retained != null &&
            retained.kind == kind &&
            reducer.matchesContext(retained.context)
        ? retained
        : SessionCommandRequest(
            kind: kind,
            commandId: newRequestId(),
            context: context,
          );
    if (!identical(request, retained)) {
      controller.cancelPending();
      _uncertainCommand = null;
    }
    _latestCommandRequest = request;

    final result = await controller.execute(
      request: request,
      send: (body, abortTrigger) =>
          _sendSessionCommand(kind, body, abortTrigger),
      readState: () => _runTeacherRequest(
        (client) => client.getSessionState(reducer.sessionUuid),
      ),
      isExpectedSuccess: (state) =>
          _isExpectedCommandState(kind, request.context, state),
    );
    if (!mounted || !identical(_latestCommandRequest, request)) return false;
    if (reducer.hasState) {
      _applyReducedTeacherState();
    }

    switch (result.kind) {
      case SessionCommandResultKind.succeeded:
      case SessionCommandResultKind.recoveredAfterNetwork:
        _uncertainCommand = null;
        try {
          final fresh = await _runTeacherRequest(
            (client) => client.getSessionState(reducer.sessionUuid),
          );
          if (!mounted || !identical(_latestCommandRequest, request)) {
            return false;
          }
          final reduction = reducer.apply(
            fresh,
            source: SessionStateSource.accountRead,
          );
          if (reduction.accepted && mounted) {
            _applyReducedTeacherState();
          }
        } catch (error) {
          _appendEvent(
            'Команда принята, но контрольное состояние временно недоступно.',
          );
        }
        return true;
      case SessionCommandResultKind.uncertain:
        _uncertainCommand = request;
        setState(() {
          _error =
              'Результат команды неизвестен. Повтор этой команды сохранит исходный идентификатор.';
        });
        return false;
      case SessionCommandResultKind.stateConflict:
      case SessionCommandResultKind.conflict:
      case SessionCommandResultKind.temporarilyFailed:
        setState(() {
          _error = result.error == null
              ? 'Команда не выполнена.'
              : userErrorText(result.error!);
        });
        return false;
      case SessionCommandResultKind.cancelled:
        _uncertainCommand = null;
        setState(() {
          _error = 'Повтор команды отменён после изменения состояния.';
        });
        return false;
      case SessionCommandResultKind.protocolError:
        _uncertainCommand = null;
        setState(() {
          _error = 'Сервер вернул несовместимую схему состояния.';
        });
        return false;
    }
  }

  Future<void> _openDisplayForSession(Map<String, dynamic> session) async {
    final sessionUuid = session['id']?.toString() ?? '';
    if (sessionUuid.isEmpty || _displayActionInProgress) return;
    setState(() {
      _displayActionInProgress = true;
      _error = null;
    });
    try {
      final apiBaseUrl = _apiController.text.trim();
      final currentOrigin = trustedApiOrigin(apiBaseUrl);
      final saved = await _roleAccessStore.restoreForSession(
        role: RoleAccessKind.display,
        sessionUuid: sessionUuid,
      );
      if (saved != null &&
          saved.grantId != null &&
          trustedApiOrigin(saved.apiBaseUrl) == currentOrigin) {
        openDisplayWindow(sessionUuid: sessionUuid);
        return;
      }

      if (_pendingDisplaySessionUuid != sessionUuid ||
          _pendingDisplayToken == null ||
          _pendingDisplayGrantId == null) {
        final issued = await _runTeacherRequest(
          (client) => client.createDisplayAccess(sessionUuid),
        );
        final token = issued['display_token']?.toString();
        final grantId = issued['id']?.toString();
        if (token == null || token.isEmpty || grantId == null) {
          throw StateError(
            'Сервер не вернул полные данные доступа к показу.',
          );
        }
        final normalizedGrantId = normalizeSessionUuid(grantId);
        _pendingDisplaySessionUuid = sessionUuid;
        _pendingDisplayToken = token;
        _pendingDisplayGrantId = normalizedGrantId;
      }

      await _roleAccessStore.persist(
        role: RoleAccessKind.display,
        sessionUuid: sessionUuid,
        apiBaseUrl: apiBaseUrl,
        token: _pendingDisplayToken!,
        grantId: _pendingDisplayGrantId,
      );
      _pendingDisplaySessionUuid = null;
      _pendingDisplayToken = null;
      _pendingDisplayGrantId = null;
      openDisplayWindow(sessionUuid: sessionUuid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _displayActionInProgress = false;
        });
      }
    }
  }

  Future<void> _revokeDisplayForSession(Map<String, dynamic> session) async {
    final sessionUuid = session['id']?.toString() ?? '';
    if (sessionUuid.isEmpty || _displayActionInProgress) return;
    setState(() {
      _displayActionInProgress = true;
      _error = null;
    });
    try {
      final saved = await _roleAccessStore.restoreForSession(
        role: RoleAccessKind.display,
        sessionUuid: sessionUuid,
      );
      final hasPending = _pendingDisplaySessionUuid == sessionUuid &&
          _pendingDisplayGrantId != null;
      final grantId = hasPending ? _pendingDisplayGrantId : saved?.grantId;
      if (grantId == null) {
        throw StateError('Действующий доступ к показу не найден.');
      }
      final currentApiBaseUrl = _apiController.text.trim();
      if (!hasPending &&
          saved != null &&
          trustedApiOrigin(saved.apiBaseUrl) !=
              trustedApiOrigin(currentApiBaseUrl)) {
        throw StateError(
          'Доступ к показу выдан другим доверенным API.',
        );
      }

      await _runTeacherRequest(
        (client) => client.revokeDisplayAccess(sessionUuid, grantId),
      );
      if (saved?.grantId == grantId) {
        await _roleAccessStore.clear(
          role: RoleAccessKind.display,
          sessionUuid: sessionUuid,
          apiBaseUrl: saved!.apiBaseUrl,
          grantId: grantId,
        );
      }
      if (hasPending) {
        _pendingDisplaySessionUuid = null;
        _pendingDisplayToken = null;
        _pendingDisplayGrantId = null;
      }
      _appendEvent('Доступ к экрану демонстрации отозван.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _displayActionInProgress = false;
        });
      }
    }
  }

  Future<void> _startSession() async {
    if (_session == null) return;
    if (_session!['status']?.toString() != 'waiting') return;

    try {
      if (!await _runSessionCommand('start')) return;
      await _openDisplayForSession(_session!);
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _startQuiz() async {
    if (_session?['status'] != 'live' || _session?['phase'] != 'lobby') return;
    try {
      if (await _runSessionCommand('start-quiz')) {
        _appendEvent('Преподаватель начал викторину.');
      }
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _nextQuestion() async {
    try {
      if (await _runSessionCommand('next-question')) {
        _appendEvent('Преподаватель открыл следующий вопрос.');
      }
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _revealAnswers() async {
    if (_session == null) return;
    try {
      if (await _runSessionCommand('end-question')) {
        _appendEvent('Преподаватель завершил приём ответов.');
      }
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _finishSession() async {
    if (_session == null) return;
    try {
      if (await _runSessionCommand('finish')) {
        _questionTimer?.cancel();
        _appendEvent('Сессия остановлена преподавателем.');
        await _refreshSessionHistory();
      }
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _showLeaderboard() async {
    if (_session == null) return;
    try {
      final rows = await _runTeacherRequest(
          (client) => client.getLeaderboard(_session!['id'].toString()));
      if (!mounted) return;

      showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text(appText(AppText.leaderboardTitle)),
            content: SizedBox(
              width: 420,
              child: rows.isEmpty
                  ? Text(appText(AppText.leaderboardNoResults))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row =
                            mapOrNull(rows[index]) ?? <String, dynamic>{};
                        return ListTile(
                          dense: true,
                          leading: Text('#${asInt(row['rank'], index + 1)}'),
                          title: Text('${row['participant_name']}'),
                          subtitle: Text('${row['phone']}'),
                          trailing: Text(appText(
                            AppText.leaderboardStats,
                            args: {
                              'correct': row['correct_answers'],
                              'time': formatRankingTimeMs(
                                asInt(row['correct_time_ms']),
                              ),
                            },
                          )),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(appText(AppText.leaderboardCloseButton)),
              ),
            ],
          );
        },
      );
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _exportCsv() async {
    final session = _session;
    if (session == null) return;

    await _exportCsvForSession(session);
  }

  Future<void> _exportCsvForSession(Map<String, dynamic> session) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final sessionUuid = session['id']?.toString() ?? '';
      if (sessionUuid.isEmpty) return;
      final pin = session['pin']?.toString() ?? sessionUuid;
      final csv = await _runTeacherRequest(
          (client) => client.exportSessionResultsCsv(sessionUuid));

      await downloadCsvFile(
        filename: 'umclick_session_${pin}_results.csv',
        content: csv,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appText(AppText.exportDownloadedSnack))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _showSessionHistoryDetails(Map<String, dynamic> session) async {
    final sessionUuid = session['id']?.toString() ?? '';
    if (sessionUuid.isEmpty) return;

    try {
      final rows = await _runTeacherRequest(
          (client) => client.getLeaderboard(sessionUuid));
      if (!mounted) return;

      showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text(appText(AppText.sessionHistoryDetailsTitle)),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appText(
                    AppText.sessionHistoryDetailsSubtitle,
                    args: {
                      'pin': session['pin'] ?? '-',
                      'status': sessionStatusText(session['status']),
                    },
                  )),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 320,
                    child: rows.isEmpty
                        ? Text(appText(AppText.leaderboardNoResults))
                        : ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (context, index) {
                              final row =
                                  mapOrNull(rows[index]) ?? <String, dynamic>{};
                              return ListTile(
                                dense: true,
                                leading: CircleAvatar(
                                  child: Text(
                                    '${asInt(row['rank'], index + 1)}',
                                  ),
                                ),
                                title: Text('${row['participant_name']}'),
                                subtitle: Text(appText(
                                  AppText.leaderboardStats,
                                  args: {
                                    'correct': row['correct_answers'],
                                    'time': formatRankingTimeMs(
                                      asInt(row['correct_time_ms']),
                                    ),
                                  },
                                )),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(appText(AppText.leaderboardCloseButton)),
              ),
            ],
          );
        },
      );
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _logout() async {
    _questionTimer?.cancel();
    await _closeSessionSocket();
    await _clearPersistedAuthSession();
    _resetQuizDraft(withState: false);
    if (!mounted) return;
    setState(() {
      _accessToken = null;
      _refreshToken = null;
      _pendingDisplaySessionUuid = null;
      _pendingDisplayToken = null;
      _pendingDisplayGrantId = null;
      _displayActionInProgress = false;
      _latestCommandRequest = null;
      _teacher = null;
      _quizzes = [];
      _sessionHistory = [];
      _selectedQuizId = null;
      _archiveMode = false;
      _session = null;
      _activeQuestion = null;
      _revealPayload = null;
      _answeredCount = 0;
      _questionTimeLeftLabel = '--:--';
      _events.clear();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFF3FBF9),
                Color(0xFFEAF4F2),
                Color(0xFFFFF7E8),
              ],
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 1120,
                  minHeight: constraints.maxHeight.isFinite &&
                          constraints.maxHeight > 32
                      ? constraints.maxHeight - 32
                      : 0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TeacherHero(isLoggedIn: _isLoggedIn, teacher: _teacher),
                    const SizedBox(height: 14),
                    _TeacherAdvancedSettings(apiController: _apiController),
                    const SizedBox(height: 14),
                    TeacherAuthCard(
                      usernameController: _usernameController,
                      passwordController: _passwordController,
                      emailController: _emailController,
                      signupCodeController: _signupCodeController,
                      loading: _loading,
                      restoringSession: _restoringSession,
                      isLoggedIn: _isLoggedIn,
                      hasRefreshToken:
                          _refreshToken != null && _refreshToken!.isNotEmpty,
                      teacher: _teacher,
                      onRegister: _registerTeacher,
                      onLogin: _loginTeacher,
                      onLoadProfile: _loadMe,
                      onLogout: _logout,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      _TeacherErrorBanner(error: _error!),
                    ],
                    if (!_isLoggedIn) ...[
                      const SizedBox(height: 14),
                      const _TeacherLockedCard(),
                    ] else ...[
                      const SizedBox(height: 14),
                      const _TeacherFlowSteps(),
                      const SizedBox(height: 14),
                      _TeacherWorkspaceHeader(quizzesCount: _quizzes.length),
                      const SizedBox(height: 14),
                      TeacherQuizBuilderCard(
                        quizzes: _quizzes,
                        selectedQuizId: _selectedQuizId,
                        editingQuizId: _editingQuizId,
                        archiveMode: _archiveMode,
                        quizFormReadOnly: _archiveMode || _editingQuizArchived,
                        canDeleteSelectedQuiz: _selectedQuizId != null &&
                            _quizById(_selectedQuizId!)?['can_delete'] == true,
                        loading: _loading,
                        isLoggedIn: _isLoggedIn,
                        titleController: _quizTitleController,
                        descriptionController: _quizDescriptionController,
                        readingTimeController: _readingTimeController,
                        resultsTimeController: _resultsTimeController,
                        questionOnlyOnDisplay: _questionOnlyOnDisplay,
                        showChoicesOnParticipant: _showChoicesOnParticipant,
                        questions: _draftQuestions,
                        onQuestionOnlyOnDisplayChanged:
                            _setQuestionOnlyOnDisplay,
                        onShowChoicesOnParticipantChanged:
                            _setShowChoicesOnParticipant,
                        onSelectedQuizChanged: (value) {
                          setState(() {
                            _selectedQuizId = value;
                          });
                        },
                        onArchiveModeChanged: _setQuizArchiveMode,
                        onLoadSelectedQuiz: _loadSelectedQuizIntoDraft,
                        onSaveQuiz: _saveQuizDraft,
                        onPreviewQuiz: _openQuizPreview,
                        onResetDraft: () => _resetQuizDraft(),
                        onRefreshQuizzes: () => _refreshQuizzes(),
                        onArchiveSelectedQuiz: _archiveSelectedQuiz,
                        onRestoreSelectedQuiz: _restoreSelectedQuiz,
                        onDeleteSelectedQuiz: _deleteSelectedQuiz,
                        onRemoveQuestion: _removeDraftQuestion,
                        onSetCorrectChoice: _setDraftCorrectChoice,
                        onRemoveChoice: _removeDraftChoice,
                        onAddChoice: _addDraftChoice,
                        onAddQuestion: _addDraftQuestion,
                      ),
                      const SizedBox(height: 14),
                      TeacherSessionSetupCard(
                        loading: _loading,
                        isLoggedIn: _isLoggedIn,
                        selectedQuizId: _archiveMode ? null : _selectedQuizId,
                        onCreateSession: _createSession,
                      ),
                      if (_session != null) ...[
                        const SizedBox(height: 20),
                        TeacherLiveSessionCard(
                          session: _session!,
                          wsConnected: _wsConnected,
                          activeQuestion: _activeQuestion,
                          questionTimeLeftLabel: _questionTimeLeftLabel,
                          answeredCount: _answeredCount,
                          revealPayload: _revealPayload,
                          onStart: _startSession,
                          onStartQuiz: _startQuiz,
                          onNextQuestion: _nextQuestion,
                          onRevealAnswers: _revealAnswers,
                          onFinish: _finishSession,
                          onOpenDisplay: () =>
                              _openDisplayForSession(_session!),
                          onRevokeDisplay: () =>
                              _revokeDisplayForSession(_session!),
                          onShowLeaderboard: _showLeaderboard,
                          onExportCsv: _exportCsv,
                          hasNextQuestion: hasNextQuestionInSessionQuiz(
                            session: _session!,
                            currentQuestion: _activeQuestion,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TeacherLiveEventsCard(events: _events),
                      ],
                      const SizedBox(height: 14),
                      _TeacherSessionHistoryCard(
                        sessions: _sessionHistory,
                        loading: _loading,
                        onRefresh: _refreshSessionHistory,
                        onExportCsv: _exportCsvForSession,
                        onOpenDetails: _showSessionHistoryDetails,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TeacherHero extends StatelessWidget {
  const _TeacherHero({required this.isLoggedIn, required this.teacher});

  final bool isLoggedIn;
  final Map<String, dynamic>? teacher;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: const LinearGradient(
          colors: [Color(0xFF063B3D), Color(0xFF087E8B), Color(0xFFFFB703)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF063B3D).withValues(alpha: 0.18),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final title = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppStatusChip(
                icon: Icons.school_outlined,
                label: appText(AppText.teacherHeroBadge),
                background: Colors.white.withValues(alpha: 0.18),
                foreground: Colors.white,
              ),
              const SizedBox(height: 18),
              Text(
                appText(AppText.teacherHeroTitle),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                appText(AppText.teacherHeroSubtitle),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 16,
                  height: 1.35,
                ),
              ),
            ],
          );

          final status = _TeacherHeroStatus(
            isLoggedIn: isLoggedIn,
            teacher: teacher,
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: 18),
                status,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 3, child: title),
              const SizedBox(width: 24),
              Expanded(flex: 2, child: status),
            ],
          );
        },
      ),
    );
  }
}

class _TeacherHeroStatus extends StatelessWidget {
  const _TeacherHeroStatus({required this.isLoggedIn, required this.teacher});

  final bool isLoggedIn;
  final Map<String, dynamic>? teacher;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isLoggedIn
                ? Icons.verified_user_outlined
                : Icons.lock_outline_rounded,
            color: Colors.white,
            size: 34,
          ),
          const SizedBox(height: 12),
          Text(
            isLoggedIn
                ? appText(AppText.loggedInTeacher, args: {
                    'suffix':
                        teacher != null ? ': ${teacher!['username']}' : '',
                  })
                : appText(AppText.notAuthenticated),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isLoggedIn
                ? appText(AppText.teacherWorkspaceSubtitle)
                : appText(AppText.teacherFlowAuthBody),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.88)),
          ),
        ],
      ),
    );
  }
}

class _TeacherAdvancedSettings extends StatelessWidget {
  const _TeacherAdvancedSettings({required this.apiController});

  final TextEditingController apiController;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.tune_outlined),
          title: Text(appText(AppText.teacherAdvancedSettingsTitle)),
          subtitle: Text(appText(AppText.teacherAdvancedSettingsSubtitle)),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          children: [
            TextField(
              controller: apiController,
              decoration: InputDecoration(
                labelText: appText(AppText.apiBaseUrlLabel),
                hintText: defaultApiBaseUrl,
                helperText: appText(AppText.teacherApiBaseUrlHelper),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeacherFlowSteps extends StatelessWidget {
  const _TeacherFlowSteps();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final cards = [
          _TeacherFlowStepCard(
            icon: Icons.login_rounded,
            title: appText(AppText.teacherFlowAuthTitle),
            body: appText(AppText.teacherFlowAuthBody),
          ),
          _TeacherFlowStepCard(
            icon: Icons.quiz_outlined,
            title: appText(AppText.teacherFlowQuizTitle),
            body: appText(AppText.teacherFlowQuizBody),
          ),
          _TeacherFlowStepCard(
            icon: Icons.qr_code_2_rounded,
            title: appText(AppText.teacherFlowLaunchTitle),
            body: appText(AppText.teacherFlowLaunchBody),
          ),
        ];

        if (compact) {
          return Column(
            children: [
              for (final card in cards) ...[
                card,
                if (card != cards.last) const SizedBox(height: 10),
              ],
            ],
          );
        }

        return Row(
          children: [
            for (final card in cards) ...[
              Expanded(child: card),
              if (card != cards.last) const SizedBox(width: 12),
            ],
          ],
        );
      },
    );
  }
}

class _TeacherFlowStepCard extends StatelessWidget {
  const _TeacherFlowStepCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE8B3),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: const Color(0xFF975A00)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 4),
                Text(body),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherWorkspaceHeader extends StatelessWidget {
  const _TeacherWorkspaceHeader({required this.quizzesCount});

  final int quizzesCount;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      color: const Color(0xFFFFFFFF),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: const Color(0xFFDDF9F2),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.dashboard_customize_outlined,
                color: Color(0xFF00796B)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appText(AppText.teacherWorkspaceTitle),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 4),
                Text(appText(AppText.teacherWorkspaceSubtitle)),
              ],
            ),
          ),
          AppStatusChip(
            icon: Icons.folder_copy_outlined,
            label: '$quizzesCount',
            background: const Color(0xFFE0F2F1),
            foreground: const Color(0xFF00695C),
          ),
        ],
      ),
    );
  }
}

class _TeacherLockedCard extends StatelessWidget {
  const _TeacherLockedCard();

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      color: const Color(0xFFFFF8E1),
      child: Row(
        children: [
          const Icon(Icons.lock_outline_rounded, color: Color(0xFF975A00)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appText(AppText.teacherLockedTitle),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 4),
                Text(appText(AppText.teacherLockedBody)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherSessionHistoryCard extends StatelessWidget {
  const _TeacherSessionHistoryCard({
    required this.sessions,
    required this.loading,
    required this.onRefresh,
    required this.onExportCsv,
    required this.onOpenDetails,
  });

  final List<dynamic> sessions;
  final bool loading;
  final VoidCallback onRefresh;
  final ValueChanged<Map<String, dynamic>> onExportCsv;
  final ValueChanged<Map<String, dynamic>> onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final rows = sessions
        .map((raw) => mapOrNull(raw) ?? <String, dynamic>{})
        .where((row) => row.isNotEmpty)
        .toList();

    return AppSectionCard(
      padding: const EdgeInsets.all(18),
      borderRadius: 28,
      color: Colors.white.withValues(alpha: 0.94),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F7FA),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.history_edu_outlined,
                    color: Color(0xFF005F73)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText(AppText.sessionHistoryTitle),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(appText(AppText.sessionHistorySubtitle)),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: loading ? null : onRefresh,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(appText(AppText.refreshHistoryButton)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (rows.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF4FBFA),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(appText(AppText.sessionHistoryEmpty)),
            )
          else
            ...rows.take(8).map((session) {
              final quiz = mapOrNull(session['quiz']) ?? <String, dynamic>{};
              final status = session['status']?.toString() ?? '';
              final createdAt = _compactDateTime(session['created_at']);
              final finishedAt = _compactDateTime(session['finished_at']);
              final participantsCount = asInt(session['participants_count']);

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7FBFA),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFDDEBE9)),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 720;
                      final details = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            quiz['title']?.toString() ??
                                appText(AppText.untitledQuiz),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              AppStatusChip(
                                icon: Icons.pin_outlined,
                                label: 'PIN: ${session['pin'] ?? '-'}',
                                background: Colors.white,
                                foreground: const Color(0xFF023047),
                              ),
                              AppStatusChip(
                                icon: Icons.flag_outlined,
                                label: sessionStatusText(status),
                                background: const Color(0xFFE0F2F1),
                                foreground: const Color(0xFF00695C),
                              ),
                              AppStatusChip(
                                icon: Icons.group_outlined,
                                label: appText(
                                  AppText.sessionHistoryParticipants,
                                  args: {'count': participantsCount},
                                ),
                                background: const Color(0xFFFFF3CD),
                                foreground: const Color(0xFF805300),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(appText(
                            AppText.sessionHistoryCreated,
                            args: {'value': createdAt},
                          )),
                          if (finishedAt.isNotEmpty)
                            Text(appText(
                              AppText.sessionHistoryFinished,
                              args: {'value': finishedAt},
                            )),
                        ],
                      );
                      final actions = Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => onOpenDetails(session),
                            icon: const Icon(Icons.insights_outlined),
                            label: Text(
                                appText(AppText.sessionHistoryDetailsButton)),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () => onExportCsv(session),
                            icon: const Icon(Icons.download_outlined),
                            label: Text(
                                appText(AppText.sessionHistoryExportButton)),
                          ),
                        ],
                      );

                      if (compact) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            details,
                            const SizedBox(height: 10),
                            actions,
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: details),
                          const SizedBox(width: 12),
                          actions,
                        ],
                      );
                    },
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  String _compactDateTime(Object? rawValue) {
    final value = rawValue?.toString() ?? '';
    final parsed = parseDateTimeLocal(value);
    if (parsed == null) return value;
    final day = parsed.day.toString().padLeft(2, '0');
    final month = parsed.month.toString().padLeft(2, '0');
    final hour = parsed.hour.toString().padLeft(2, '0');
    final minute = parsed.minute.toString().padLeft(2, '0');
    return '$day.$month.${parsed.year} $hour:$minute';
  }
}

class _TeacherErrorBanner extends StatelessWidget {
  const _TeacherErrorBanner({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.error_outline,
              color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              error,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
