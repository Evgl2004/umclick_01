import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:umclick_frontend/api/api_client.dart';

void main() {
  const sessionUuid = '123e4567-e89b-42d3-a456-426614174000';

  group('ApiClient', () {
    test('uses 10 seconds for HTTP and 30 seconds for CSV by default', () {
      expect(ApiClient.defaultRequestTimeout, const Duration(seconds: 10));
      expect(ApiClient.defaultCsvTimeout, const Duration(seconds: 30));
    });

    test('times out and aborts regular HTTP while CSV uses its longer bound',
        () async {
      final transport = _DelayedClient(const Duration(milliseconds: 30));
      final client = ApiClient(
        'https://umclick.example/api',
        accessToken: 'account-token',
        httpClient: transport,
        requestTimeout: const Duration(milliseconds: 5),
        csvTimeout: const Duration(milliseconds: 100),
      );

      await expectLater(client.getMe(), throwsA(isA<TimeoutException>()));
      final timedOutRequest = transport.requests.single;
      expect(timedOutRequest, isA<http.AbortableRequest>());
      await (timedOutRequest as http.AbortableRequest).abortTrigger;

      expect(await client.exportSessionResultsCsv(sessionUuid), '{}');
      expect(transport.requests, hasLength(2));
    });

    test('builds websocket URL from http API URL', () {
      final client = ApiClient('http://localhost:8000/api');

      expect(
        client.sessionWebSocketUrl(sessionUuid),
        'ws://localhost:8000/ws/sessions/$sessionUuid/',
      );
    });

    test('builds secure websocket URL from https API URL', () {
      final client = ApiClient('https://umclick.example/api');

      expect(
        client.sessionWebSocketUrl(sessionUuid),
        'wss://umclick.example/ws/sessions/$sessionUuid/',
      );
    });

    test('builds local fallback websocket URL from relative API URL in tests',
        () {
      final client = ApiClient('/api');

      expect(
        client.sessionWebSocketUrl(sessionUuid),
        'ws://localhost:8000/ws/sessions/$sessionUuid/',
      );
    });

    test('rejects invalid session UUID before opening websocket', () {
      final client = ApiClient('https://umclick.example/api');

      expect(
        () => client.sessionWebSocketUrl('42'),
        throwsA(isA<FormatException>()),
      );
    });

    test('uses distinct role headers on UUID state routes', () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      });
      final client = ApiClient(
        'https://umclick.example/api',
        accessToken: 'account-token',
        httpClient: transport,
      );

      await client.getSessionState(sessionUuid);
      await client.getParticipationState(
        sessionUuid,
        participantToken: 'participant-token',
      );
      await client.getSessionDisplayState(
        sessionUuid,
        displayToken: 'display-token',
      );

      expect(requests.map((request) => request.url.path), [
        '/api/sessions/$sessionUuid/state/',
        '/api/sessions/$sessionUuid/participation/',
        '/api/sessions/$sessionUuid/display-state/',
      ]);
      expect(requests.map((request) => request.headers['Authorization']), [
        'Bearer account-token',
        'Participant participant-token',
        'Display display-token',
      ]);
    });

    test('submits answer on UUID route with Participant token and id',
        () async {
      late http.Request captured;
      final transport = MockClient((request) async {
        captured = request;
        return http.Response('{"accepted":true}', 200);
      });
      final client = ApiClient(
        'https://umclick.example/api',
        httpClient: transport,
      );

      await client.submitAnswer(
        sessionUuid: sessionUuid,
        participantToken: 'participant-token',
        questionId: 10,
        choiceId: 20,
        submissionId: '9ecbded8-1962-46a2-9861-b17f0464d3ac',
      );

      expect(captured.url.path, '/api/sessions/$sessionUuid/answer/');
      expect(
          captured.headers['Authorization'], 'Participant participant-token');
      expect(jsonDecode(captured.body), {
        'question_id': 10,
        'choice_id': 20,
        'submission_id': '9ecbded8-1962-46a2-9861-b17f0464d3ac',
      });
    });

    test('fetches newly created session details by public UUID', () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST') {
          return http.Response(
            '{"id":42,"join_token":"$sessionUuid"}',
            201,
          );
        }
        return http.Response('{"join_token":"$sessionUuid"}', 200);
      });
      final client = ApiClient(
        'https://umclick.example/api',
        accessToken: 'account-token',
        httpClient: transport,
      );

      await client.createSession(7);

      expect(requests.last.url.path, '/api/sessions/$sessionUuid/');
      expect(requests.last.headers['Authorization'], 'Bearer account-token');
    });

    test('использует фильтр архива и действия карточки без раскрытия версий',
        () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response('[]', 200);
        }
        if (request.method == 'DELETE') {
          return http.Response('', 204);
        }
        return http.Response(
          '{"id":7,"archived_at":null,"can_delete":true}',
          200,
        );
      });
      final client = ApiClient(
        'https://umclick.example/api',
        accessToken: 'account-token',
        httpClient: transport,
      );

      await client.getQuizzes();
      await client.getQuizzes(archived: true);
      await client.archiveQuiz(7);
      await client.restoreQuiz(7);
      await client.deleteQuiz(7);

      expect(requests.map((request) => request.method), [
        'GET',
        'GET',
        'POST',
        'POST',
        'DELETE',
      ]);
      expect(requests.map((request) => request.url.path), [
        '/api/quizzes/',
        '/api/quizzes/',
        '/api/quizzes/7/archive/',
        '/api/quizzes/7/restore/',
        '/api/quizzes/7/',
      ]);
      expect(requests[0].url.queryParameters, isEmpty);
      expect(requests[1].url.queryParameters, {'archived': 'true'});
      expect(requests[2].body, isEmpty);
      expect(requests[3].body, isEmpty);
      expect(
        requests.map((request) => request.headers['Authorization']).toSet(),
        {'Bearer account-token'},
      );
    });

    test('creates Display access on UUID route with Bearer token', () async {
      late http.Request captured;
      final transport = MockClient((request) async {
        captured = request;
        return http.Response(
          '{"id":"grant-id","display_token":"display-token"}',
          201,
        );
      });
      final client = ApiClient(
        'https://umclick.example/api',
        accessToken: 'account-token',
        httpClient: transport,
      );

      await client.createDisplayAccess(sessionUuid);

      expect(captured.url.path, '/api/sessions/$sessionUuid/display-access/');
      expect(captured.headers['Authorization'], 'Bearer account-token');
    });

    test('revokes the exact Display grant on UUID route with Bearer token',
        () async {
      const grantId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      late http.Request captured;
      final transport = MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      });
      final client = ApiClient(
        'https://umclick.example/api',
        accessToken: 'account-token',
        httpClient: transport,
      );

      await client.revokeDisplayAccess(sessionUuid, grantId);

      expect(captured.method, 'DELETE');
      expect(
        captured.url.path,
        '/api/sessions/$sessionUuid/display-access/$grantId/',
      );
      expect(captured.headers['Authorization'], 'Bearer account-token');
    });

    test('sends command context and id without changing them', () async {
      late http.Request captured;
      final transport = MockClient((request) async {
        captured = request;
        return http.Response(
          '{"schema_version":2,"session_id":"$sessionUuid",'
          '"state_revision":2,"status":"live","phase":"lobby",'
          '"question_run_id":null}',
          200,
        );
      });
      final client = ApiClient(
        'https://umclick.example/api',
        accessToken: 'account-token',
        httpClient: transport,
      );
      final command = {
        'command_id': '9ecbded8-1962-46a2-9861-b17f0464d3ac',
        'state_revision': 1,
        'phase': 'lobby',
        'question_run_id': null,
      };

      await client.startSession(sessionUuid, command: command);

      expect(captured.url.path, '/api/sessions/$sessionUuid/start/');
      expect(jsonDecode(captured.body), command);
    });

    test('parses structured access reason without treating every 401 alike',
        () async {
      final invalidClient = ApiClient(
        'https://umclick.example/api',
        httpClient: MockClient((_) async => http.Response(
              '{"code":"access_expired","retry_after":3}',
              401,
            )),
      );
      final genericClient = ApiClient(
        'https://umclick.example/api',
        httpClient: MockClient((_) async => http.Response(
              '{"detail":"route error"}',
              401,
            )),
      );

      await expectLater(
        invalidClient.getSessionDisplayState(
          sessionUuid,
          displayToken: 'display-token',
        ),
        throwsA(
          isA<ApiException>()
              .having((error) => error.code, 'code', 'access_expired')
              .having(
                (error) => error.invalidatesRoleAccess,
                'invalidatesRoleAccess',
                isTrue,
              ),
        ),
      );
      await expectLater(
        genericClient.getSessionDisplayState(
          sessionUuid,
          displayToken: 'display-token',
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.invalidatesRoleAccess,
            'invalidatesRoleAccess',
            isFalse,
          ),
        ),
      );
    });

    test('preserves Retry-After from a 503 response header', () async {
      final client = ApiClient(
        'https://umclick.example/api',
        accessToken: 'account-token',
        httpClient: MockClient((_) async => http.Response(
              '{"code":"limiter_unavailable"}',
              503,
              headers: {'retry-after': '3'},
            )),
      );

      await expectLater(
        client.getMe(),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having((error) => error.retryAfter, 'retryAfter', 3),
        ),
      );
    });
  });
}

class _DelayedClient extends http.BaseClient {
  _DelayedClient(this.delay);

  final Duration delay;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await Future<void>.delayed(delay);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{}')),
      200,
    );
  }
}
