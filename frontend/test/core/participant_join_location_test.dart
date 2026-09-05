import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/core/participant_join_location.dart';

void main() {
  const uuid = '123e4567-e89b-42d3-a456-426614174000';

  test('builds a canonical public join URL without PIN or secrets', () {
    final result = canonicalParticipantJoinUri(
      Uri.parse('https://quiz.example/?pin=123456&api=https://bad.example#x'),
      uuid,
    );

    expect(result.toString(), 'https://quiz.example/join?token=$uuid');
    expect(result.queryParameters.keys, ['token']);
  });

  test('rejects a non-UUID session identifier', () {
    expect(
      () =>
          canonicalParticipantJoinUri(Uri.parse('https://quiz.example/'), '42'),
      throwsA(isA<FormatException>()),
    );
  });
}
