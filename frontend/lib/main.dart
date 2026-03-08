import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const UmclickApp());
}

class UmclickApp extends StatelessWidget {
  const UmclickApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'umclick',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E7C7B)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

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
      throw Exception('Failed to register teacher: ${response.body}');
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
      throw Exception('Failed to login: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getMe() async {
    final response = await http.get(
      _uri('/auth/me/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to get profile: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getQuizzes() async {
    final response = await http.get(
      _uri('/quizzes/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to load quizzes: ${response.body}');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> createDemoQuiz(String title) async {
    final payload = {
      'title': title,
      'description': 'Auto-created demo quiz',
      'questions': [
        {
          'text': 'What is 2 + 2?',
          'order': 1,
          'time_limit_sec': 20,
          'choices': [
            {'text': '3', 'order': 1, 'is_correct': false},
            {'text': '4', 'order': 2, 'is_correct': true},
            {'text': '5', 'order': 3, 'is_correct': false},
            {'text': '22', 'order': 4, 'is_correct': false},
          ],
        }
      ],
    };

    final response = await http.post(
      _uri('/quizzes/'),
      headers: _headers(jsonBody: true, auth: true),
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to create quiz: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createSession(int quizId) async {
    final response = await http.post(
      _uri('/sessions/'),
      headers: _headers(jsonBody: true, auth: true),
      body: jsonEncode({'quiz': quizId, 'host_name': 'Teacher'}),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to create session: ${response.body}');
    }

    final created = jsonDecode(response.body) as Map<String, dynamic>;
    final details = await http.get(
      _uri('/sessions/${created['id']}/'),
      headers: _headers(auth: true),
    );
    if (details.statusCode >= 400) {
      throw Exception('Failed to fetch session details: ${details.body}');
    }
    return jsonDecode(details.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> startSession(int sessionId) async {
    final response = await http.post(
      _uri('/sessions/$sessionId/start/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to start session: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> finishSession(int sessionId) async {
    final response = await http.post(
      _uri('/sessions/$sessionId/finish/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to finish session: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> nextQuestion(int sessionId) async {
    final response = await http.post(
      _uri('/sessions/$sessionId/next-question/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to load next question: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> revealAnswer(int sessionId) async {
    final response = await http.post(
      _uri('/sessions/$sessionId/reveal-answer/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to reveal answers: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getLeaderboard(int sessionId) async {
    final response = await http.get(
      _uri('/sessions/$sessionId/leaderboard/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to load leaderboard: ${response.body}');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> joinSession({
    required String pin,
    required String phone,
    required String name,
    required bool consent,
  }) async {
    final response = await http.post(
      _uri('/sessions/join/'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'pin': pin,
        'phone': phone,
        'name': name,
        'consent': consent,
      }),
    );
    if (response.statusCode >= 400) {
      throw Exception('Failed to join session: ${response.body}');
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
      throw Exception('Failed to submit answer: ${response.body}');
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

class TeacherPanel extends StatefulWidget {
  const TeacherPanel({super.key});

  @override
  State<TeacherPanel> createState() => _TeacherPanelState();
}

class _TeacherPanelState extends State<TeacherPanel> {
  final _apiController = TextEditingController(text: 'http://localhost:8000/api');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailController = TextEditingController();
  final _signupCodeController = TextEditingController();
  final _quizTitleController = TextEditingController(text: 'Demo quiz');

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

  ApiClient _client({bool withToken = true}) {
    return ApiClient(
      _apiController.text.trim(),
      accessToken: withToken ? _accessToken : null,
    );
  }

  bool get _isLoggedIn => _accessToken != null && _accessToken!.isNotEmpty;

  @override
  void dispose() {
    _questionTimer?.cancel();
    _closeSessionSocket();
    _apiController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _emailController.dispose();
    _signupCodeController.dispose();
    _quizTitleController.dispose();
    super.dispose();
  }

  void _appendEvent(String text) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _events.insert(0, '[$timestamp] $text');
      if (_events.length > 25) {
        _events.removeRange(25, _events.length);
      }
    });
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
        setState(() {
          _revealPayload = payload;
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
      final me = await _client().getMe();
      setState(() {
        _teacher = me;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  Future<void> _refreshQuizzes() async {
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
      final quizzes = await _client().getQuizzes();
      setState(() {
        _quizzes = quizzes;
        if (_quizzes.isNotEmpty) {
          _selectedQuizId = _selectedQuizId ?? _quizzes.first['id'] as int;
        }
      });
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

  Future<void> _createDemoQuiz() async {
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
      await _client().createDemoQuiz(_quizTitleController.text.trim());
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

  Future<void> _createSession() async {
    if (!_isLoggedIn || _selectedQuizId == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final session = await _client().createSession(_selectedQuizId!);
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
      final started = await _client().startSession(_session!['id'] as int);
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
      final payload = await _client().nextQuestion(_session!['id'] as int);
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
      final payload = await _client().revealAnswer(_session!['id'] as int);
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
      final finished = await _client().finishSession(_session!['id'] as int);
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
      final rows = await _client().getLeaderboard(_session!['id'] as int);
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
              hintText: 'http://localhost:8000/api',
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
                  Text(
                    _isLoggedIn
                        ? 'Logged in${_teacher != null ? ': ${_teacher!['username']}' : ''}'
                        : 'Not authenticated',
                  ),
                  if (_refreshToken != null && _refreshToken!.isNotEmpty)
                    const Text('Refresh token is kept in memory for this app session.'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _quizTitleController,
            decoration: const InputDecoration(labelText: 'Quiz title'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton(
                onPressed: (_loading || !_isLoggedIn) ? null : _createDemoQuiz,
                child: const Text('Create demo quiz'),
              ),
              FilledButton.tonal(
                onPressed: (_loading || !_isLoggedIn) ? null : _refreshQuizzes,
                child: const Text('Refresh quizzes'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_quizzes.isNotEmpty)
                Expanded(
                  child: DropdownButton<int>(
                    value: _selectedQuizId,
                    isExpanded: true,
                    items: _quizzes
                        .map(
                          (q) => DropdownMenuItem<int>(
                            value: q['id'] as int,
                            child: Text('${q['id']}: ${q['title']}'),
                          ),
                        )
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
  final _apiController = TextEditingController(text: 'http://localhost:8000/api');
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

  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  bool _socketConnected = false;
  Timer? _countdownTimer;
  final List<String> _events = [];

  ApiClient _client() => ApiClient(_apiController.text.trim());

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
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _events.insert(0, '[$timestamp] $text');
      if (_events.length > 25) {
        _events.removeRange(25, _events.length);
      }
    });
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

        setState(() {
          _sessionStatus = payload['status']?.toString() ?? _sessionStatus;
          _sessionFinished = _sessionStatus == 'finished';
        });

        if (incomingQuestionId != activeQuestionId || incomingQuestion == null) {
          _applyQuestionState(incomingQuestion, payload['question_ends_at']);
        } else {
          _startCountdown(parseDateTimeLocal(payload['question_ends_at']));
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
      final payload = await _client().joinSession(
        pin: _pinController.text.trim(),
        phone: _phoneController.text.trim(),
        name: _nameController.text.trim(),
        consent: _consent,
      );

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
        _events.clear();
      });
      _startCountdown(parseDateTimeLocal(payload['question_ends_at']));

      await _connectSocket(payload['session_id'] as int);
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
          TextField(
            controller: _pinController,
            decoration: const InputDecoration(labelText: 'Session PIN'),
          ),
          const SizedBox(height: 12),
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
            title: const Text('I consent to personal data processing and privacy policy'),
            contentPadding: EdgeInsets.zero,
          ),
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



