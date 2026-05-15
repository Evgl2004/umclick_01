import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/app_language.dart';
import 'l10n/app_strings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appLanguage.load();
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
    return ValueListenableBuilder<UiLanguage>(
      valueListenable: appLanguage,
      builder: (context, _, __) {
        return MaterialApp(
          title: 'umclick',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E7C7B)),
            useMaterial3: true,
            tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 350)),
          ),
          home: _buildHomeForEntryPoint(),
        );
      },
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
      appBar: AppBar(
        title: Text(appText(AppText.appTitle)),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: LanguageSwitcher()),
          ),
        ],
      ),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.school),
            label: appText(AppText.teacherTab),
          ),
          NavigationDestination(
            icon: const Icon(Icons.group),
            label: appText(AppText.participantTab),
          ),
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

  Future<Map<String, dynamic>> previewJoinSession({
    String? pin,
    String? joinToken,
  }) async {
    final queryParameters = <String, String>{};

    final normalizedPin = (pin ?? '').trim();
    if (normalizedPin.isNotEmpty) {
      queryParameters['pin'] = normalizedPin;
    }

    final normalizedJoinToken = (joinToken ?? '').trim();
    if (normalizedJoinToken.isNotEmpty) {
      queryParameters['token'] = normalizedJoinToken;
    }

    final response = await http.get(
      _uri('/sessions/join/preview/').replace(queryParameters: queryParameters),
      headers: _headers(),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load session preview');
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


  Widget _buildTeacherSectionCard(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }

  Widget _buildTeacherStatusChip({
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: foreground, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildSessionSetupCard(BuildContext context) {
    return _buildTeacherSectionCard(
      context,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFFE0F7FA),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.cast_for_education_outlined, color: Color(0xFF005F73)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(appText(AppText.teacherSessionSetupTitle), style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(appText(AppText.teacherSessionSetupSubtitle)),
                const SizedBox(height: 8),
                Text(
                  _selectedQuizId == null
                      ? appText(AppText.selectQuizForSession)
                      : appText(AppText.sessionQuiz, args: {'id': _selectedQuizId}),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: (_loading || !_isLoggedIn || _selectedQuizId == null) ? null : _createSession,
            icon: const Icon(Icons.playlist_add_check_circle_outlined),
            label: Text(appText(AppText.createSessionButton)),
          ),
        ],
      ),
    );
  }

  Widget _buildTeacherLiveSessionCard(BuildContext context) {
    final session = _session!;
    final joinUrl = session['join_url'] as String;
    final exportUrl = '${_apiController.text}/sessions/${session['id']}/results/export/';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF023047), Color(0xFF005F73), Color(0xFF0A9396)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF023047).withOpacity(0.2),
            blurRadius: 26,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText(AppText.teacherLivePanelTitle),
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _buildTeacherStatusChip(
                          icon: Icons.pin_outlined,
                          label: 'PIN: ${session['pin']}',
                          background: Colors.white,
                          foreground: const Color(0xFF023047),
                        ),
                        _buildTeacherStatusChip(
                          icon: Icons.flag_outlined,
                          label: appText(AppText.statusValue, args: {'status': session['status']}),
                          background: Colors.white.withOpacity(0.16),
                          foreground: Colors.white,
                        ),
                        _buildTeacherStatusChip(
                          icon: Icons.group_outlined,
                          label: appText(
                            AppText.participantsCount,
                            args: {'count': session['participants_count'] ?? 0},
                          ),
                          background: Colors.white.withOpacity(0.16),
                          foreground: Colors.white,
                        ),
                        _buildTeacherStatusChip(
                          icon: _wsConnected ? Icons.wifi : Icons.wifi_off,
                          label: appText(
                            AppText.webSocketState,
                            args: {
                              'state': _wsConnected
                                  ? appText(AppText.webSocketConnected)
                                  : appText(AppText.webSocketDisconnected),
                            },
                          ),
                          background: Colors.white.withOpacity(0.16),
                          foreground: Colors.white,
                        ),
                        if (_activeQuestion != null)
                          _buildTeacherStatusChip(
                            icon: Icons.timer_outlined,
                            label: appText(AppText.timeLeft, args: {'time': _questionTimeLeftLabel}),
                            background: Colors.white.withOpacity(0.16),
                            foreground: Colors.white,
                          ),
                        if (_answeredCount > 0)
                          _buildTeacherStatusChip(
                            icon: Icons.how_to_vote_outlined,
                            label: appText(AppText.answersReceived, args: {'count': _answeredCount}),
                            background: Colors.white.withOpacity(0.16),
                            foreground: Colors.white,
                          ),
                      ],
                    ),
                    if (_activeQuestion != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        appText(AppText.currentQuestion, args: {'text': _activeQuestion!['text']}),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 18),
              Container(
                width: 220,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  children: [
                    Text(appText(AppText.teacherQrCodeTitle), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 10),
                    QrImageView(data: joinUrl, size: 170),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SelectableText(
            appText(AppText.joinUrl, args: {'url': joinUrl}),
            style: TextStyle(color: Colors.white.withOpacity(0.88)),
          ),
          const SizedBox(height: 16),
          Text(
            appText(AppText.teacherRoundControlsTitle),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _startSession,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(appText(AppText.startButton)),
              ),
              FilledButton.tonalIcon(
                onPressed: _nextQuestion,
                icon: const Icon(Icons.skip_next_outlined),
                label: Text(appText(AppText.nextQuestionButton)),
              ),
              FilledButton.tonalIcon(
                onPressed: _revealAnswers,
                icon: const Icon(Icons.visibility_outlined),
                label: Text(appText(AppText.revealAnswersButton)),
              ),
              FilledButton.tonalIcon(
                onPressed: _finishSession,
                icon: const Icon(Icons.flag_outlined),
                label: Text(appText(AppText.finishButton)),
              ),
              OutlinedButton.icon(
                onPressed: _showLeaderboard,
                icon: const Icon(Icons.leaderboard_outlined),
                label: Text(appText(AppText.leaderboardButton)),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(appText(AppText.exportUrlSnack, args: {'url': exportUrl}))),
                  );
                },
                icon: const Icon(Icons.download_outlined),
                label: Text(appText(AppText.exportCsvButton)),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              ),
            ],
          ),
          if (_revealPayload != null) ...[
            const SizedBox(height: 16),
            _buildTeacherRevealResultsCard(context),
          ],
        ],
      ),
    );
  }

  Widget _buildTeacherRevealResultsCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            appText(AppText.revealResultsTitle),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            appText(AppText.totalAnswers, args: {'count': _revealPayload!['total_answers'] ?? 0}),
            style: const TextStyle(color: Colors.white),
          ),
          Text(
            appText(AppText.pointsAwarded, args: {'points': _revealPayload!['total_points_awarded'] ?? 0}),
            style: const TextStyle(color: Colors.white),
          ),
          Text(
            appText(AppText.revealedBy, args: {'value': _revealPayload!['revealed_by'] ?? 'teacher'}),
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 8),
          ...((_revealPayload!['choices'] as List<dynamic>? ?? <dynamic>[]).map((rawChoice) {
            final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
            final correct = choice['is_correct'] == true;
            return ListTile(
              dense: true,
              textColor: Colors.white,
              iconColor: Colors.white,
              leading: Icon(correct ? Icons.check_circle : Icons.circle_outlined),
              title: Text('${choice['text']}'),
              trailing: Text(appText(
                AppText.choiceStats,
                args: {
                  'votes': choice['answers_count'] ?? 0,
                  'points': choice['points_awarded'] ?? 0,
                },
              )),
            );
          })),
        ],
      ),
    );
  }

  Widget _buildTeacherLiveEventsCard(BuildContext context) {
    return _buildTeacherSectionCard(
      context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.liveEventsTitle), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_events.isEmpty)
            Text(appText(AppText.noEventsYet))
          else
            ..._events.map((event) => Text(event)),
        ],
      ),
    );
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
            decoration: InputDecoration(
              labelText: appText(AppText.apiBaseUrlLabel),
              hintText: _defaultApiBaseUrl,
              helperText: appText(AppText.teacherApiBaseUrlHelper),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appText(AppText.teacherAuthTitle), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _usernameController,
                    decoration: InputDecoration(labelText: appText(AppText.usernameLabel)),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(labelText: appText(AppText.passwordLabel)),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _emailController,
                    decoration: InputDecoration(labelText: appText(AppText.emailOptionalLabel)),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _signupCodeController,
                    decoration: InputDecoration(
                      labelText: appText(AppText.signupCodeOptionalLabel),
                      helperText: appText(AppText.signupCodeHelper),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton(
                        onPressed: _loading ? null : _registerTeacher,
                        child: Text(appText(AppText.registerButton)),
                      ),
                      FilledButton.tonal(
                        onPressed: _loading ? null : _loginTeacher,
                        child: Text(appText(AppText.loginButton)),
                      ),
                      OutlinedButton(
                        onPressed: _loading ? null : _loadMe,
                        child: Text(appText(AppText.teacherProfileButton)),
                      ),
                      OutlinedButton(
                        onPressed: _loading ? null : _logout,
                        child: Text(appText(AppText.logoutButton)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_restoringSession)
                    Text(appText(AppText.restoringTeacherSession)),
                  Text(
                    _isLoggedIn
                        ? appText(
                            AppText.loggedInTeacher,
                            args: {'suffix': _teacher != null ? ': ${_teacher!['username']}' : ''},
                          )
                        : appText(AppText.notAuthenticated),
                  ),
                  if (_refreshToken != null && _refreshToken!.isNotEmpty)
                    Text(appText(AppText.refreshTokenStored)),
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
                  Text(appText(AppText.quizBuilderTitle), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _editingQuizId == null
                        ? appText(AppText.quizDraftMode)
                        : appText(AppText.quizEditMode, args: {'id': _editingQuizId}),
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
                                  final quizTitle = quiz['title']?.toString() ?? appText(AppText.untitledQuiz);
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
                        Expanded(child: Text(appText(AppText.noQuizzesYet))),
                      const SizedBox(width: 12),
                      FilledButton.tonal(
                        onPressed: (_loading || !_isLoggedIn || _selectedQuizId == null)
                            ? null
                            : _loadSelectedQuizIntoDraft,
                        child: Text(appText(AppText.loadButton)),
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
                        child: Text(_editingQuizId == null
                            ? appText(AppText.saveNewQuizButton)
                            : appText(AppText.saveQuizChangesButton)),
                      ),
                      FilledButton.tonal(
                        onPressed: (_loading || !_isLoggedIn) ? null : () => _resetQuizDraft(),
                        child: Text(appText(AppText.newDraftButton)),
                      ),
                      OutlinedButton(
                        onPressed: (_loading || !_isLoggedIn) ? null : () => _refreshQuizzes(),
                        child: Text(appText(AppText.refreshQuizzesButton)),
                      ),
                      OutlinedButton(
                        onPressed: (_loading || !_isLoggedIn || _selectedQuizId == null)
                            ? null
                            : _deleteSelectedQuiz,
                        child: Text(appText(AppText.deleteSelectedButton)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _quizTitleController,
                    decoration: InputDecoration(labelText: appText(AppText.quizTitleLabel)),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _quizDescriptionController,
                    maxLines: 2,
                    decoration: InputDecoration(labelText: appText(AppText.quizDescriptionOptionalLabel)),
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
                                  appText(AppText.questionNumber, args: {'number': questionIndex + 1}),
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const Spacer(),
                                IconButton(
                                  onPressed: _loading ? null : () => _removeDraftQuestion(questionIndex),
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: appText(AppText.removeQuestionTooltip),
                                ),
                              ],
                            ),
                            TextField(
                              controller: question.textController,
                              decoration: InputDecoration(labelText: appText(AppText.questionTextLabel)),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: question.timeLimitController,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: appText(AppText.timeLimitSecLabel),
                                hintText: '5-180',
                                helperText: appText(AppText.timeLimitHelper),
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
                                          labelText: appText(AppText.choiceNumber, args: {'number': choiceIndex + 1}),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: _loading
                                          ? null
                                          : () => _removeDraftChoice(question, choiceIndex),
                                      icon: const Icon(Icons.close),
                                      tooltip: appText(AppText.removeChoiceTooltip),
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
                                label: Text(appText(AppText.addChoiceButton)),
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
                    label: Text(appText(AppText.addQuestionButton)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildSessionSetupCard(context),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_session != null) ...[
            const SizedBox(height: 20),
            _buildTeacherLiveSessionCard(context),
            const SizedBox(height: 12),
            _buildTeacherLiveEventsCard(context),
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
  Map<String, dynamic>? _joinPreview;
  bool _loadingJoinPreview = false;
  String? _joinTokenFromLink;
  bool _useJoinTokenFromLink = false;

  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  bool _socketConnected = false;
  Timer? _countdownTimer;
  final List<String> _events = [];

  ApiClient _client() => ApiClient(_apiController.text.trim());

  String? get _activeJoinToken => _useJoinTokenFromLink ? _joinTokenFromLink : null;

  String? get _activePin {
    if (_useJoinTokenFromLink) {
      return null;
    }
    final pin = _pinController.text.trim();
    return pin.isEmpty ? null : pin;
  }

  @override
  void initState() {
    super.initState();
    _configureJoinSourceFromUrl();
    _loadLegalDocuments(showError: false);
    _loadJoinPreview(showError: _joinTokenFromLink != null || _activePin != null);
  }

  void _configureJoinSourceFromUrl() {
    final apiBaseFromUrl = Uri.base.queryParameters['api']?.trim() ?? '';
    if (apiBaseFromUrl.isNotEmpty) {
      _apiController.text = apiBaseFromUrl;
    }

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

  Future<void> _loadJoinPreview({bool showError = true}) async {
    if (_loadingJoinPreview) {
      return;
    }

    final joinToken = _activeJoinToken;
    final pin = _activePin;
    if ((joinToken == null || joinToken.isEmpty) && (pin == null || pin.isEmpty)) {
      if (showError) {
        setState(() {
          _error = 'Enter a PIN or open a tokenized join link first.';
        });
      }
      return;
    }

    setState(() {
      _loadingJoinPreview = true;
      if (showError) {
        _error = null;
      }
    });

    try {
      final preview = await _client().previewJoinSession(
        pin: pin,
        joinToken: joinToken,
      );
      if (!mounted) return;
      setState(() {
        _joinPreview = preview;
        _legalDocuments = mapOrNull(preview['legal_documents']) ?? _legalDocuments;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _joinPreview = null;
        if (showError) {
          _error = e.toString();
        }
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingJoinPreview = false;
      });
    }
  }

  String _legalVersion(String section) {
    final sectionMap = mapOrNull(_legalDocuments?[section]);
    final version = sectionMap?['version']?.toString() ?? '';
    return version.isEmpty ? 'n/a' : version;
  }

  String get _consentCheckboxLabel {
    final privacyVersion = _legalVersion('privacy_policy');
    final consentVersion = _legalVersion('personal_data_consent');
    return appText(
      AppText.consentCheckboxLabel,
      args: {
        'privacyVersion': privacyVersion,
        'consentVersion': consentVersion,
      },
    );
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
      if (_joinPreview?['can_join'] == false) {
        throw StateError(
          _joinPreview?['closed_reason']?.toString() ?? 'Session is not available for joining.',
        );
      }

      final joinToken = _activeJoinToken;
      final pin = _activePin;

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

  Widget _buildJoinPreviewCard() {
    final preview = _joinPreview;
    if (_loadingJoinPreview && preview == null) {
      return const LinearProgressIndicator();
    }
    if (preview == null) {
      return const SizedBox.shrink();
    }

    final quiz = mapOrNull(preview['quiz']) ?? <String, dynamic>{};
    final title = quiz['title']?.toString() ?? appText(AppText.untitledQuizLong);
    final description = quiz['description']?.toString() ?? '';
    final statusLabel = preview['session_status']?.toString() ?? 'unknown';
    final participantsCount = asInt(preview['participants_count']);
    final canJoin = preview['can_join'] != false;
    final closedReason = preview['closed_reason']?.toString() ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: canJoin ? const Color(0xFFFFF4D6) : Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: canJoin ? const Color(0xFFFFB703).withOpacity(0.42) : Theme.of(context).colorScheme.error,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(canJoin ? Icons.fact_check_outlined : Icons.lock_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(description),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildStatusChip(
                icon: Icons.flag_outlined,
                label: appText(AppText.statusValue, args: {'status': statusLabel}),
                background: Colors.white.withOpacity(0.66),
                foreground: const Color(0xFF023047),
              ),
              _buildStatusChip(
                icon: Icons.group_outlined,
                label: appText(AppText.participantsCount, args: {'count': participantsCount}),
                background: Colors.white.withOpacity(0.66),
                foreground: const Color(0xFF023047),
              ),
            ],
          ),
          if (!canJoin && closedReason.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(closedReason, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_loadingJoinPreview) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }

  Widget _buildParticipantCard(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface.withOpacity(0.94),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }

  Widget _buildStatusChip({
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: foreground, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildParticipantHero(BuildContext context) {
    final isLive = _joinPayload != null;
    final statusText = appText(AppText.statusValue, args: {'status': _sessionStatus});
    final socketText = appText(
      AppText.webSocketState,
      args: {
        'state': _socketConnected ? appText(AppText.webSocketConnected) : appText(AppText.webSocketDisconnected),
      },
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF023047), Color(0xFF0A9396), Color(0xFFFFB703)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF023047).withOpacity(0.22),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusChip(
            icon: isLive ? Icons.bolt : Icons.qr_code_2,
            label: isLive ? appText(AppText.participantHeroLiveBadge) : appText(AppText.participantHeroJoinBadge),
            background: Colors.white.withOpacity(0.18),
            foreground: Colors.white,
          ),
          const SizedBox(height: 18),
          Text(
            isLive ? appText(AppText.participantHeroLiveTitle) : appText(AppText.participantHeroJoinTitle),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            isLive ? appText(AppText.participantHeroLiveSubtitle) : appText(AppText.participantHeroJoinSubtitle),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white.withOpacity(0.9),
                  height: 1.35,
                ),
          ),
          if (isLive) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _buildStatusChip(
                  icon: Icons.emoji_events_outlined,
                  label: appText(AppText.participantPoints, args: {'points': _totalPoints}),
                  background: Colors.white,
                  foreground: const Color(0xFF023047),
                ),
                _buildStatusChip(
                  icon: Icons.flag_outlined,
                  label: statusText,
                  background: Colors.white.withOpacity(0.18),
                  foreground: Colors.white,
                ),
                _buildStatusChip(
                  icon: _socketConnected ? Icons.wifi : Icons.wifi_off,
                  label: socketText,
                  background: Colors.white.withOpacity(0.18),
                  foreground: Colors.white,
                ),
                if (_activeQuestion != null)
                  _buildStatusChip(
                    icon: Icons.timer_outlined,
                    label: appText(AppText.timeLeft, args: {'time': _timeLeftLabel}),
                    background: Colors.white.withOpacity(0.18),
                    foreground: Colors.white,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildJoinConnectionCard(BuildContext context) {
    return _buildParticipantCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantJoinCardTitle), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          TextField(
            controller: _apiController,
            decoration: InputDecoration(
              labelText: appText(AppText.apiBaseUrlLabel),
              helperText: appText(AppText.participantApiBaseUrlHelper),
            ),
          ),
          const SizedBox(height: 14),
          if (_useJoinTokenFromLink && _joinTokenFromLink != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFE0F7FA),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF0A9396).withOpacity(0.32)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.link, color: Color(0xFF005F73)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(appText(AppText.joinLinkDetected))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(appText(AppText.joinTokenLabel, args: {'token': _joinTokenFromLink})),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: (_loading || _loadingJoinPreview) ? null : () => _loadJoinPreview(),
                        icon: const Icon(Icons.refresh),
                        label: Text(appText(AppText.refreshPreviewButton)),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loading
                            ? null
                            : () {
                                setState(() {
                                  _useJoinTokenFromLink = false;
                                  _joinPreview = null;
                                });
                              },
                        icon: const Icon(Icons.pin_outlined),
                        label: Text(appText(AppText.usePinInsteadButton)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            TextField(
              controller: _pinController,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
              decoration: InputDecoration(
                labelText: appText(AppText.sessionPinLabel),
                helperText: appText(AppText.sessionPinHelper),
                prefixIcon: const Icon(Icons.pin_outlined),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.tonalIcon(
                  onPressed: (_loading || _loadingJoinPreview) ? null : () => _loadJoinPreview(),
                  icon: const Icon(Icons.visibility_outlined),
                  label: Text(appText(AppText.previewSessionButton)),
                ),
                if (_joinTokenFromLink != null)
                  TextButton.icon(
                    onPressed: _loading
                        ? null
                        : () {
                            setState(() {
                              _useJoinTokenFromLink = true;
                              _joinPreview = null;
                            });
                            _loadJoinPreview(showError: false);
                          },
                    icon: const Icon(Icons.link),
                    label: Text(appText(AppText.useJoinTokenButton)),
                  ),
              ],
            ),
          ],
          if (_loadingJoinPreview || _joinPreview != null) ...[
            const SizedBox(height: 14),
            _buildJoinPreviewCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildParticipantProfileCard(BuildContext context) {
    return _buildParticipantCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantProfileCardTitle), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: appText(AppText.participantNameLabel),
              prefixIcon: const Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneController,
            decoration: InputDecoration(
              labelText: appText(AppText.participantPhoneLabel),
              helperText: appText(AppText.participantPhoneHelper),
              prefixIcon: const Icon(Icons.phone_outlined),
            ),
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
            controlAffinity: ListTileControlAffinity.leading,
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: (_loading || _loadingLegalDocuments) ? null : _openLegalDocumentsPage,
                icon: const Icon(Icons.policy_outlined),
                label: Text(appText(AppText.legalDocumentsButton)),
              ),
              OutlinedButton.icon(
                onPressed: (_loading || _loadingLegalDocuments) ? null : () => _loadLegalDocuments(),
                icon: const Icon(Icons.refresh),
                label: Text(appText(AppText.refreshLegalDocsButton)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _loading ? null : _join,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(appText(AppText.joinSessionButton)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _buildLiveSessionArea(BuildContext context) {
    return _buildParticipantCard(
      context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantLiveCardTitle), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(appText(AppText.participantLastAnswer, args: {'points': _lastAnswerPoints})),
          const SizedBox(height: 14),
          if (_sessionFinished)
            _buildRoundMessage(
              context,
              icon: Icons.flag_circle_outlined,
              message: appText(AppText.sessionFinishedMessage),
              color: const Color(0xFF0A9396),
            )
          else if (_activeQuestion == null)
            _buildRoundMessage(
              context,
              icon: Icons.hourglass_top_outlined,
              message: appText(AppText.waitingForQuestionMessage),
              color: const Color(0xFF005F73),
            )
          else
            _QuestionCard(
              question: _activeQuestion!,
              onAnswer: _answer,
              questionLocked: _questionAnswered || _isQuestionExpired,
              selectedChoiceId: _selectedChoiceId,
            ),
          if (_isQuestionExpired && !_questionAnswered && !_sessionFinished) ...[
            const SizedBox(height: 10),
            _buildRoundMessage(
              context,
              icon: Icons.timer_off_outlined,
              message: appText(AppText.timeOverMessage),
              color: Theme.of(context).colorScheme.error,
            ),
          ],
          if (_revealPayload != null) ...[
            const SizedBox(height: 14),
            _buildRevealResultsCard(context),
          ],
          const SizedBox(height: 14),
          _buildLiveEventsCard(context),
        ],
      ),
    );
  }

  Widget _buildRoundMessage(
    BuildContext context, {
    required IconData icon,
    required String message,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.11),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withOpacity(0.24)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }

  Widget _buildRevealResultsCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.55),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.revealResultsTitle), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(appText(AppText.totalAnswers, args: {'count': _revealPayload!['total_answers'] ?? 0})),
          Text(appText(AppText.pointsAwarded, args: {'points': _revealPayload!['total_points_awarded'] ?? 0})),
          Text(appText(AppText.revealedBy, args: {'value': _revealPayload!['revealed_by'] ?? 'teacher'})),
          const SizedBox(height: 8),
          ...((_revealPayload!['choices'] as List<dynamic>? ?? <dynamic>[]).map((rawChoice) {
            final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
            final isCorrect = choice['is_correct'] == true;
            return ListTile(
              dense: true,
              leading: Icon(isCorrect ? Icons.check_circle : Icons.circle_outlined),
              title: Text('${choice['text']}'),
              trailing: Text(appText(
                AppText.choiceStats,
                args: {
                  'votes': choice['answers_count'] ?? 0,
                  'points': choice['points_awarded'] ?? 0,
                },
              )),
            );
          })),
        ],
      ),
    );
  }

  Widget _buildLiveEventsCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.35),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.liveEventsTitle), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_events.isEmpty)
            Text(appText(AppText.noEventsYet))
          else
            ..._events.map((event) => Text(event)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFF7F9FC), Color(0xFFE0F7FA)],
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 920,
                  minHeight: constraints.maxHeight.isFinite && constraints.maxHeight > 32
                      ? constraints.maxHeight - 32
                      : 0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildParticipantHero(context),
                    const SizedBox(height: 16),
                    if (_joinPayload == null) ...[
                      _buildJoinConnectionCard(context),
                      const SizedBox(height: 14),
                      _buildParticipantProfileCard(context),
                    ] else ...[
                      _buildLiveSessionArea(context),
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
      appBar: AppBar(title: Text(appText(AppText.privacyConsentTitle))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appText(AppText.currentLegalVersionsTitle), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(appText(AppText.privacyVersionLabel, args: {'version': privacyVersion})),
                  SelectableText(appText(AppText.privacyUrlLabel, args: {'url': _url('privacy_policy')})),
                  const SizedBox(height: 6),
                  Text(appText(AppText.personalDataConsentVersionLabel, args: {'version': consentVersion})),
                  SelectableText(appText(AppText.personalDataConsentUrlLabel, args: {'url': _url('personal_data_consent')})),
                  const SizedBox(height: 6),
                  SelectableText(appText(AppText.legalContactLabel, args: {'email': contactEmail})),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                appText(AppText.legalConsentNotice),
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
                label: Text(appText(AppText.openPrivacyPolicyButton)),
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
                label: Text(appText(AppText.openConsentButton)),
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
      return appText(AppText.privacyPolicyTitle);
    }
    return appText(AppText.personalDataConsentTitle);
  }

  String get _shortDescription {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return appText(AppText.privacyPolicyDescription);
    }
    return appText(AppText.personalDataConsentDescription);
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
      return [
        MapEntry(appText(AppText.privacyDataCollectedTitle), appText(AppText.privacyDataCollectedBody)),
        MapEntry(appText(AppText.privacyPurposeTitle), appText(AppText.privacyPurposeBody)),
        MapEntry(appText(AppText.privacyLegalBasisTitle), appText(AppText.privacyLegalBasisBody)),
        MapEntry(appText(AppText.privacyRetentionTitle), appText(AppText.privacyRetentionBody)),
        MapEntry(appText(AppText.privacySharingTitle), appText(AppText.privacySharingBody)),
        MapEntry(appText(AppText.privacyRightsTitle), appText(AppText.privacyRightsBody)),
      ];
    }

    return [
      MapEntry(appText(AppText.consentScopeTitle), appText(AppText.consentScopeBody)),
      MapEntry(appText(AppText.consentActionsTitle), appText(AppText.consentActionsBody)),
      MapEntry(appText(AppText.consentPurposeTitle), appText(AppText.consentPurposeBody)),
      MapEntry(appText(AppText.consentPeriodTitle), appText(AppText.consentPeriodBody)),
      MapEntry(appText(AppText.consentWithdrawalTitle), appText(AppText.consentWithdrawalBody)),
      MapEntry(appText(AppText.consentConfirmationTitle), appText(AppText.consentConfirmationBody)),
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
            label: Text(appText(AppText.openAppButton)),
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
                    Text(appText(AppText.legalMetadataRefreshError, args: {'error': _error})),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _loadLegalDocuments,
                      icon: const Icon(Icons.refresh),
                      label: Text(appText(AppText.retryButton)),
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
                  Text(appText(AppText.publicLegalVersionLabel, args: {'version': _version})),
                  SelectableText(appText(AppText.publicLegalUrlLabel, args: {'url': _documentUrl})),
                  SelectableText(appText(AppText.publicLegalContactLabel, args: {'email': _contactEmail})),
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

  static const _answerColors = [
    Color(0xFFE21B3C),
    Color(0xFF1368CE),
    Color(0xFFD89E00),
    Color(0xFF26890C),
  ];

  static const _answerIcons = [
    Icons.change_history,
    Icons.diamond_outlined,
    Icons.circle_outlined,
    Icons.square_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final choices = (question['choices'] as List<dynamic>? ?? <dynamic>[]).toList()
      ..sort((a, b) {
        final aMap = mapOrNull(a) ?? <String, dynamic>{};
        final bMap = mapOrNull(b) ?? <String, dynamic>{};
        return asInt(aMap['order']).compareTo(asInt(bMap['order']));
      });

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF111827), Color(0xFF023047)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF111827).withOpacity(0.22),
            blurRadius: 26,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    appText(AppText.questionTimeLimitLabel, args: {'seconds': question['time_limit_sec'] ?? '-'}),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                if (questionLocked)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      appText(AppText.answerLockedMessage),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '${question['text']}',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                final useTwoColumns = constraints.maxWidth >= 680;
                final itemWidth = useTwoColumns ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;

                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: choices.asMap().entries.map((entry) {
                    final choiceIndex = entry.key;
                    final rawChoice = entry.value;
                    final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
                    final choiceId = asInt(choice['id'], -1);
                    final isSelected = selectedChoiceId == choiceId;
                    final color = _answerColors[choiceIndex % _answerColors.length];
                    final icon = _answerIcons[choiceIndex % _answerIcons.length];

                    return SizedBox(
                      width: itemWidth,
                      child: _buildAnswerTile(
                        context,
                        color: color,
                        icon: icon,
                        label: '${choice['text']}',
                        isSelected: isSelected,
                        isDimmed: questionLocked && !isSelected,
                        onTap: questionLocked ? null : () => onAnswer(choiceId),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerTile(
    BuildContext context, {
    required Color color,
    required IconData icon,
    required String label,
    required bool isSelected,
    required bool isDimmed,
    required VoidCallback? onTap,
  }) {
    final radius = BorderRadius.circular(24);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: isDimmed ? 0.58 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            minHeight: 88,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: color,
              borderRadius: radius,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.white.withOpacity(0.18),
                width: isSelected ? 4 : 1,
              ),
              boxShadow: [
                if (isSelected)
                  BoxShadow(
                    color: Colors.white.withOpacity(0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          height: 1.2,
                        ),
                  ),
                ),
                if (isSelected) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.check_circle, color: Colors.white),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
