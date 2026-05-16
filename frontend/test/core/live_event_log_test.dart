import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/core/live_event_log.dart';

void main() {
  group('LiveEventLog', () {
    test('formats messages with a stable timestamp', () {
      const log = LiveEventLog();

      expect(
        log.format('participant joined', now: DateTime(2026, 5, 16, 7, 8, 9)),
        '[07:08:09] participant joined',
      );
    });

    test('prepends newest events and trims old entries', () {
      const log = LiveEventLog(maxEntries: 2);
      final events = <String>[];

      log.prepend(events, 'first', now: DateTime(2026, 5, 16, 7, 0, 0));
      log.prepend(events, 'second', now: DateTime(2026, 5, 16, 7, 0, 1));
      log.prepend(events, 'third', now: DateTime(2026, 5, 16, 7, 0, 2));

      expect(events, [
        '[07:00:02] third',
        '[07:00:01] second',
      ]);
    });
  });
}
