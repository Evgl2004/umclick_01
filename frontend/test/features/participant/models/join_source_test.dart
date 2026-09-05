import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/features/participant/models/join_source.dart';

void main() {
  group('ParticipantJoinSource', () {
    test('extracts and trims join parameters from URI', () {
      final source = ParticipantJoinSource.fromUri(
        Uri(
          path: '/join',
          queryParameters: {
            'api': ' http://localhost:8000/api ',
            'token': ' token-123 ',
            'pin': ' 123456 ',
          },
        ),
      );

      expect(source.joinToken, 'token-123');
      expect(source.pin, '123456');
      expect(source.hasJoinTarget, isTrue);
      expect(source.shouldUseJoinToken, isTrue);
    });

    test('treats blank query values as missing', () {
      final source = ParticipantJoinSource.fromUri(
        Uri(
          path: '/join',
          queryParameters: {
            'api': ' ',
            'token': '',
            'pin': ' ',
          },
        ),
      );

      expect(source.joinToken, isNull);
      expect(source.pin, isNull);
      expect(source.hasJoinTarget, isFalse);
      expect(source.shouldUseJoinToken, isFalse);
    });
  });
}
