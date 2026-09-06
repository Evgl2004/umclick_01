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
    expect(
      userErrorText(
        const FormatException(
          'Reading time must be between 3 and 120 seconds.',
        ),
      ),
      'Время на зачитывание вопроса должно быть от 3 до 120 секунд.',
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
    expect(
      userErrorText(ApiException(
        statusCode: 400,
        message: 'Failed to load display state',
        body: '{}',
      )),
      'Не удалось загрузить экран демонстрации.',
    );
  });

  test('explains revision conflict without discarding the editor form', () {
    expect(
      userErrorText(ApiException(
        statusCode: 409,
        message: 'Failed to update quiz',
        body: '{"code":"quiz_revision_conflict"}',
        code: 'quiz_revision_conflict',
      )),
      'Викторина уже изменена. Обновите список осознанно; текущая форма сохранена.',
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
    expect(
      userErrorText(ApiException(
        statusCode: 400,
        message: 'Failed to join session',
        body: '{"non_field_errors":["Session is already finished."]}',
      )),
      'Сессия уже завершена.',
    );
  });
}
