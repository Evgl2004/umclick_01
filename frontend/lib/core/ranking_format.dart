import '../l10n/app_language.dart';

String formatRankingTimeMs(int milliseconds, {UiLanguage? language}) {
  final safeMilliseconds = milliseconds < 0 ? 0 : milliseconds;
  final seconds = safeMilliseconds ~/ 1000;
  final fraction = (safeMilliseconds % 1000).toString().padLeft(3, '0');
  final effectiveLanguage = language ?? appLanguage.value;
  final separator = effectiveLanguage == UiLanguage.ru ? ',' : '.';
  final unit = effectiveLanguage == UiLanguage.ru ? 'с' : 's';
  return '$seconds$separator$fraction $unit';
}
