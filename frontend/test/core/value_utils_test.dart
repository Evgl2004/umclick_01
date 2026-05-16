import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/core/value_utils.dart';

void main() {
  group('mapOrNull', () {
    test('returns typed maps unchanged', () {
      final source = <String, dynamic>{'answer': 42};

      expect(mapOrNull(source), same(source));
    });

    test('converts map keys to strings', () {
      expect(
        mapOrNull({1: 'one', 'two': 2}),
        equals({'1': 'one', 'two': 2}),
      );
    });

    test('returns null for non-map values', () {
      expect(mapOrNull('not a map'), isNull);
    });
  });

  group('asInt', () {
    test('keeps integers and parses strings', () {
      expect(asInt(12), 12);
      expect(asInt('34'), 34);
    });

    test('uses fallback for invalid values', () {
      expect(asInt('nope', -1), -1);
    });
  });

  group('parseDateTimeLocal', () {
    test('returns null for empty or non-string values', () {
      expect(parseDateTimeLocal(''), isNull);
      expect(parseDateTimeLocal(123), isNull);
    });

    test('parses ISO date strings', () {
      expect(parseDateTimeLocal('2026-05-16T07:08:09Z'), isA<DateTime>());
    });
  });

  group('formatRemaining', () {
    test('formats durations as mm:ss', () {
      expect(formatRemaining(const Duration(seconds: 65)), '01:05');
      expect(formatRemaining(const Duration(minutes: 10, seconds: 3)), '10:03');
    });
  });
}
