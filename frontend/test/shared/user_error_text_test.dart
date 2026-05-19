import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/api/api_client.dart';
import 'package:umclick_frontend/l10n/app_language.dart';
import 'package:umclick_frontend/l10n/app_strings.dart';
import 'package:umclick_frontend/shared/user_error_text.dart';

void main() {
  setUp(() {
    appLanguage.value = UiLanguage.ru;
  });

  test('localizes quiz validation messages', () {
    expect(
      userErrorText(const FormatException('Quiz title is required.')),
      'Укажите название викторины.',
    );
    expect(
      userErrorText(
        const FormatException('Question 2 text is required.'),
      ),
      'Заполните текст вопроса 2.',
    );
  });

  test('localizes known API messages', () {
    expect(
      userErrorText(ApiException(
        statusCode: 400,
        message: 'Failed to create session',
        body: '{}',
      )),
      'Не удалось создать live-сессию.',
    );
  });

  test('localizes participant join validation details', () {
    expect(
      userErrorText(ApiException(
        statusCode: 400,
        message: 'Failed to join session',
        body: '{"phone":["This field may not be blank."]}',
      )),
      appText(AppText.participantPhoneRequiredError),
    );
    expect(
      userErrorText(ApiException(
        statusCode: 400,
        message: 'Failed to join session',
        body: '{"name":["This field may not be blank."]}',
      )),
      appText(AppText.participantNameRequiredError),
    );
    expect(
      userErrorText(ApiException(
        statusCode: 400,
        message: 'Failed to join session',
        body: '{"consent":["This field is required."]}',
      )),
      appText(AppText.participantConsentRequiredError),
    );
  });
}
