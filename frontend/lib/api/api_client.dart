import 'dart:convert';

import 'package:http/http.dart' as http;

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

  Uri _resolveBaseUri() {
    final trimmedBaseUrl = baseUrl.trim();
    if (trimmedBaseUrl.startsWith('http://') ||
        trimmedBaseUrl.startsWith('https://')) {
      return Uri.parse(trimmedBaseUrl);
    }

    final currentUri = Uri.base;
    final normalizedRelativeBase =
        trimmedBaseUrl.startsWith('/') ? trimmedBaseUrl : '/$trimmedBaseUrl';
    if ((currentUri.scheme == 'http' || currentUri.scheme == 'https') &&
        currentUri.host.isNotEmpty) {
      return currentUri.resolve(normalizedRelativeBase);
    }

    return Uri.parse('http://localhost:8000$normalizedRelativeBase');
  }

  Uri _uri(String path) {
    final base = _resolveBaseUri().toString().replaceFirst(RegExp(r'/*$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$normalizedPath');
  }

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
    final apiUri = _resolveBaseUri();
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
      if (signupCode != null && signupCode.isNotEmpty)
        'signup_code': signupCode,
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

  Future<Map<String, dynamic>> updateQuiz(
      int quizId, Map<String, dynamic> payload) async {
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

  Future<List<dynamic>> getSessions() async {
    final response = await http.get(
      _uri('/sessions/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load sessions');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> getSessionDisplayState(int sessionId) async {
    final response = await http.get(
      _uri('/sessions/$sessionId/display-state/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load display state');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSessionState(int sessionId) async {
    final response = await http.get(
      _uri('/sessions/$sessionId/state/'),
      headers: _headers(),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load session state');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
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

  Future<String> exportSessionResultsCsv(int sessionId) async {
    final response = await http.get(
      _uri('/sessions/$sessionId/results/export/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to export session results');
    }
    return utf8.decode(response.bodyBytes);
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
