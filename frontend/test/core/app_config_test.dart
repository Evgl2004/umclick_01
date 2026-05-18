import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/core/app_config.dart';

void main() {
  group('resolveDefaultApiBaseUrl', () {
    test('uses local backend for Flutter localhost dev server', () {
      expect(
        resolveDefaultApiBaseUrl(Uri.parse('http://localhost:3000')),
        localDevApiBaseUrl,
      );
      expect(
        resolveDefaultApiBaseUrl(Uri.parse('http://127.0.0.1:3000')),
        localDevApiBaseUrl,
      );
    });

    test('uses same-origin API for deployed web origin', () {
      expect(
        resolveDefaultApiBaseUrl(Uri.parse('http://203.0.113.10')),
        sameOriginApiBaseUrl,
      );
      expect(
        resolveDefaultApiBaseUrl(Uri.parse('https://umclick.example')),
        sameOriginApiBaseUrl,
      );
    });

    test('falls back to local backend outside browser http origins', () {
      expect(
        resolveDefaultApiBaseUrl(Uri.parse('file:///C:/umclick/index.html')),
        localDevApiBaseUrl,
      );
    });
  });
}
