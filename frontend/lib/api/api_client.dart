import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/session_uuid.dart';

class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.message,
    required this.body,
    this.code,
    this.retryAfter,
    this.state,
  });

  final int statusCode;
  final String message;
  final String body;
  final String? code;
  final int? retryAfter;
  final Map<String, dynamic>? state;

  bool get invalidatesRoleAccess =>
      code == 'access_invalid' ||
      code == 'access_revoked' ||
      code == 'access_expired';

  @override
  String toString() => '$message (status $statusCode): $body';
}

class ApiClient {
  ApiClient(
    this.baseUrl, {
    this.accessToken,
    http.Client? httpClient,
    Duration requestTimeout = defaultRequestTimeout,
    Duration csvTimeout = defaultCsvTimeout,
  })  : _httpClient = httpClient,
        _requestTimeout = requestTimeout,
        _csvTimeout = csvTimeout;

  static const defaultRequestTimeout = Duration(seconds: 10);
  static const defaultCsvTimeout = Duration(seconds: 30);

  final String baseUrl;
  final String? accessToken;
  final http.Client? _httpClient;
  final Duration _requestTimeout;
  final Duration _csvTimeout;

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

  Map<String, String> _headers({
    bool jsonBody = false,
    bool auth = false,
    String? participantToken,
    String? displayToken,
  }) {
    assert(!(auth && (participantToken != null || displayToken != null)));
    assert(participantToken == null || displayToken == null);
    final headers = <String, String>{};
    if (jsonBody) {
      headers['Content-Type'] = 'application/json';
    }
    if (auth && accessToken != null && accessToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    } else if (participantToken != null && participantToken.isNotEmpty) {
      headers['Authorization'] = 'Participant $participantToken';
    } else if (displayToken != null && displayToken.isNotEmpty) {
      headers['Authorization'] = 'Display $displayToken';
    }
    return headers;
  }

  Future<http.Response> _get(
    Uri uri, {
    Map<String, String>? headers,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) {
    return _request(
      'GET',
      uri,
      headers: headers,
      abortTrigger: abortTrigger,
      timeout: timeout,
    );
  }

  Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) {
    return _request(
      'POST',
      uri,
      headers: headers,
      body: body,
      abortTrigger: abortTrigger,
      timeout: timeout,
    );
  }

  Future<http.Response> _put(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) {
    return _request(
      'PUT',
      uri,
      headers: headers,
      body: body,
      abortTrigger: abortTrigger,
      timeout: timeout,
    );
  }

  Future<http.Response> _delete(
    Uri uri, {
    Map<String, String>? headers,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) {
    return _request(
      'DELETE',
      uri,
      headers: headers,
      abortTrigger: abortTrigger,
      timeout: timeout,
    );
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? _requestTimeout;
    final timeoutSignal = Completer<void>();
    final timeoutTimer = Timer(effectiveTimeout, timeoutSignal.complete);
    final abortSignals = <Future<void>>[timeoutSignal.future];
    if (abortTrigger != null) abortSignals.add(abortTrigger);
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: Future.any<void>(abortSignals),
    );
    if (headers != null) request.headers.addAll(headers);
    if (body is String) {
      request.body = body;
    } else if (body is List<int>) {
      request.bodyBytes = body;
    } else if (body is Map<String, String>) {
      request.bodyFields = body;
    } else if (body != null) {
      throw ArgumentError.value(
          body, 'body', 'Неподдерживаемый тип тела HTTP.');
    }

    final client = _httpClient ?? http.Client();
    Future<T> bounded<T>(Future<T> operation) {
      final candidates = <Future<T>>[
        operation,
        timeoutSignal.future.then<T>(
          (_) => throw TimeoutException(
            'Превышено время ожидания HTTP-запроса.',
            effectiveTimeout,
          ),
        ),
      ];
      if (abortTrigger != null) {
        candidates.add(
          abortTrigger.then<T>(
            (_) => throw http.RequestAbortedException(uri),
          ),
        );
      }
      return Future.any<T>(candidates);
    }

    try {
      final streamed = await bounded(client.send(request));
      return await bounded(http.Response.fromStream(streamed));
    } finally {
      timeoutTimer.cancel();
      if (_httpClient == null) client.close();
    }
  }

  Never _throwError(http.Response response, String message) {
    Map<String, dynamic>? payload;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        payload = decoded;
      }
    } on FormatException {
      payload = null;
    }
    throw ApiException(
      statusCode: response.statusCode,
      message: message,
      body: response.body,
      code: payload?['code']?.toString(),
      retryAfter: _asPositiveInt(payload?['retry_after']) ??
          _asPositiveInt(response.headers['retry-after']),
      state: payload?['state'] is Map<String, dynamic>
          ? payload!['state'] as Map<String, dynamic>
          : null,
    );
  }

  int? _asPositiveInt(Object? value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  String sessionWebSocketUrl(String sessionUuid) {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final apiUri = _resolveBaseUri();
    final scheme = apiUri.scheme == 'https' ? 'wss' : 'ws';
    final portPart = apiUri.hasPort ? ':${apiUri.port}' : '';
    return '$scheme://${apiUri.host}$portPart/ws/sessions/$normalizedUuid/';
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

    final response = await _post(
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
    final response = await _post(
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
    final response = await _post(
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
    final response = await _get(
      _uri('/auth/me/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to get profile');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getQuizzes() async {
    final response = await _get(
      _uri('/quizzes/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load quizzes');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> createQuiz(Map<String, dynamic> payload) async {
    final response = await _post(
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
    final response = await _put(
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
    final response = await _delete(
      _uri('/quizzes/$quizId/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to delete quiz');
    }
  }

  Future<Map<String, dynamic>> createSession(int quizId) async {
    final response = await _post(
      _uri('/sessions/'),
      headers: _headers(jsonBody: true, auth: true),
      body: jsonEncode({'quiz': quizId, 'host_name': 'Teacher'}),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to create session');
    }

    final created = jsonDecode(response.body) as Map<String, dynamic>;
    final details = await _get(
      _uri('/sessions/${created['join_token']}/'),
      headers: _headers(auth: true),
    );
    if (details.statusCode >= 400) {
      _throwError(details, 'Failed to fetch session details');
    }
    return jsonDecode(details.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getSessions() async {
    final response = await _get(
      _uri('/sessions/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load sessions');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> getSessionDisplayState(
    String sessionUuid, {
    required String displayToken,
  }) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final response = await _get(
      _uri('/sessions/$normalizedUuid/display-state/'),
      headers: _headers(displayToken: displayToken),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load display state');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSessionState(String sessionUuid) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final response = await _get(
      _uri('/sessions/$normalizedUuid/state/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load session state');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getParticipationState(
    String sessionUuid, {
    required String participantToken,
  }) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final response = await _get(
      _uri('/sessions/$normalizedUuid/participation/'),
      headers: _headers(participantToken: participantToken),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Не удалось загрузить состояние участия');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> startSession(
    String sessionUuid, {
    required Map<String, dynamic> command,
    Future<void>? abortTrigger,
  }) {
    return _sessionCommand(
      sessionUuid,
      'start',
      command,
      abortTrigger: abortTrigger,
    );
  }

  Future<Map<String, dynamic>> startQuiz(
    String sessionUuid, {
    required Map<String, dynamic> command,
    Future<void>? abortTrigger,
  }) {
    return _sessionCommand(
      sessionUuid,
      'start-quiz',
      command,
      abortTrigger: abortTrigger,
    );
  }

  Future<Map<String, dynamic>> finishSession(
    String sessionUuid, {
    required Map<String, dynamic> command,
    Future<void>? abortTrigger,
  }) {
    return _sessionCommand(
      sessionUuid,
      'finish',
      command,
      abortTrigger: abortTrigger,
    );
  }

  Future<Map<String, dynamic>> nextQuestion(
    String sessionUuid, {
    required Map<String, dynamic> command,
    Future<void>? abortTrigger,
  }) {
    return _sessionCommand(
      sessionUuid,
      'next-question',
      command,
      abortTrigger: abortTrigger,
    );
  }

  Future<Map<String, dynamic>> endQuestion(
    String sessionUuid, {
    required Map<String, dynamic> command,
    Future<void>? abortTrigger,
  }) {
    return _sessionCommand(
      sessionUuid,
      'end-question',
      command,
      abortTrigger: abortTrigger,
    );
  }

  Future<Map<String, dynamic>> _sessionCommand(
    String sessionUuid,
    String action,
    Map<String, dynamic> command, {
    Future<void>? abortTrigger,
  }) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final response = await _post(
      _uri('/sessions/$normalizedUuid/$action/'),
      headers: _headers(jsonBody: true, auth: true),
      body: jsonEncode(command),
      abortTrigger: abortTrigger,
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Не удалось выполнить управляющую команду');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getLeaderboard(String sessionUuid) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final response = await _get(
      _uri('/sessions/$normalizedUuid/leaderboard/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to load leaderboard');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<String> exportSessionResultsCsv(String sessionUuid) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final response = await _get(
      _uri('/sessions/$normalizedUuid/results/export/'),
      headers: _headers(auth: true),
      timeout: _csvTimeout,
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to export session results');
    }
    return utf8.decode(response.bodyBytes);
  }

  Future<Map<String, dynamic>> getCurrentLegalDocuments() async {
    final response = await _get(
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
      queryParameters['join_token'] = normalizedJoinToken;
    }

    final response = await _get(
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
    String? participantToken,
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

    final response = await _post(
      _uri('/sessions/join/'),
      headers: _headers(
        jsonBody: true,
        participantToken: participantToken,
      ),
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to join session');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> submitAnswer({
    required String sessionUuid,
    required String participantToken,
    required int questionId,
    required int choiceId,
    required String submissionId,
    Future<void>? abortTrigger,
  }) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final response = await _post(
      _uri('/sessions/$normalizedUuid/answer/'),
      headers: _headers(
        jsonBody: true,
        participantToken: participantToken,
      ),
      body: jsonEncode({
        'question_id': questionId,
        'choice_id': choiceId,
        'submission_id': submissionId,
      }),
      abortTrigger: abortTrigger,
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Failed to submit answer');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createDisplayAccess(String sessionUuid) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final response = await _post(
      _uri('/sessions/$normalizedUuid/display-access/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Не удалось выдать доступ к показу');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> revokeDisplayAccess(
    String sessionUuid,
    String grantId,
  ) async {
    final normalizedUuid = normalizeSessionUuid(sessionUuid);
    final normalizedGrantId = normalizeSessionUuid(grantId);
    final response = await _delete(
      _uri('/sessions/$normalizedUuid/display-access/$normalizedGrantId/'),
      headers: _headers(auth: true),
    );
    if (response.statusCode >= 400) {
      _throwError(response, 'Не удалось отозвать доступ к показу');
    }
  }
}
