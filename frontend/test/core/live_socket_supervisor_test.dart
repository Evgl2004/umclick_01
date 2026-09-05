import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/core/live_socket_supervisor.dart';

void main() {
  late List<Duration> waits;
  late List<_FakeSocket> sockets;
  late List<String?> stoppedReasons;

  LiveSocketSupervisor supervisor() {
    return LiveSocketSupervisor(
      url: 'ws://localhost/ws/sessions/uuid/',
      authentication: const {
        'event': 'auth',
        'access_type': 'participant',
        'token': 'secret',
      },
      onMessage: (_) {},
      onConnectionError: (_) {},
      onInvalidPayload: () {},
      onTransportError: (_) {},
      onStopped: (_, reason) => stoppedReasons.add(reason),
      opener: ({
        required authentication,
        required onMessage,
        required onError,
        required onDone,
        required onInvalidPayload,
      }) {
        final socket = _FakeSocket(
          authentication: authentication,
          onMessage: onMessage,
          onDone: onDone,
        );
        sockets.add(socket);
        return socket;
      },
      delay: (duration) async => waits.add(duration),
      jitter: (seconds) => seconds,
    );
  }

  setUp(() {
    waits = [];
    sockets = [];
    stoppedReasons = [];
  });

  test('4429 retries no more than three times using retry_after', () async {
    final manager = supervisor();
    await manager.start();
    for (var i = 0; i < 4; i++) {
      sockets.last.message({
        'event': 'connection_error',
        'payload': {'code': 'rate_limited', 'retry_after': i + 1},
      });
      sockets.last.done(4429, 'rate_limited');
      await Future<void>.delayed(Duration.zero);
    }

    expect(sockets, hasLength(4));
    expect(waits.map((value) => value.inSeconds), [1, 2, 3]);
    expect(stoppedReasons, ['rate_limited']);
  });

  test('4503 retries at 3, 6, 12 seconds', () async {
    final manager = supervisor();
    await manager.start();
    for (var i = 0; i < 4; i++) {
      sockets.last.message({
        'event': 'connection_error',
        'payload': {'code': 'limiter_unavailable', 'retry_after': 3},
      });
      sockets.last.done(4503, 'limiter_unavailable');
      await Future<void>.delayed(Duration.zero);
    }

    expect(waits.map((value) => value.inSeconds), [3, 6, 12]);
    expect(stoppedReasons, ['limiter_unavailable']);
  });

  test('network and 1012 use bounded 1, 2, 4, 8, 16, 30 backoff', () async {
    final manager = supervisor();
    await manager.start();
    for (var i = 0; i < 7; i++) {
      sockets.last.done(1012, 'restart');
      await Future<void>.delayed(Duration.zero);
    }

    expect(waits.map((value) => value.inSeconds), [1, 2, 4, 8, 16, 30]);
    expect(sockets, hasLength(7));
    expect(stoppedReasons, ['restart']);
  });

  test('terminal protocol and access closures do not reconnect', () async {
    for (final code in [4000, 4001, 4003, 1009, 1000]) {
      final manager = supervisor();
      await manager.start();
      final opened = sockets.length;
      sockets.last.done(code, 'terminal');
      await Future<void>.delayed(Duration.zero);
      expect(sockets.length, opened);
    }
    expect(waits, isEmpty);
  });

  test('reads the exact top-level server connection_error contract', () async {
    final errors = <Map<String, dynamic>>[];
    final manager = LiveSocketSupervisor(
      url: 'ws://localhost/ws/sessions/uuid/',
      authentication: const {
        'event': 'auth',
        'access_type': 'display',
        'token': 'secret',
      },
      onMessage: (_) {},
      onConnectionError: errors.add,
      onInvalidPayload: () {},
      onTransportError: (_) {},
      onStopped: (_, __) {},
      opener: ({
        required authentication,
        required onMessage,
        required onError,
        required onDone,
        required onInvalidPayload,
      }) {
        final socket = _FakeSocket(
          authentication: authentication,
          onMessage: onMessage,
          onDone: onDone,
        );
        sockets.add(socket);
        return socket;
      },
      delay: (duration) async => waits.add(duration),
      jitter: (seconds) => seconds,
    );

    await manager.start();
    sockets.single.message({
      'event': 'connection_error',
      'code': 'access_expired',
      'message': 'Срок доступа истёк.',
    });
    sockets.single.done(4003, 'access_expired');
    await Future<void>.delayed(Duration.zero);

    expect(errors.single['code'], 'access_expired');
    expect(sockets, hasLength(1));
    expect(waits, isEmpty);
  });

  test('access_expired replaces authentication and opens a new socket',
      () async {
    final recovery = Completer<Map<String, dynamic>?>();
    final manager = LiveSocketSupervisor(
      url: 'ws://localhost/ws/sessions/uuid/',
      authentication: const {
        'event': 'auth',
        'access_type': 'account',
        'token': 'old-access',
      },
      onMessage: (_) {},
      onConnectionError: (_) {},
      onInvalidPayload: () {},
      onTransportError: (_) {},
      onStopped: (_, reason) => stoppedReasons.add(reason),
      recoverAuthentication: (used) {
        expect(used['token'], 'old-access');
        return recovery.future;
      },
      opener: ({
        required authentication,
        required onMessage,
        required onError,
        required onDone,
        required onInvalidPayload,
      }) {
        final socket = _FakeSocket(
          authentication: authentication,
          onMessage: onMessage,
          onDone: onDone,
        );
        sockets.add(socket);
        return socket;
      },
      delay: (duration) async => waits.add(duration),
      jitter: (seconds) => seconds,
    );

    await manager.start();
    sockets.single.message({
      'event': 'connection_error',
      'code': 'access_expired',
    });
    sockets.single.done(4003, 'access_expired');
    await Future<void>.delayed(Duration.zero);
    recovery.complete({
      'event': 'auth',
      'access_type': 'account',
      'token': 'new-access',
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(sockets, hasLength(2));
    expect(sockets.last.authentication['token'], 'new-access');
    expect(stoppedReasons, isEmpty);
  });

  test('stop during access refresh prevents a late socket reopen', () async {
    final recovery = Completer<Map<String, dynamic>?>();
    final manager = LiveSocketSupervisor(
      url: 'ws://localhost/ws/sessions/uuid/',
      authentication: const {
        'event': 'auth',
        'access_type': 'account',
        'token': 'old-access',
      },
      onMessage: (_) {},
      onConnectionError: (_) {},
      onInvalidPayload: () {},
      onTransportError: (_) {},
      onStopped: (_, __) {},
      recoverAuthentication: (_) => recovery.future,
      opener: ({
        required authentication,
        required onMessage,
        required onError,
        required onDone,
        required onInvalidPayload,
      }) {
        final socket = _FakeSocket(
          authentication: authentication,
          onMessage: onMessage,
          onDone: onDone,
        );
        sockets.add(socket);
        return socket;
      },
    );

    await manager.start();
    sockets.single.message({
      'event': 'connection_error',
      'code': 'access_expired',
    });
    sockets.single.done(4003, 'access_expired');
    await Future<void>.delayed(Duration.zero);
    await manager.stop();
    recovery.complete({
      'event': 'auth',
      'access_type': 'account',
      'token': 'new-access',
    });
    await Future<void>.delayed(Duration.zero);

    expect(sockets, hasLength(1));
  });

  test('single-flight refresh handles both failure orders and late old 401s',
      () async {
    final coordinator = SingleFlightTokenRefresh();
    final refreshGate = Completer<void>();
    var currentToken = 'old-access';
    var refreshes = 0;

    Future<bool> refresh() async {
      refreshes += 1;
      await refreshGate.future;
      currentToken = 'new-access';
      return true;
    }

    final httpFirst = coordinator.recover(
      tokenUsed: 'old-access',
      currentToken: () => currentToken,
      refresh: refresh,
    );
    final websocketSecond = coordinator.recover(
      tokenUsed: 'old-access',
      currentToken: () => currentToken,
      refresh: refresh,
    );
    refreshGate.complete();
    expect(await Future.wait([httpFirst, websocketSecond]), [isTrue, isTrue]);
    expect(refreshes, 1);

    for (var i = 0; i < 3; i++) {
      expect(
        await coordinator.recover(
          tokenUsed: 'old-access',
          currentToken: () => currentToken,
          refresh: refresh,
        ),
        isTrue,
      );
    }
    expect(refreshes, 1);

    currentToken = 'third-access';
    expect(
      await coordinator.recover(
        tokenUsed: 'third-access',
        currentToken: () => currentToken,
        refresh: () async {
          refreshes += 1;
          return true;
        },
      ),
      isTrue,
    );
    expect(refreshes, 2);
  });
}

class _FakeSocket implements SupervisedSocket {
  _FakeSocket({
    required this.authentication,
    required this.onMessage,
    required this.onDone,
  });

  final Map<String, dynamic> authentication;
  final void Function(Map<String, dynamic> message) onMessage;
  final void Function(int? closeCode, String? closeReason) onDone;

  void message(Map<String, dynamic> value) => onMessage(value);
  void done(int? code, String? reason) => onDone(code, reason);

  @override
  Future<void> close() async {}
}
