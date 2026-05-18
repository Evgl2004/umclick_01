import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../core/app_config.dart';
import '../../core/countdown_ticker.dart';
import '../../core/csv_download.dart';
import '../../core/live_event_log.dart';
import '../../core/live_socket_connection.dart';
import '../../core/value_utils.dart';
import '../../l10n/app_strings.dart';
import '../../shared/widgets/app_surfaces.dart';
import 'quiz_draft.dart';
import 'quiz_draft_mapper.dart';
import 'teacher_auth_session.dart';
import 'widgets/teacher_auth_card.dart';
import 'widgets/teacher_live_events_card.dart';
import 'widgets/teacher_live_session_card.dart';
import 'widgets/teacher_quiz_builder_card.dart';
import 'widgets/teacher_session_setup_card.dart';

class TeacherPanel extends StatefulWidget {
  const TeacherPanel({super.key});

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
  final _authSessionStore = const TeacherAuthSessionStore();
  final _quizDraftMapper = const QuizDraftMapper();

  final List<QuizDraftQuestion> _draftQuestions = [];
  int? _editingQuizId;

  List<dynamic> _quizzes = [];
  int? _selectedQuizId;
  Map<String, dynamic>? _session;
  Map<String, dynamic>? _teacher;
  Map<String, dynamic>? _activeQuestion;
  Map<String, dynamic>? _revealPayload;
  String? _accessToken;
  String? _refreshToken;
  bool _loading = false;
  String? _error;
  int _answeredCount = 0;

  LiveSocketConnection? _sessionSocketConnection;
  bool _wsConnected = false;
  final _countdownTicker = const CountdownTicker();
  final _eventLog = const LiveEventLog();
  final List<String> _events = [];

  Timer? _questionTimer;
  String _questionTimeLeftLabel = '--:--';
  bool _restoringSession = true;

  ApiClient _client({bool withToken = true}) {
    return ApiClient(
      _apiController.text.trim(),
      accessToken: withToken ? _accessToken : null,
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
    _closeSessionSocket();
    _disposeQuizDraft();
    _apiController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _emailController.dispose();
    _signupCodeController.dispose();
    _quizTitleController.dispose();
    _quizDescriptionController.dispose();
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
      _quizTitleController.clear();
      _quizDescriptionController.clear();
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
      if (_editingQuizId != null) {
        _selectedQuizId = _editingQuizId;
      }
      _quizTitleController.text = draft.title;
      _quizDescriptionController.text = draft.description;
      _draftQuestions.addAll(draft.questions);
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
        const SnackBar(
            content: Text('Quiz must contain at least one question.')),
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
        const SnackBar(
            content: Text('Each question needs at least two answer choices.')),
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

      if (mounted) {
        setState(() {
          _teacher = me;
          _quizzes = quizzes;
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
          _selectedQuizId = null;
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
        _error = 'Session expired. Please login again.';
      });
      _appendEvent('Refresh token expired, teacher logged out.');
      return false;
    }
  }

  Future<T> _runTeacherRequest<T>(
      Future<T> Function(ApiClient client) request) async {
    try {
      return await request(_client());
    } on ApiException catch (e) {
      if (e.statusCode != 401) {
        rethrow;
      }

      final refreshed = await _refreshAccessToken();
      if (!refreshed) {
        rethrow;
      }
      return request(_client());
    }
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

  Future<void> _connectSessionSocket(int sessionId) async {
    await _closeSessionSocket();
    final url = _client().sessionWebSocketUrl(sessionId);

    try {
      _sessionSocketConnection = LiveSocketConnection.connect(
        url: url,
        isActive: () => mounted,
        onMessage: _handleTeacherSocketEvent,
        onInvalidPayload: () => _appendEvent('Invalid socket payload.'),
        onError: (error) {
          _appendEvent('Socket error: $error');
          _setSessionSocketConnected(false);
        },
        onDone: () {
          _appendEvent('Socket disconnected.');
          _setSessionSocketConnected(false);
        },
      );

      _setSessionSocketConnected(true);
      _appendEvent('Connected to session socket.');
    } catch (e) {
      _setSessionSocketConnected(false);
      _appendEvent('Failed to connect socket: $e');
    }
  }

  Future<void> _closeSessionSocket() async {
    await _sessionSocketConnection?.close();
    _sessionSocketConnection = null;
    _setSessionSocketConnected(false);
  }

  void _setSessionSocketConnected(bool connected) {
    if (!mounted) return;
    setState(() {
      _wsConnected = connected;
    });
  }

  void _patchSession(Map<String, dynamic> patch) {
    if (_session == null) return;
    final updated = Map<String, dynamic>.from(_session!);
    updated.addAll(patch);
    setState(() {
      _session = updated;
    });
  }

  void _handleTeacherSocketEvent(Map<String, dynamic> message) {
    final event = message['event']?.toString() ?? 'unknown';
    final payload = mapOrNull(message['payload']) ?? <String, dynamic>{};

    switch (event) {
      case 'session_state':
      case 'session_started':
        _patchSession({
          'status': payload['status'],
          'participants_count': payload['participants_count'] ??
              (_session?['participants_count'] ?? 0),
        });
        setState(() {
          _activeQuestion = mapOrNull(payload['current_question']);
          if ((_session?['status']?.toString() ?? '') == 'finished') {
            _activeQuestion = null;
          }
        });
        _startTeacherTimer(parseDateTimeLocal(payload['question_ends_at']));
        if (payload['is_answer_revealed'] == true) {
          _questionTimer?.cancel();
          setState(() {
            _questionTimeLeftLabel = '00:00';
          });
        }
        break;
      case 'participant_joined':
        _patchSession({
          'participants_count': payload['participants_count'] ??
              (_session?['participants_count'] ?? 0)
        });
        break;
      case 'question_started':
        setState(() {
          _activeQuestion = mapOrNull(payload['question']);
          _revealPayload = null;
          _answeredCount = 0;
        });
        _startTeacherTimer(parseDateTimeLocal(payload['question_ends_at']));
        break;
      case 'answer_submitted':
        setState(() {
          _answeredCount = asInt(payload['answered_count'], _answeredCount);
        });
        break;
      case 'answer_revealed':
        _questionTimer?.cancel();
        setState(() {
          _revealPayload = payload;
          _questionTimeLeftLabel = '00:00';
        });
        break;
      case 'session_finished':
        _patchSession({'status': 'finished'});
        _questionTimer?.cancel();
        setState(() {
          _activeQuestion = null;
          _questionTimeLeftLabel = '--:--';
        });
        break;
      default:
        break;
    }

    _appendEvent('Event: $event');
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
          const SnackBar(content: Text('Teacher registered. Now login.')),
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
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
    } catch (e) {
      setState(() {
        _error = e.toString();
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
        _error = e.toString();
      });
    }
  }

  Future<void> _refreshQuizzes({int? selectQuizId}) async {
    if (!_isLoggedIn) {
      setState(() {
        _error = 'Login required for teacher API.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final quizzes = await _runTeacherRequest((client) => client.getQuizzes());
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
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
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

  Future<void> _saveQuizDraft() async {
    if (!_isLoggedIn) {
      setState(() {
        _error = 'Login required for teacher API.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final payload = _quizDraftMapper.toPayload(
        title: _quizTitleController.text,
        description: _quizDescriptionController.text,
        questions: _draftQuestions,
      );
      final editingQuizId = _editingQuizId;

      final savedQuiz = editingQuizId == null
          ? await _runTeacherRequest((client) => client.createQuiz(payload))
          : await _runTeacherRequest(
              (client) => client.updateQuiz(editingQuizId, payload));

      final savedQuizId = asInt(savedQuiz['id'], 0);
      await _refreshQuizzes(selectQuizId: savedQuizId);

      final refreshedQuiz = _quizById(savedQuizId) ?? savedQuiz;
      _loadQuizDraftFromMap(refreshedQuiz);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              editingQuizId == null
                  ? 'Quiz created successfully.'
                  : 'Quiz updated successfully.',
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
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
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

    final quizTitle =
        _quizById(quizId)?['title']?.toString() ?? 'selected quiz';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete quiz?'),
          content: Text(
              'Delete "$quizTitle" permanently? This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
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
      final wasEditingDeletedQuiz = _editingQuizId == quizId;
      await _refreshQuizzes();
      if (wasEditingDeletedQuiz) {
        _resetQuizDraft();
      }
      _appendEvent('Quiz #$quizId deleted.');
    } catch (e) {
      setState(() {
        _error = e.toString();
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
    if (!_isLoggedIn || _selectedQuizId == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final session = await _runTeacherRequest(
          (client) => client.createSession(_selectedQuizId!));
      setState(() {
        _session = session;
        _activeQuestion = mapOrNull(session['current_question']);
        _revealPayload = null;
        _answeredCount = 0;
      });
      _startTeacherTimer(parseDateTimeLocal(session['question_ends_at']));
      await _connectSessionSocket(session['id'] as int);
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _startSession() async {
    if (_session == null) return;
    try {
      final started = await _runTeacherRequest(
          (client) => client.startSession(_session!['id'] as int));
      setState(() {
        _session = started;
        _activeQuestion = mapOrNull(started['current_question']);
        _revealPayload = null;
      });
      _startTeacherTimer(parseDateTimeLocal(started['question_ends_at']));
      await _connectSessionSocket(_session!['id'] as int);
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  Future<void> _nextQuestion() async {
    if (_session == null) return;
    try {
      final payload = await _runTeacherRequest(
          (client) => client.nextQuestion(_session!['id'] as int));
      if (payload.containsKey('session')) {
        final session = mapOrNull(payload['session']);
        if (session != null) {
          setState(() {
            _session = session;
            _activeQuestion = null;
          });
        }
        _questionTimer?.cancel();
        setState(() {
          _questionTimeLeftLabel = '--:--';
        });
      } else {
        setState(() {
          _activeQuestion = mapOrNull(payload['question']);
          _revealPayload = null;
          _answeredCount = 0;
        });
        _startTeacherTimer(parseDateTimeLocal(payload['question_ends_at']));
      }
      _appendEvent('Teacher moved to next question.');
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  Future<void> _revealAnswers() async {
    if (_session == null) return;
    try {
      final payload = await _runTeacherRequest(
          (client) => client.revealAnswer(_session!['id'] as int));
      setState(() {
        _revealPayload = payload;
      });
      _appendEvent('Teacher revealed answers.');
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  Future<void> _finishSession() async {
    if (_session == null) return;
    try {
      final finished = await _runTeacherRequest(
          (client) => client.finishSession(_session!['id'] as int));
      _questionTimer?.cancel();
      setState(() {
        _session = finished;
        _activeQuestion = null;
        _questionTimeLeftLabel = '--:--';
      });
      _appendEvent('Session finished by teacher.');
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  Future<void> _showLeaderboard() async {
    if (_session == null) return;
    try {
      final rows = await _runTeacherRequest(
          (client) => client.getLeaderboard(_session!['id'] as int));
      if (!mounted) return;

      showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Leaderboard'),
            content: SizedBox(
              width: 420,
              child: rows.isEmpty
                  ? const Text('No results yet.')
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row =
                            mapOrNull(rows[index]) ?? <String, dynamic>{};
                        return ListTile(
                          dense: true,
                          leading: Text('#${index + 1}'),
                          title: Text('${row['participant_name']}'),
                          subtitle: Text('${row['phone']}'),
                          trailing: Text(
                              'Pts: ${row['points']} | Correct: ${row['correct_answers']}'),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  Future<void> _exportCsv() async {
    final session = _session;
    if (session == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final sessionId = session['id'] as int;
      final pin = session['pin']?.toString() ?? sessionId.toString();
      final csv = await _runTeacherRequest(
          (client) => client.exportSessionResultsCsv(sessionId));

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
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
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
      _teacher = null;
      _quizzes = [];
      _selectedQuizId = null;
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
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF3FBF9), Color(0xFFEAF4F2), Color(0xFFFFF7E8)],
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                loading: _loading,
                isLoggedIn: _isLoggedIn,
                titleController: _quizTitleController,
                descriptionController: _quizDescriptionController,
                questions: _draftQuestions,
                onSelectedQuizChanged: (value) {
                  setState(() {
                    _selectedQuizId = value;
                  });
                },
                onLoadSelectedQuiz: _loadSelectedQuizIntoDraft,
                onSaveQuiz: _saveQuizDraft,
                onResetDraft: () => _resetQuizDraft(),
                onRefreshQuizzes: () => _refreshQuizzes(),
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
                selectedQuizId: _selectedQuizId,
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
                  onNextQuestion: _nextQuestion,
                  onRevealAnswers: _revealAnswers,
                  onFinish: _finishSession,
                  onShowLeaderboard: _showLeaderboard,
                  onExportCsv: _exportCsv,
                ),
                const SizedBox(height: 12),
                TeacherLiveEventsCard(events: _events),
              ],
            ],
          ],
        ),
      ),
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
