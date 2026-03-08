import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

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
      appBar: AppBar(
        title: const Text('umclick MVP'),
      ),
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
  ApiClient(this.baseUrl);

  String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<List<dynamic>> getQuizzes() async {
    final response = await http.get(_uri('/quizzes/'));
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
      headers: {'Content-Type': 'application/json'},
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
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'quiz': quizId, 'host_name': 'Teacher'}),
    );

    if (response.statusCode >= 400) {
      throw Exception('Failed to create session: ${response.body}');
    }

    final created = jsonDecode(response.body) as Map<String, dynamic>;
    final details = await http.get(_uri('/sessions/${created['id']}/'));
    if (details.statusCode >= 400) {
      throw Exception('Failed to fetch session details: ${details.body}');
    }
    return jsonDecode(details.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> startSession(int sessionId) async {
    final response = await http.post(_uri('/sessions/$sessionId/start/'));
    if (response.statusCode >= 400) {
      throw Exception('Failed to start session: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> finishSession(int sessionId) async {
    final response = await http.post(_uri('/sessions/$sessionId/finish/'));
    if (response.statusCode >= 400) {
      throw Exception('Failed to finish session: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> joinSession({
    required String pin,
    required String phone,
    required String name,
    required bool consent,
  }) async {
    final response = await http.post(
      _uri('/sessions/join/'),
      headers: {'Content-Type': 'application/json'},
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
      headers: {'Content-Type': 'application/json'},
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

class TeacherPanel extends StatefulWidget {
  const TeacherPanel({super.key});

  @override
  State<TeacherPanel> createState() => _TeacherPanelState();
}

class _TeacherPanelState extends State<TeacherPanel> {
  final _apiController = TextEditingController(text: 'http://localhost:8000/api');
  final _quizTitleController = TextEditingController(text: 'Demo quiz');

  late ApiClient _api;
  List<dynamic> _quizzes = [];
  int? _selectedQuizId;
  Map<String, dynamic>? _session;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(_apiController.text);
    _refreshQuizzes();
  }

  @override
  void dispose() {
    _apiController.dispose();
    _quizTitleController.dispose();
    super.dispose();
  }

  Future<void> _refreshQuizzes() async {
    setState(() {
      _loading = true;
      _error = null;
      _api = ApiClient(_apiController.text);
    });

    try {
      final quizzes = await _api.getQuizzes();
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
    setState(() {
      _loading = true;
      _error = null;
      _api = ApiClient(_apiController.text);
    });

    try {
      await _api.createDemoQuiz(_quizTitleController.text.trim());
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
    if (_selectedQuizId == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _api = ApiClient(_apiController.text);
    });

    try {
      final session = await _api.createSession(_selectedQuizId!);
      setState(() {
        _session = session;
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

  Future<void> _startSession() async {
    if (_session == null) return;
    final started = await _api.startSession(_session!['id'] as int);
    setState(() {
      _session = started;
    });
  }

  Future<void> _finishSession() async {
    if (_session == null) return;
    final finished = await _api.finishSession(_session!['id'] as int);
    setState(() {
      _session = finished;
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _quizTitleController,
                  decoration: const InputDecoration(labelText: 'Quiz title'),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _loading ? null : _createDemoQuiz,
                child: const Text('Create demo quiz'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _loading ? null : _refreshQuizzes,
                child: const Text('Refresh quizzes'),
              ),
              const SizedBox(width: 12),
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
                ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: (_loading || _selectedQuizId == null) ? null : _createSession,
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
                      children: [
                        FilledButton(
                          onPressed: _startSession,
                          child: const Text('Start'),
                        ),
                        FilledButton.tonal(
                          onPressed: _finishSession,
                          child: const Text('Finish'),
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
  int _questionIndex = 0;
  bool _consent = false;
  bool _loading = false;
  int _score = 0;
  String? _error;

  List<dynamic> get _questions {
    if (_joinPayload == null) return [];
    final list = (_joinPayload!['quiz']['questions'] as List<dynamic>).toList();
    list.sort((a, b) => (a['order'] as int).compareTo(b['order'] as int));
    return list;
  }

  Future<void> _join() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = ApiClient(_apiController.text);
      final payload = await api.joinSession(
        pin: _pinController.text.trim(),
        phone: _phoneController.text.trim(),
        name: _nameController.text.trim(),
        consent: _consent,
      );

      setState(() {
        _joinPayload = payload;
        _questionIndex = 0;
        _score = 0;
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

  Future<void> _answer(int choiceId) async {
    final question = _questions[_questionIndex] as Map<String, dynamic>;
    final api = ApiClient(_apiController.text);

    try {
      final response = await api.submitAnswer(
        sessionParticipantId: _joinPayload!['session_participant_id'] as int,
        questionId: question['id'] as int,
        choiceId: choiceId,
      );

      setState(() {
        _score = response['score'] as int;
        _questionIndex += 1;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _apiController.dispose();
    _pinController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
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
            Text('Score: $_score', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (_questionIndex < _questions.length)
              _QuestionCard(
                question: _questions[_questionIndex] as Map<String, dynamic>,
                onAnswer: _answer,
              )
            else
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Quiz completed. Great job!'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.question, required this.onAnswer});

  final Map<String, dynamic> question;
  final ValueChanged<int> onAnswer;

  @override
  Widget build(BuildContext context) {
    final choices = (question['choices'] as List<dynamic>).toList()
      ..sort((a, b) => (a['order'] as int).compareTo(b['order'] as int));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question['text'] as String, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ...choices.map(
              (choice) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => onAnswer(choice['id'] as int),
                    child: Text(choice['text'] as String),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
