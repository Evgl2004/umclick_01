import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UiLanguage {
  ru,
  en,
}

class AppLanguageController extends ValueNotifier<UiLanguage> {
  AppLanguageController() : super(UiLanguage.ru);

  static const _storageKey = 'umclick_ui_language';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = _fromCode(prefs.getString(_storageKey));
  }

  Future<void> setLanguage(UiLanguage language) async {
    if (language == value) return;
    value = language;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, language.name);
  }

  UiLanguage _fromCode(String? code) {
    return UiLanguage.values.firstWhere(
      (language) => language.name == code,
      orElse: () => UiLanguage.ru,
    );
  }
}

final AppLanguageController appLanguage = AppLanguageController();

String uiText({required String ru, required String en}) {
  return appLanguage.value == UiLanguage.ru ? ru : en;
}

class LanguageSwitcher extends StatelessWidget {
  const LanguageSwitcher({super.key});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<UiLanguage>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: UiLanguage.ru, label: Text('RU')),
        ButtonSegment(value: UiLanguage.en, label: Text('EN')),
      ],
      selected: {appLanguage.value},
      onSelectionChanged: (selection) {
        appLanguage.setLanguage(selection.first);
      },
    );
  }
}
