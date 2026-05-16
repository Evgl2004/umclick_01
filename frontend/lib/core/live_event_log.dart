class LiveEventLog {
  const LiveEventLog({this.maxEntries = 25});

  final int maxEntries;

  void prepend(List<String> events, String message, {DateTime? now}) {
    events.insert(0, format(message, now: now));
    if (events.length > maxEntries) {
      events.removeRange(maxEntries, events.length);
    }
  }

  String format(String message, {DateTime? now}) {
    final timestamp =
        (now ?? DateTime.now()).toIso8601String().substring(11, 19);
    return '[$timestamp] $message';
  }
}
