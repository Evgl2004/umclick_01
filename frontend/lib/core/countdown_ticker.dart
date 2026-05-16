import 'dart:async';

import 'value_utils.dart';

class CountdownTick {
  const CountdownTick({
    required this.label,
    required this.isExpired,
  });

  final String label;
  final bool isExpired;
}

class CountdownTicker {
  const CountdownTicker({
    this.idleLabel = '--:--',
    this.expiredLabel = '00:00',
    this.interval = const Duration(seconds: 1),
  });

  final String idleLabel;
  final String expiredLabel;
  final Duration interval;

  Timer? restart({
    required Timer? currentTimer,
    required DateTime? endsAt,
    required void Function(CountdownTick tick) onTick,
    bool Function()? isActive,
  }) {
    currentTimer?.cancel();

    Timer? timer;
    var shouldScheduleTimer = true;

    void stopScheduling() {
      shouldScheduleTimer = false;
      timer?.cancel();
    }

    void notify(CountdownTick tick) {
      if (isActive?.call() == false) {
        stopScheduling();
        return;
      }
      onTick(tick);
    }

    if (endsAt == null) {
      notify(CountdownTick(label: idleLabel, isExpired: false));
      return null;
    }

    void tick() {
      final remaining = endsAt.difference(DateTime.now());
      if (remaining.inMilliseconds <= 0) {
        stopScheduling();
        notify(CountdownTick(label: expiredLabel, isExpired: true));
        return;
      }

      notify(CountdownTick(label: formatRemaining(remaining), isExpired: false));
    }

    tick();
    if (!shouldScheduleTimer) {
      return null;
    }

    timer = Timer.periodic(interval, (_) => tick());
    return timer;
  }
}
