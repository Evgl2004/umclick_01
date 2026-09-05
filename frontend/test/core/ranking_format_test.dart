import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/core/ranking_format.dart';
import 'package:umclick_frontend/l10n/app_language.dart';

void main() {
  test('ranking time keeps all three millisecond digits', () {
    expect(
      formatRankingTimeMs(40234, language: UiLanguage.ru),
      '40,234 с',
    );
    expect(
      formatRankingTimeMs(40432, language: UiLanguage.ru),
      '40,432 с',
    );
    expect(
      formatRankingTimeMs(40234, language: UiLanguage.en),
      '40.234 s',
    );
  });

  test('ranking time is never rendered as a negative duration', () {
    expect(formatRankingTimeMs(-1, language: UiLanguage.ru), '0,000 с');
  });
}
