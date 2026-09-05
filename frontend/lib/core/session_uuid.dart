String normalizeSessionUuid(String value) {
  final normalized = value.trim().toLowerCase();
  final pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  if (!pattern.hasMatch(normalized)) {
    throw const FormatException('Некорректный UUID сессии.');
  }
  return normalized;
}
