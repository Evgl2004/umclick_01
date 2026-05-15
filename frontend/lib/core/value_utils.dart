Map<String, dynamic>? mapOrNull(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return null;
}

int asInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  return int.tryParse('$value') ?? fallback;
}

DateTime? parseDateTimeLocal(dynamic rawValue) {
  if (rawValue is! String || rawValue.isEmpty) return null;
  return DateTime.tryParse(rawValue)?.toLocal();
}

String formatRemaining(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
