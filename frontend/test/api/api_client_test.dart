import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/api/api_client.dart';

void main() {
  group('ApiClient', () {
    test('builds websocket URL from http API URL', () {
      final client = ApiClient('http://localhost:8000/api');

      expect(
        client.sessionWebSocketUrl(42),
        'ws://localhost:8000/ws/sessions/42/',
      );
    });

    test('builds secure websocket URL from https API URL', () {
      final client = ApiClient('https://umclick.example/api');

      expect(
        client.sessionWebSocketUrl(7),
        'wss://umclick.example/ws/sessions/7/',
      );
    });

    test('builds local fallback websocket URL from relative API URL in tests',
        () {
      final client = ApiClient('/api');

      expect(
        client.sessionWebSocketUrl(7),
        'ws://localhost:8000/ws/sessions/7/',
      );
    });
  });
}
