import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:umclick_frontend/l10n/app_language.dart';

void main() {
  group('AppLanguageController', () {
    test('loads Russian by default', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = AppLanguageController();
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.value, UiLanguage.ru);
    });

    test('loads saved language from preferences', () async {
      SharedPreferences.setMockInitialValues({
        'umclick_ui_language': 'en',
      });
      final controller = AppLanguageController();
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.value, UiLanguage.en);
    });

    test('persists language changes', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = AppLanguageController();
      addTearDown(controller.dispose);

      await controller.setLanguage(UiLanguage.en);
      final prefs = await SharedPreferences.getInstance();

      expect(controller.value, UiLanguage.en);
      expect(prefs.getString('umclick_ui_language'), 'en');
    });
  });

  group('uiText', () {
    test('uses the current global language', () {
      final previousLanguage = appLanguage.value;
      addTearDown(() {
        appLanguage.value = previousLanguage;
      });

      appLanguage.value = UiLanguage.ru;
      expect(uiText(ru: 'ru text', en: 'en text'), 'ru text');

      appLanguage.value = UiLanguage.en;
      expect(uiText(ru: 'ru text', en: 'en text'), 'en text');
    });
  });
}
