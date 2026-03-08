import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const UmclickApp());
}

const _defaultApiBaseUrl = 'http://localhost:8000/api';
const _defaultPrivacyPolicyVersion = '2026-03';
const _defaultPersonalDataConsentVersion = '2026-03';

enum UmclickEntryPoint {
  home,
  legalPrivacy,
  legalConsent,
}

enum PublicLegalDocumentType {
  privacyPolicy,
  personalDataConsent,
}

String _normalizePath(String path) {
  if (path.isEmpty) return '/';
  final trimmed = path.replaceAll(RegExp(r'/+$'), '');
  return trimmed.isEmpty ? '/' : trimmed;
}

UmclickEntryPoint resolveEntryPoint(Uri uri) {
  final normalizedPath = _normalizePath(uri.path.toLowerCase());
  switch (normalizedPath) {
    case '/legal/privacy':
      return UmclickEntryPoint.legalPrivacy;
    case '/legal/consent':
      return UmclickEntryPoint.legalConsent;
    default:
      return UmclickEntryPoint.home;
  }
}

int resolveInitialHomeTab(Uri uri) {
  final normalizedPath = _normalizePath(uri.path.toLowerCase());
  if (normalizedPath == '/join') {
    return 1;
  }
  return 0;
}

String resolvePublicLegalApiBase(Uri uri) {
  final apiFromQuery = uri.queryParameters['api']?.trim() ?? '';
  if (apiFromQuery.isNotEmpty) {
    return apiFromQuery;
  }
  return _defaultApiBaseUrl;
}

class UmclickApp extends StatelessWidget {
  const UmclickApp({super.key});

  Widget _buildHomeForEntryPoint() {
    final uri = Uri.base;
    final entryPoint = resolveEntryPoint(uri);
    final publicApiBase = resolvePublicLegalApiBase(uri);

    switch (entryPoint) {
      case UmclickEntryPoint.legalPrivacy:
        return PublicLegalDocumentPage(
          documentType: PublicLegalDocumentType.privacyPolicy,
          apiBaseUrl: publicApiBase,
        );
      case UmclickEntryPoint.legalConsent:
        return PublicLegalDocumentPage(
          documentType: PublicLegalDocumentType.personalDataConsent,
          apiBaseUrl: publicApiBase,
        );
      case UmclickEntryPoint.home:
        return HomePage(initialIndex: resolveInitialHomeTab(uri));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'umclick',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E7C7B)),
        useMaterial3: true,
      ),
      home: _buildHomeForEntryPoint(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, 1).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [const TeacherPanel(), const ParticipantPanel()];

    return Scaffold(
      appBar: AppBar(title: const Text('umclick MVP')),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.school), label: 'Teacher'),
          NavigationDestination(icon: Icon(Icons.group), label: 'Participant'),
        ],
        onDestinationSelected: (value) {
          setState(() {
            _index = value;
          });
        },
      ),
    );
  }
}

class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.message,
    required this.body,
  });

  final int statusCode;
  final String message;
  final String body;

  @override
  String toString() => '$message (status $statusCode): $body';
}

class ApiClient {
  ApiClient(this.baseUrl, {this.accessToken});

  final String baseUrl;
  final String? accessToken;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _headers({bool jsonBody = false, bool auth = false}) {
    final headers = <String, String>{};
    if (jsonBody) {
      headers['Content-Type'] = 'application/json';
    }
    if (auth && accessToken != null && accessToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  Never _throwError(http.Response response, String message) {
    throw ApiException(
      statusCode: response.statusCode,
      message: message,
      body: response.body,
    );
  }

  String sessionWebSocketUrl(int sessionId) {
    final apiUri = Uri.parse(baseUrl);
    final scheme = apiUri.scheme == 'https' ? 'wss' : 'ws';
    final portPart = apiUri.hasPort ? ':${apiUri.port}' : '';
    return '$scheme://${apiUri.host}$portPart/ws/sessions/$sessionId/';
  }

  Future<Map<String, dynamic>> registerTeacher({
    required String username,
    required String password,
    String? email,
    String? signupCode,
  }) async {
    final payload = {
      'username': username,
      'password': password,
      if (email != null && email.isNotEmpty) 'email': email,
      if (signupCode != null && signupCode.isNotEmpty) 'signup_code': signupCode,
    };

    final response = await http.post(
      _uri('/auth/register/'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to register teacher');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> loginTeacher({
    required String username,
    required String password,
  }) async {
    final response = await http.post(
      _uri('/auth/token/'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to login');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refreshTeacherToken({
    required String refreshToken,
  }) async {
    final response = await http.post(
      _uri('/auth/token/refresh/'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'refresh': refreshToken}),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to refresh token');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getMe() async {
    final response = await http.get(
      _uri('/auth/me/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to get profile');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getQuizzes() async {
    final response = await http.get(
      _uri('/quizzes/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load quizzes');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> createQuiz(Map<String, dynamic> payload) async {
    final response = await http.post(
      _uri('/quizzes/'),
      headers: _headers(jsonBody: true, auth: true),
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to create quiz');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateQuiz(int quizId, Map<String, dynamic> payload) async {
    final response = await http.put(
      _uri('/quizzes/$quizId/'),
      headers: _headers(jsonBody: true, auth: true),
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to update quiz');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> deleteQuiz(int quizId) async {
    final response = await http.delete(
      _uri('/quizzes/$quizId/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to delete quiz');
    }
  }

  Future<Map<String, dynamic>> createSession(int quizId) async {
    final response = await http.post(
      _uri('/sessions/'),
      headers: _headers(jsonBody: true, auth: true),
      body: jsonEncode({'quiz': quizId, 'host_name': 'Teacher'}),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to create session');
    }

    final created = jsonDecode(response.body) as Map<String, dynamic>;
    final details = await http.get(
      _uri('/sessions/${created['id']}/'),
      headers: _headers(auth: true),
    );
    if (details.statusCode >= 400) {
      _throwError(details, 'Failed to fetch session details');
    }
    return jsonDecode(details.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> startSession(int sessionId) async {
    final response = await http.post(
      _uri('/sessions/$sessionId/start/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to start session');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> finishSession(int sessionId) async {
    final response = await http.post(
      _uri('/sessions/$sessionId/finish/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to finish session');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> nextQuestion(int sessionId) async {
    final response = await http.post(
      _uri('/sessions/$sessionId/next-question/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load next question');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> revealAnswer(int sessionId) async {
    final response = await http.post(
      _uri('/sessions/$sessionId/reveal-answer/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to reveal answers');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getLeaderboard(int sessionId) async {
    final response = await http.get(
      _uri('/sessions/$sessionId/leaderboard/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load leaderboard');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> getCurrentLegalDocuments() async {
    final response = await http.get(
      _uri('/sessions/legal/current/'),
      headers: _headers(),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load legal documents');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> joinSession({
    String? pin,
    String? joinToken,
    required String phone,
    required String name,
    required bool consent,
  }) async {
    final payload = <String, dynamic>{
      'phone': phone,
      'name': name,
      'consent': consent,
    };

    final normalizedPin = (pin ?? '').trim();
    if (normalizedPin.isNotEmpty) {
      payload['pin'] = normalizedPin;
    }

    final normalizedJoinToken = (joinToken ?? '').trim();
    if (normalizedJoinToken.isNotEmpty) {
      payload['join_token'] = normalizedJoinToken;
    }

    final response = await http.post(
      _uri('/sessions/join/'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to join session');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> submitAnswer({
    required int sessionParticipantId,
    required int questionId,
    required int choiceId,
  }) async {
    final response = await http.post(
      _uri('/sessions/answer/'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'session_participant_id': sessionParticipantId,
        'question_id': questionId,
        'choice_id': choiceId,
      }),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to submit answer');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

Map<String, dynamic>? mapOrNull(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return null;
}

int asInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  return int.tryParse('$value') ?? fallback;
}

DateTime? parseDateTimeLocal(dynamic rawValue) {
  if (rawValue is! String || rawValue.isEmpty) return null;
  return DateTime.tryParse(rawValue)?.toLocal();
}

String formatRemaining(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

const _prefsAccessTokenKey = 'umclick_teacher_access_token';
const _prefsRefreshTokenKey = 'umclick_teacher_refresh_token';
const _prefsApiBaseUrlKey = 'umclick_api_base_url';
const _prefsUsernameKey = 'umclick_teacher_username';

class QuizDraftChoice {
  QuizDraftChoice({String text = '', this.isCorrect = false})
      : textController = TextEditingController(text: text);

  final TextEditingController textController;
  bool isCorrect;

  void dispose() {
    textController.dispose();
  }
}

class QuizDraftQuestion {
  QuizDraftQuestion({
    String text = '',
    int timeLimitSec = 20,
    List<QuizDraftChoice>? choices,
  })  : textController = TextEditingController(text: text),
        timeLimitController = TextEditingController(text: '$timeLimitSec'),
        choices = choices ?? [QuizDraftChoice(), QuizDraftChoice()];

  final TextEditingController textController;
  final TextEditingController timeLimitController;
  final List<QuizDraftChoice> choices;

  void dispose() {
    textController.dispose();
    timeLimitController.dispose();
    for (final choice in choices) {
      choice.dispose();
    }
  }
}

class TeacherPanel extends StatefulWidget {
  const TeacherPanel({super.key});

  @override
  State<TeacherPanel> createState() => _TeacherPanelState();
}

class _TeacherPanelState extends State<TeacherPanel> {
  final _apiController = TextEditingController(text: _defaultApiBaseUrl);
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailController = TextEditingController();
  final _signupCodeController = TextEditingController();
  final _quizTitleController = TextEditingController();
  final _quizDescriptionController = TextEditingController();

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

  WebSocketChannel? _sessionSocket;
  StreamSubscription? _sessionSubscription;
  bool _wsConnected = false;
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
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _events.insert(0, '[$timestamp] $text');
      if (_events.length > 25) {
        _events.removeRange(25, _events.length);
      }
    });
  }

  QuizDraftQuestion _newDraftQuestion({
    String text = '',
    int timeLimitSec = 20,
    List<QuizDraftChoice>? choices,
  }) {
    final resolvedChoices = choices ?? [
      QuizDraftChoice(isCorrect: true),
      QuizDraftChoice(),
      QuizDraftChoice(),
      QuizDraftChoice(),
    ];

    if (resolvedChoices.isNotEmpty && !resolvedChoices.any((choice) => choice.isCorrect)) {
      resolvedChoices.first.isCorrect = true;
    }

    return QuizDraftQuestion(
      text: text,
      timeLimitSec: timeLimitSec,
      choices: resolvedChoices,
    );
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
      _draftQuestions.add(_newDraftQuestion());
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

      final parsedQuizId = asInt(quiz['id'], -1);
      _editingQuizId = parsedQuizId > 0 ? parsedQuizId : null;
      if (_editingQuizId != null) {
        _selectedQuizId = _editingQuizId;
      }
      _quizTitleController.text = quiz['title']?.toString() ?? '';
      _quizDescriptionController.text = quiz['description']?.toString() ?? '';

      final questionMaps = ((quiz['questions'] as List<dynamic>? ?? <dynamic>[])
              .map(mapOrNull)
              .whereType<Map<String, dynamic>>()
              .toList())
            ..sort((a, b) => asInt(a['order']).compareTo(asInt(b['order'])));

      for (final questionMap in questionMaps) {
        final choiceMaps = ((questionMap['choices'] as List<dynamic>? ?? <dynamic>[])
                .map(mapOrNull)
                .whereType<Map<String, dynamic>>()
                .toList())
              ..sort((a, b) => asInt(a['order']).compareTo(asInt(b['order'])));

        final draftChoices = choiceMaps
            .map(
              (choice) => QuizDraftChoice(
                text: choice['text']?.toString() ?? '',
                isCorrect: choice['is_correct'] == true,
              ),
            )
            .toList();

        while (draftChoices.length < 2) {
          draftChoices.add(QuizDraftChoice());
        }

        _draftQuestions.add(
          _newDraftQuestion(
            text: questionMap['text']?.toString() ?? '',
            timeLimitSec: asInt(questionMap['time_limit_sec'], 20),
            choices: draftChoices,
          ),
        );
      }

      if (_draftQuestions.isEmpty) {
        _draftQuestions.add(_newDraftQuestion());
      }
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
      _draftQuestions.add(_newDraftQuestion());
    });
  }

  void _removeDraftQuestion(int questionIndex) {
    if (_draftQuestions.length <= 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Quiz must contain at least one question.')),
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
        const SnackBar(content: Text('Each question needs at least two answer choices.')),
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

  void _setDraftCorrectChoice(QuizDraftQuestion question, int selectedChoiceIndex) {
    setState(() {
      for (var i = 0; i < question.choices.length; i++) {
        question.choices[i].isCorrect = i == selectedChoiceIndex;
      }
    });
  }

  Map<String, dynamic> _buildQuizPayload() {
    final title = _quizTitleController.text.trim();
    if (title.isEmpty) {
      throw const FormatException('Quiz title is required.');
    }

    if (_draftQuestions.isEmpty) {
      throw const FormatException('Add at least one question.');
    }

    final questions = <Map<String, dynamic>>[];

    for (var questionIndex = 0; questionIndex < _draftQuestions.length; questionIndex++) {
      final question = _draftQuestions[questionIndex];
      final questionNumber = questionIndex + 1;
      final questionText = question.textController.text.trim();
      if (questionText.isEmpty) {
        throw FormatException('Question $questionNumber text is required.');
      }

      final timeLimit = int.tryParse(question.timeLimitController.text.trim());
      if (timeLimit == null || timeLimit < 5 || timeLimit > 180) {
        throw FormatException('Question $questionNumber time limit must be between 5 and 180 seconds.');
      }

      final choices = <Map<String, dynamic>>[];
      var correctCount = 0;

      for (final choice in question.choices) {
        final choiceText = choice.textController.text.trim();
        if (choiceText.isEmpty) {
          continue;
        }

        if (choice.isCorrect) {
          correctCount += 1;
        }

        choices.add({
          'text': choiceText,
          'order': choices.length + 1,
          'is_correct': choice.isCorrect,
        });
      }

      if (choices.length < 2) {
        throw FormatException('Question $questionNumber must have at least two non-empty choices.');
      }
      if (correctCount != 1) {
        throw FormatException('Question $questionNumber must have exactly one correct choice.');
      }

      questions.add({
        'text': questionText,
        'order': questionNumber,
        'time_limit_sec': timeLimit,
        'choices': choices,
      });
    }

    return {
      'title': title,
      'description': _quizDescriptionController.text.trim(),
      'questions': questions,
    };
  }
  Future<void> _persistAuthSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      await prefs.setString(_prefsAccessTokenKey, _accessToken!);
    } else {
      await prefs.remove(_prefsAccessTokenKey);
    }

    if (_refreshToken != null && _refreshToken!.isNotEmpty) {
      await prefs.setString(_prefsRefreshTokenKey, _refreshToken!);
    } else {
      await prefs.remove(_prefsRefreshTokenKey);
    }

    final apiBase = _apiController.text.trim();
    if (apiBase.isNotEmpty) {
      await prefs.setString(_prefsApiBaseUrlKey, apiBase);
    }

    final username = _usernameController.text.trim();
    if (username.isNotEmpty) {
      await prefs.setString(_prefsUsernameKey, username);
    }
  }

  Future<void> _clearPersistedAuthSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsAccessTokenKey);
    await prefs.remove(_prefsRefreshTokenKey);
  }

  Future<void> _restoreAuthSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedApiBase = prefs.getString(_prefsApiBaseUrlKey);
      final savedUsername = prefs.getString(_prefsUsernameKey);
      final savedAccess = prefs.getString(_prefsAccessTokenKey);
      final savedRefresh = prefs.getString(_prefsRefreshTokenKey);

      if (savedApiBase != null && savedApiBase.isNotEmpty) {
        _apiController.text = savedApiBase;
      }
      if (savedUsername != null && savedUsername.isNotEmpty) {
        _usernameController.text = savedUsername;
      }

      if (savedAccess == null || savedAccess.isEmpty) {
        if (mounted) {
          setState(() {
            _restoringSession = false;
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _accessToken = savedAccess;
          _refreshToken = savedRefresh;
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

  Future<T> _runTeacherRequest<T>(Future<T> Function(ApiClient client) request) async {
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
    _questionTimer?.cancel();
    if (endsAt == null) {
      setState(() {
        _questionTimeLeftLabel = '--:--';
      });
      return;
    }

    void tick() {
      final remaining = endsAt.difference(DateTime.now());
      if (remaining.inMilliseconds <= 0) {
        _questionTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _questionTimeLeftLabel = '00:00';
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _questionTimeLeftLabel = formatRemaining(remaining);
      });
    }

    tick();
    _questionTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<void> _connectSessionSocket(int sessionId) async {
    await _closeSessionSocket();
    final url = _client().sessionWebSocketUrl(sessionId);

    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _sessionSocket = channel;
      _sessionSubscription = channel.stream.listen(
        (raw) {
          try {
            final decoded = jsonDecode(raw as String);
            final message = mapOrNull(decoded);
            if (message == null) return;
            _handleTeacherSocketEvent(message);
          } catch (_) {
            _appendEvent('Invalid socket payload.');
          }
        },
        onError: (error) {
          _appendEvent('Socket error: $error');
          setState(() {
            _wsConnected = false;
          });
        },
        onDone: () {
          _appendEvent('Socket disconnected.');
          setState(() {
            _wsConnected = false;
          });
        },
      );

      setState(() {
        _wsConnected = true;
      });
      _appendEvent('Connected to session socket.');
    } catch (e) {
      setState(() {
        _wsConnected = false;
      });
      _appendEvent('Failed to connect socket: $e');
    }
  }

  Future<void> _closeSessionSocket() async {
    await _sessionSubscription?.cancel();
    _sessionSubscription = null;
    await _sessionSocket?.sink.close();
    _sessionSocket = null;
    if (mounted) {
      setState(() {
        _wsConnected = false;
      });
    }
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
          'participants_count': payload['participants_count'] ?? (_session?['participants_count'] ?? 0),
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
        _patchSession({'participants_count': payload['participants_count'] ?? (_session?['participants_count'] ?? 0)});
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
            quizzes.any((rawQuiz) => asInt(mapOrNull(rawQuiz)?['id'], -1) == preferredQuizId);
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
      final payload = _buildQuizPayload();
      final editingQuizId = _editingQuizId;

      final savedQuiz = editingQuizId == null
          ? await _runTeacherRequest((client) => client.createQuiz(payload))
          : await _runTeacherRequest((client) => client.updateQuiz(editingQuizId, payload));

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

    final quizTitle = _quizById(quizId)?['title']?.toString() ?? 'selected quiz';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete quiz?'),
          content: Text('Delete "$quizTitle" permanently? This action cannot be undone.'),
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
      final session = await _runTeacherRequest((client) => client.createSession(_selectedQuizId!));
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
      final started = await _runTeacherRequest((client) => client.startSession(_session!['id'] as int));
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
      final payload = await _runTeacherRequest((client) => client.nextQuestion(_session!['id'] as int));
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
      final payload = await _runTeacherRequest((client) => client.revealAnswer(_session!['id'] as int));
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
      final finished = await _runTeacherRequest((client) => client.finishSession(_session!['id'] as int));
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
      final rows = await _runTeacherRequest((client) => client.getLeaderboard(_session!['id'] as int));
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
                        final row = mapOrNull(rows[index]) ?? <String, dynamic>{};
                        return ListTile(
                          dense: true,
                          leading: Text('#${index + 1}'),
                          title: Text('${row['participant_name']}'),
                          subtitle: Text('${row['phone']}'),
                          trailing: Text('Pts: ${row['points']} | Correct: ${row['correct_answers']}'),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _apiController,
            decoration: const InputDecoration(
              labelText: 'API base URL',
              hintText: _defaultApiBaseUrl,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Teacher Auth', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _usernameController,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _emailController,
                    decoration: const InputDecoration(labelText: 'Email (optional)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _signupCodeController,
                    decoration: const InputDecoration(labelText: 'Signup code (optional)'),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton(
                        onPressed: _loading ? null : _registerTeacher,
                        child: const Text('Register'),
                      ),
                      FilledButton.tonal(
                        onPressed: _loading ? null : _loginTeacher,
                        child: const Text('Login'),
                      ),
                      OutlinedButton(
                        onPressed: _loading ? null : _loadMe,
                        child: const Text('Who am I'),
                      ),
                      OutlinedButton(
                        onPressed: _loading ? null : _logout,
                        child: const Text('Logout'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_restoringSession)
                    const Text('Restoring saved teacher session...'),
                  Text(
                    _isLoggedIn
                        ? 'Logged in${_teacher != null ? ': ${_teacher!['username']}' : ''}'
                        : 'Not authenticated',
                  ),
                  if (_refreshToken != null && _refreshToken!.isNotEmpty)
                    const Text('Refresh token is stored locally for this browser profile.'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quiz Builder', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _editingQuizId == null
                        ? 'Mode: new quiz draft'
                        : 'Mode: editing quiz #$_editingQuizId',
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (_quizzes.isNotEmpty)
                        Expanded(
                          child: DropdownButton<int>(
                            value: _selectedQuizId,
                            isExpanded: true,
                            items: _quizzes
                                .map((rawQuiz) {
                                  final quiz = mapOrNull(rawQuiz) ?? <String, dynamic>{};
                                  final quizId = asInt(quiz['id'], 0);
                                  final quizTitle = quiz['title']?.toString() ?? 'Untitled';
                                  return DropdownMenuItem<int>(
                                    value: quizId,
                                    child: Text('$quizId: $quizTitle'),
                                  );
                                })
                                .toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedQuizId = value;
                              });
                            },
                          ),
                        )
                      else
                        const Expanded(child: Text('No quizzes yet')),
                      const SizedBox(width: 12),
                      FilledButton.tonal(
                        onPressed: (_loading || !_isLoggedIn || _selectedQuizId == null)
                            ? null
                            : _loadSelectedQuizIntoDraft,
                        child: const Text('Load'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton(
                        onPressed: (_loading || !_isLoggedIn) ? null : _saveQuizDraft,
                        child: Text(_editingQuizId == null ? 'Save new quiz' : 'Save changes'),
                      ),
                      FilledButton.tonal(
                        onPressed: (_loading || !_isLoggedIn) ? null : () => _resetQuizDraft(),
                        child: const Text('New draft'),
                      ),
                      OutlinedButton(
                        onPressed: (_loading || !_isLoggedIn) ? null : () => _refreshQuizzes(),
                        child: const Text('Refresh quizzes'),
                      ),
                      OutlinedButton(
                        onPressed: (_loading || !_isLoggedIn || _selectedQuizId == null)
                            ? null
                            : _deleteSelectedQuiz,
                        child: const Text('Delete selected'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _quizTitleController,
                    decoration: const InputDecoration(labelText: 'Quiz title'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _quizDescriptionController,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Description (optional)'),
                  ),
                  const SizedBox(height: 12),
                  ..._draftQuestions.asMap().entries.map((questionEntry) {
                    final questionIndex = questionEntry.key;
                    final question = questionEntry.value;
                    final correctChoiceIndex = question.choices.indexWhere((choice) => choice.isCorrect);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Question ${questionIndex + 1}',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const Spacer(),
                                IconButton(
                                  onPressed: _loading ? null : () => _removeDraftQuestion(questionIndex),
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: 'Remove question',
                                ),
                              ],
                            ),
                            TextField(
                              controller: question.textController,
                              decoration: const InputDecoration(labelText: 'Question text'),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: question.timeLimitController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Time limit (sec)',
                                hintText: '5-180',
                              ),
                            ),
                            const SizedBox(height: 10),
                            ...question.choices.asMap().entries.map((choiceEntry) {
                              final choiceIndex = choiceEntry.key;
                              final choice = choiceEntry.value;

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Radio<int>(
                                      value: choiceIndex,
                                      groupValue: correctChoiceIndex >= 0 ? correctChoiceIndex : null,
                                      onChanged: _loading
                                          ? null
                                          : (_) => _setDraftCorrectChoice(question, choiceIndex),
                                    ),
                                    Expanded(
                                      child: TextField(
                                        controller: choice.textController,
                                        decoration: InputDecoration(
                                          labelText: 'Choice ${choiceIndex + 1}',
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: _loading
                                          ? null
                                          : () => _removeDraftChoice(question, choiceIndex),
                                      icon: const Icon(Icons.close),
                                      tooltip: 'Remove choice',
                                    ),
                                  ],
                                ),
                              );
                            }),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: _loading ? null : () => _addDraftChoice(question),
                                icon: const Icon(Icons.add),
                                label: const Text('Add choice'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  FilledButton.tonalIcon(
                    onPressed: (_loading || !_isLoggedIn) ? null : _addDraftQuestion,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Add question'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _selectedQuizId == null
                      ? 'Select a quiz in builder to create a live session.'
                      : 'Session quiz: #$_selectedQuizId',
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: (_loading || !_isLoggedIn || _selectedQuizId == null) ? null : _createSession,
                child: const Text('Create session'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_session != null) ...[
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('PIN: ${_session!['pin']}', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text('Status: ${_session!['status']}'),
                    Text('Participants: ${_session!['participants_count'] ?? 0}'),
                    Text('WebSocket: ${_wsConnected ? 'connected' : 'disconnected'}'),
                    if (_activeQuestion != null)
                      Text('Current question: ${_activeQuestion!['text']}'),
                    if (_activeQuestion != null)
                      Text('Time left: $_questionTimeLeftLabel'),
                    if (_answeredCount > 0)
                      Text('Answers received: $_answeredCount'),
                    const SizedBox(height: 8),
                    Text('Join URL: ${_session!['join_url']}'),
                    const SizedBox(height: 12),
                    Center(
                      child: QrImageView(
                        data: _session!['join_url'] as String,
                        size: 180,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton(
                          onPressed: _startSession,
                          child: const Text('Start'),
                        ),
                        FilledButton.tonal(
                          onPressed: _nextQuestion,
                          child: const Text('Next question'),
                        ),
                        FilledButton.tonal(
                          onPressed: _revealAnswers,
                          child: const Text('Reveal answers'),
                        ),
                        FilledButton.tonal(
                          onPressed: _finishSession,
                          child: const Text('Finish'),
                        ),
                        OutlinedButton(
                          onPressed: _showLeaderboard,
                          child: const Text('Leaderboard'),
                        ),
                        OutlinedButton(
                          onPressed: () {
                            final exportUrl =
                                '${_apiController.text}/sessions/${_session!['id']}/results/export/';
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Export URL: $exportUrl')),
                            );
                          },
                          child: const Text('Export URL'),
                        ),
                      ],
                    ),
                    if (_revealPayload != null) ...[
                      const SizedBox(height: 12),
                      const Divider(),
                      Text('Reveal results', style: Theme.of(context).textTheme.titleMedium),
                      Text('Total answers: ${_revealPayload!['total_answers'] ?? 0}'),
                      Text('Points awarded: ${_revealPayload!['total_points_awarded'] ?? 0}'),
                      Text('Revealed by: ${_revealPayload!['revealed_by'] ?? 'teacher'}'),
                      const SizedBox(height: 8),
                      ...((_revealPayload!['choices'] as List<dynamic>? ?? <dynamic>[]).map((rawChoice) {
                        final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
                        final correct = choice['is_correct'] == true;
                        return ListTile(
                          dense: true,
                          leading: Icon(correct ? Icons.check_circle : Icons.circle_outlined),
                          title: Text('${choice['text']}'),
                          trailing: Text('Votes: ${choice['answers_count'] ?? 0} | Pts: ${choice['points_awarded'] ?? 0}'),
                        );
                      })),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Live events', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_events.isEmpty)
                      const Text('No events yet.')
                    else
                      ..._events.map((event) => Text(event)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class ParticipantPanel extends StatefulWidget {
  const ParticipantPanel({super.key});

  @override
  State<ParticipantPanel> createState() => _ParticipantPanelState();
}

class _ParticipantPanelState extends State<ParticipantPanel> {
  final _apiController = TextEditingController(text: _defaultApiBaseUrl);
  final _pinController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  Map<String, dynamic>? _joinPayload;
  Map<String, dynamic>? _activeQuestion;
  Map<String, dynamic>? _revealPayload;
  bool _consent = false;
  bool _loading = false;
  int _totalPoints = 0;
  int _lastAnswerPoints = 0;
  String? _error;
  String _sessionStatus = 'waiting';
  bool _questionAnswered = false;
  int? _selectedChoiceId;
  bool _sessionFinished = false;
  String _timeLeftLabel = '--:--';
  bool _isQuestionExpired = false;
  Map<String, dynamic>? _legalDocuments;
  bool _loadingLegalDocuments = false;
  String? _joinTokenFromLink;
  bool _useJoinTokenFromLink = false;

  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  bool _socketConnected = false;
  Timer? _countdownTimer;
  final List<String> _events = [];

  ApiClient _client() => ApiClient(_apiController.text.trim());

  @override
  void initState() {
    super.initState();
    _configureJoinSourceFromUrl();
    _loadLegalDocuments(showError: false);
  }

  void _configureJoinSourceFromUrl() {
    final tokenFromUrl = Uri.base.queryParameters['token']?.trim() ?? '';
    if (tokenFromUrl.isNotEmpty) {
      _joinTokenFromLink = tokenFromUrl;
      _useJoinTokenFromLink = true;
      return;
    }

    final pinFromUrl = Uri.base.queryParameters['pin']?.trim() ?? '';
    if (pinFromUrl.isNotEmpty) {
      _pinController.text = pinFromUrl;
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _closeSocket();
    _apiController.dispose();
    _pinController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _appendEvent(String text) {
    if (!mounted) return;
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _events.insert(0, '[$timestamp] $text');
      if (_events.length > 25) {
        _events.removeRange(25, _events.length);
      }
    });
  }

  String _legalVersion(String section) {
    final sectionMap = mapOrNull(_legalDocuments?[section]);
    final version = sectionMap?['version']?.toString() ?? '';
    return version.isEmpty ? 'n/a' : version;
  }

  String get _consentCheckboxLabel {
    final privacyVersion = _legalVersion('privacy_policy');
    final consentVersion = _legalVersion('personal_data_consent');
    return 'I consent to personal data processing and privacy policy '
        '(privacy v$privacyVersion, consent v$consentVersion)';
  }

  Future<void> _loadLegalDocuments({bool showError = true}) async {
    if (_loadingLegalDocuments) {
      return;
    }

    if (mounted) {
      setState(() {
        _loadingLegalDocuments = true;
        if (showError) {
          _error = null;
        }
      });
    }

    try {
      final legalDocuments = await _client().getCurrentLegalDocuments();
      if (!mounted) return;
      setState(() {
        _legalDocuments = legalDocuments;
      });
    } catch (e) {
      if (showError && mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingLegalDocuments = false;
        });
      }
    }
  }

  Future<void> _openLegalDocumentsPage() async {
    if (_legalDocuments == null) {
      await _loadLegalDocuments();
    }
    if (!mounted || _legalDocuments == null) {
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LegalDocumentsPage(documents: _legalDocuments!, apiBaseUrl: _apiController.text.trim()),
      ),
    );
  }

  void _startCountdown(DateTime? endsAt) {
    _countdownTimer?.cancel();
    if (endsAt == null) {
      setState(() {
        _timeLeftLabel = '--:--';
        _isQuestionExpired = false;
      });
      return;
    }

    void tick() {
      final remaining = endsAt.difference(DateTime.now());
      if (remaining.inMilliseconds <= 0) {
        _countdownTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _timeLeftLabel = '00:00';
          _isQuestionExpired = true;
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _timeLeftLabel = formatRemaining(remaining);
        _isQuestionExpired = false;
      });
    }

    tick();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void _applyQuestionState(Map<String, dynamic>? question, dynamic endsAtRaw) {
    setState(() {
      _activeQuestion = question;
      _revealPayload = null;
      _questionAnswered = false;
      _selectedChoiceId = null;
      _isQuestionExpired = false;
    });
    _startCountdown(parseDateTimeLocal(endsAtRaw));
  }

  Future<void> _connectSocket(int sessionId) async {
    await _closeSocket();
    final url = _client().sessionWebSocketUrl(sessionId);

    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _socket = channel;
      _socketSubscription = channel.stream.listen(
        (raw) {
          try {
            final decoded = jsonDecode(raw as String);
            final message = mapOrNull(decoded);
            if (message == null) return;
            _handleParticipantSocketEvent(message);
          } catch (_) {
            _appendEvent('Invalid socket payload.');
          }
        },
        onError: (error) {
          _appendEvent('Socket error: $error');
          setState(() {
            _socketConnected = false;
          });
        },
        onDone: () {
          _appendEvent('Socket disconnected.');
          setState(() {
            _socketConnected = false;
          });
        },
      );

      setState(() {
        _socketConnected = true;
      });
      _appendEvent('Connected to live session.');
    } catch (e) {
      setState(() {
        _socketConnected = false;
      });
      _appendEvent('Failed to connect socket: $e');
    }
  }

  Future<void> _closeSocket() async {
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _socket?.sink.close();
    _socket = null;
    if (mounted) {
      setState(() {
        _socketConnected = false;
      });
    }
  }

  void _handleParticipantSocketEvent(Map<String, dynamic> message) {
    final event = message['event']?.toString() ?? 'unknown';
    final payload = mapOrNull(message['payload']) ?? <String, dynamic>{};

    switch (event) {
      case 'session_state':
      case 'session_started':
        final incomingQuestion = mapOrNull(payload['current_question']);
        final incomingQuestionId = asInt(incomingQuestion?['id'], -1);
        final activeQuestionId = asInt(_activeQuestion?['id'], -2);
        final isAnswerRevealed = payload['is_answer_revealed'] == true;

        setState(() {
          _sessionStatus = payload['status']?.toString() ?? _sessionStatus;
          _sessionFinished = _sessionStatus == 'finished';
        });

        if (incomingQuestionId != activeQuestionId || incomingQuestion == null) {
          _applyQuestionState(incomingQuestion, payload['question_ends_at']);
        } else {
          _startCountdown(parseDateTimeLocal(payload['question_ends_at']));
        }

        if (isAnswerRevealed && incomingQuestion != null) {
          _countdownTimer?.cancel();
          setState(() {
            _isQuestionExpired = true;
            _timeLeftLabel = '00:00';
          });
        }
        break;
      case 'question_started':
        setState(() {
          _sessionStatus = payload['status']?.toString() ?? 'live';
          _sessionFinished = false;
          _lastAnswerPoints = 0;
        });
        _applyQuestionState(mapOrNull(payload['question']), payload['question_ends_at']);
        break;
      case 'answer_revealed':
        _countdownTimer?.cancel();
        setState(() {
          _revealPayload = payload;
          _timeLeftLabel = '00:00';
          _isQuestionExpired = true;
        });
        break;
      case 'session_finished':
        _countdownTimer?.cancel();
        setState(() {
          _sessionStatus = 'finished';
          _sessionFinished = true;
          _activeQuestion = null;
          _timeLeftLabel = '--:--';
          _isQuestionExpired = false;
        });
        break;
      default:
        break;
    }

    _appendEvent('Event: $event');
  }

  Future<void> _join() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final joinToken = _useJoinTokenFromLink ? _joinTokenFromLink : null;
      final pin = _useJoinTokenFromLink ? null : _pinController.text.trim();

      final payload = await _client().joinSession(
        pin: pin,
        joinToken: joinToken,
        phone: _phoneController.text.trim(),
        name: _nameController.text.trim(),
        consent: _consent,
      );

      final isAnswerRevealed = payload['is_answer_revealed'] == true;

      setState(() {
        _joinPayload = payload;
        _activeQuestion = mapOrNull(payload['current_question']);
        _revealPayload = null;
        _totalPoints = 0;
        _lastAnswerPoints = 0;
        _sessionStatus = payload['session_status']?.toString() ?? 'waiting';
        _sessionFinished = _sessionStatus == 'finished';
        _questionAnswered = false;
        _selectedChoiceId = null;
        _isQuestionExpired = isAnswerRevealed;
        _timeLeftLabel = isAnswerRevealed ? '00:00' : '--:--';
        _legalDocuments = mapOrNull(payload['legal_documents']) ?? _legalDocuments;
        _events.clear();
      });

      if (isAnswerRevealed) {
        _countdownTimer?.cancel();
      } else {
        _startCountdown(parseDateTimeLocal(payload['question_ends_at']));
      }

      await _connectSocket(payload['session_id'] as int);
    } catch (e) {
      setState(() {
        final fallbackHint = _useJoinTokenFromLink
            ? '\nYou can switch to manual PIN input if this link is outdated.'
            : '';
        _error = '${e.toString()}$fallbackHint';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _answer(int choiceId) async {
    if (_joinPayload == null || _activeQuestion == null || _questionAnswered || _isQuestionExpired) {
      return;
    }

    try {
      final response = await _client().submitAnswer(
        sessionParticipantId: _joinPayload!['session_participant_id'] as int,
        questionId: _activeQuestion!['id'] as int,
        choiceId: choiceId,
      );

      setState(() {
        _totalPoints = asInt(response['total_points'], _totalPoints);
        _lastAnswerPoints = asInt(response['score_points']);
        _questionAnswered = true;
        _selectedChoiceId = choiceId;
      });

      _appendEvent('Answer submitted (+$_lastAnswerPoints pts).');
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _apiController,
            decoration: const InputDecoration(labelText: 'API base URL'),
          ),
          const SizedBox(height: 12),
          if (_useJoinTokenFromLink && _joinTokenFromLink != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Join link detected. Session PIN is not required.'),
                    const SizedBox(height: 6),
                    SelectableText('Token: $_joinTokenFromLink'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _loading
                          ? null
                          : () {
                              setState(() {
                                _useJoinTokenFromLink = false;
                              });
                            },
                      child: const Text('Use PIN instead'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ] else ...[
            TextField(
              controller: _pinController,
              decoration: const InputDecoration(labelText: 'Session PIN'),
            ),
            if (_joinTokenFromLink != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _loading
                    ? null
                    : () {
                        setState(() {
                          _useJoinTokenFromLink = true;
                        });
                      },
                child: const Text('Use token from join link'),
              ),
            ],
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneController,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _consent,
            onChanged: (value) {
              setState(() {
                _consent = value ?? false;
              });
            },
            title: Text(_consentCheckboxLabel),
            contentPadding: EdgeInsets.zero,
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton(
                onPressed: (_loading || _loadingLegalDocuments) ? null : _openLegalDocumentsPage,
                child: const Text('Privacy & consent'),
              ),
              OutlinedButton(
                onPressed: (_loading || _loadingLegalDocuments) ? null : () => _loadLegalDocuments(),
                child: const Text('Refresh legal docs'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _loading ? null : _join,
            child: const Text('Join session'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_joinPayload != null) ...[
            const SizedBox(height: 20),
            Text('Points: $_totalPoints', style: Theme.of(context).textTheme.titleLarge),
            Text('Last answer: +$_lastAnswerPoints pts'),
            Text('Status: $_sessionStatus'),
            Text('WebSocket: ${_socketConnected ? 'connected' : 'disconnected'}'),
            if (_activeQuestion != null) Text('Time left: $_timeLeftLabel'),
            const SizedBox(height: 12),
            if (_sessionFinished)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Session finished. Thanks for playing!'),
                ),
              )
            else if (_activeQuestion == null)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Waiting for teacher to start the next question...'),
                ),
              )
            else
              _QuestionCard(
                question: _activeQuestion!,
                onAnswer: _answer,
                questionLocked: _questionAnswered || _isQuestionExpired,
                selectedChoiceId: _selectedChoiceId,
              ),
            if (_isQuestionExpired && !_questionAnswered && !_sessionFinished)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Time is over. Wait for results and the next question.'),
              ),
            if (_revealPayload != null) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Round results', style: Theme.of(context).textTheme.titleMedium),
                      Text('Total answers: ${_revealPayload!['total_answers'] ?? 0}'),
                      Text('Points awarded: ${_revealPayload!['total_points_awarded'] ?? 0}'),
                      Text('Revealed by: ${_revealPayload!['revealed_by'] ?? 'teacher'}'),
                      const SizedBox(height: 8),
                      ...((_revealPayload!['choices'] as List<dynamic>? ?? <dynamic>[]).map((rawChoice) {
                        final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
                        final isCorrect = choice['is_correct'] == true;
                        return ListTile(
                          dense: true,
                          leading: Icon(isCorrect ? Icons.check_circle : Icons.circle_outlined),
                          title: Text('${choice['text']}'),
                          trailing: Text('Votes: ${choice['answers_count'] ?? 0} | Pts: ${choice['points_awarded'] ?? 0}'),
                        );
                      })),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Live events', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_events.isEmpty)
                      const Text('No events yet.')
                    else
                      ..._events.map((event) => Text(event)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class LegalDocumentsPage extends StatelessWidget {
  const LegalDocumentsPage({
    super.key,
    required this.documents,
    required this.apiBaseUrl,
  });

  final Map<String, dynamic> documents;
  final String apiBaseUrl;

  String _version(String key) {
    final section = mapOrNull(documents[key]);
    final version = section?['version']?.toString() ?? '';
    return version.isEmpty ? 'n/a' : version;
  }

  String _url(String key) {
    final section = mapOrNull(documents[key]);
    return section?['url']?.toString() ?? '-';
  }

  @override
  Widget build(BuildContext context) {
    final privacyVersion = _version('privacy_policy');
    final consentVersion = _version('personal_data_consent');
    final contactEmail = documents['contact_email']?.toString() ?? '-';

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & Consent')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Current legal versions', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('Privacy policy version: $privacyVersion'),
                  SelectableText('Privacy policy URL: ${_url('privacy_policy')}'),
                  const SizedBox(height: 6),
                  Text('Personal data consent version: $consentVersion'),
                  SelectableText('Consent URL: ${_url('personal_data_consent')}'),
                  const SizedBox(height: 6),
                  SelectableText('Contact: $contactEmail'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Before joining a quiz, participant agrees to personal data processing '
                'and acknowledges the privacy policy. Versions above are saved with consent.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PublicLegalDocumentPage(
                        documentType: PublicLegalDocumentType.privacyPolicy,
                        initialDocuments: documents,
                        apiBaseUrl: apiBaseUrl,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.policy_outlined),
                label: const Text('Open privacy policy'),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PublicLegalDocumentPage(
                        documentType: PublicLegalDocumentType.personalDataConsent,
                        initialDocuments: documents,
                        apiBaseUrl: apiBaseUrl,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.gpp_maybe_outlined),
                label: const Text('Open consent form'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PublicLegalDocumentPage extends StatefulWidget {
  const PublicLegalDocumentPage({
    super.key,
    required this.documentType,
    this.initialDocuments,
    this.apiBaseUrl = _defaultApiBaseUrl,
  });

  final PublicLegalDocumentType documentType;
  final Map<String, dynamic>? initialDocuments;
  final String apiBaseUrl;

  @override
  State<PublicLegalDocumentPage> createState() => _PublicLegalDocumentPageState();
}

class _PublicLegalDocumentPageState extends State<PublicLegalDocumentPage> {
  Map<String, dynamic>? _documents;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _documents = widget.initialDocuments;
    if (_documents == null) {
      _loadLegalDocuments();
    }
  }

  String get _documentKey {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return 'privacy_policy';
    }
    return 'personal_data_consent';
  }

  String get _fallbackVersion {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return _defaultPrivacyPolicyVersion;
    }
    return _defaultPersonalDataConsentVersion;
  }

  String get _title {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return 'Privacy Policy';
    }
    return 'Personal Data Processing Consent';
  }

  String get _shortDescription {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return 'How umclick collects, stores, and uses participant data.';
    }
    return 'Rules of consent for collecting and processing personal data in umclick.';
  }

  String get _fallbackPublicUrl {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return '/legal/privacy';
    }
    return '/legal/consent';
  }

  String get _version {
    final section = mapOrNull(_documents?[_documentKey]);
    final version = section?['version']?.toString().trim() ?? '';
    return version.isEmpty ? _fallbackVersion : version;
  }

  String get _documentUrl {
    final section = mapOrNull(_documents?[_documentKey]);
    final url = section?['url']?.toString().trim() ?? '';
    return url.isEmpty ? _fallbackPublicUrl : url;
  }

  String get _contactEmail {
    final email = _documents?['contact_email']?.toString().trim() ?? '';
    return email.isEmpty ? 'privacy@umclick.local' : email;
  }

  List<MapEntry<String, String>> get _sections {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return const [
        MapEntry('1. Data We Collect', 'We collect participant phone number, display name, session participation metadata, answer history, and technical logs required for reliability and abuse prevention.'),
        MapEntry('2. Why We Process Data', 'Data is used to register participants, run live quiz sessions, calculate scores, build leaderboards, and export results to teachers after each session.'),
        MapEntry('3. Legal Basis', 'Processing is based on explicit participant consent accepted before joining a quiz session.'),
        MapEntry('4. Storage and Retention', 'Data is stored in service databases and retained only for the period required to deliver the service, resolve disputes, and satisfy legal obligations.'),
        MapEntry('5. Sharing and Access', 'Data is available to authorized teacher accounts of the specific session and to technical operators responsible for hosting and support under confidentiality duties.'),
        MapEntry('6. Participant Rights', 'Participants may request access, correction, restriction, deletion, or withdrawal of consent by contacting the legal email listed on this page.'),
      ];
    }

    return const [
      MapEntry('1. Scope of Consent', 'By joining a session, participant consents to processing of phone number, name, quiz answers, score values, and participation timestamps.'),
      MapEntry('2. Processing Actions', 'Consent covers collection, recording, systematization, storage, updating, extraction, transfer to authorized teacher accounts, and deletion after retention period.'),
      MapEntry('3. Purpose of Processing', 'Processing is required for participant authorization, quiz gameplay, score calculation, leaderboard display, and teacher report export.'),
      MapEntry('4. Consent Period', 'Consent is valid from the moment of acceptance and remains active until withdrawal or until processing purposes are fully achieved.'),
      MapEntry('5. Withdrawal Procedure', 'Participant can withdraw consent by contacting legal support. Withdrawal may limit ability to continue using quiz participation features.'),
      MapEntry('6. Confirmation', 'Continuing with registration confirms that participant has read and accepted this consent text and related privacy policy version.'),
    ];
  }

  Future<void> _loadLegalDocuments() async {
    if (_loading) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final docs = await ApiClient(widget.apiBaseUrl).getCurrentLegalDocuments();
      if (!mounted) return;
      setState(() {
        _documents = docs;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const HomePage()),
                (route) => false,
              );
            },
            icon: const Icon(Icons.home_outlined),
            label: const Text('Open app'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_loading) const SizedBox(height: 12),
          if (_error != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Failed to refresh legal metadata: $_error'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _loadLegalDocuments,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_shortDescription, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('Version: $_version'),
                  SelectableText('Public URL: $_documentUrl'),
                  SelectableText('Legal contact: $_contactEmail'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ..._sections.map((section) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(section.key, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Text(section.value),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.onAnswer,
    required this.questionLocked,
    required this.selectedChoiceId,
  });

  final Map<String, dynamic> question;
  final ValueChanged<int> onAnswer;
  final bool questionLocked;
  final int? selectedChoiceId;

  @override
  Widget build(BuildContext context) {
    final choices = (question['choices'] as List<dynamic>? ?? <dynamic>[]).toList()
      ..sort((a, b) {
        final aMap = mapOrNull(a) ?? <String, dynamic>{};
        final bMap = mapOrNull(b) ?? <String, dynamic>{};
        return asInt(aMap['order']).compareTo(asInt(bMap['order']));
      });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${question['text']}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('Time limit: ${question['time_limit_sec'] ?? '-'} sec'),
            const SizedBox(height: 12),
            ...choices.map((rawChoice) {
              final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
              final choiceId = asInt(choice['id'], -1);
              final isSelected = selectedChoiceId == choiceId;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: questionLocked ? null : () => onAnswer(choiceId),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: isSelected ? Theme.of(context).colorScheme.secondaryContainer : null,
                    ),
                    child: Text('${choice['text']}'),
                  ),
                ),
              );
            }),
            if (questionLocked)
              const Text('Answer locked. Waiting for teacher update.'),
          ],
        ),
      ),
    );
  }
}
