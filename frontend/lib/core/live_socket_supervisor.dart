import 'dart:async';
import 'dart:math';

import 'live_socket_connection.dart';
import 'value_utils.dart';

export 'live_socket_connection.dart' show SupervisedSocket;

typedef SupervisedSocketOpener = SupervisedSocket Function({
  required Map<String, dynamic> authentication,
  required void Function(Map<String, dynamic> message) onMessage,
  required void Function(Object error) onError,
  required void Function(int? closeCode, String? closeReason) onDone,
  required void Function() onInvalidPayload,
});

typedef SocketDelay = Future<void> Function(Duration duration);
typedef SocketAuthenticationRecovery = Future<Map<String, dynamic>?> Function(
  Map<String, dynamic> usedAuthentication,
);

class LiveSocketSupervisor {
  LiveSocketSupervisor({
    required this.url,
    required Map<String, dynamic> authentication,
    required this.onMessage,
    required this.onConnectionError,
    required this.onInvalidPayload,
    required this.onTransportError,
    required this.onStopped,
    this.recoverAuthentication,
    SupervisedSocketOpener? opener,
    SocketDelay? delay,
    double Function(double seconds)? jitter,
  })  : _authentication = Map<String, dynamic>.from(authentication),
        _opener = opener,
        _delay = delay ?? ((duration) => Future<void>.delayed(duration)),
        _jitter = jitter ??
            ((seconds) {
              final factor = 0.8 + Random.secure().nextDouble() * 0.4;
              return seconds * factor;
            });

  final String url;
  final void Function(Map<String, dynamic> message) onMessage;
  final void Function(Map<String, dynamic> error) onConnectionError;
  final void Function() onInvalidPayload;
  final void Function(Object error) onTransportError;
  final void Function(int? closeCode, String? reason) onStopped;
  final SocketAuthenticationRecovery? recoverAuthentication;
  final SupervisedSocketOpener? _opener;
  final SocketDelay _delay;
  final double Function(double seconds) _jitter;
  Map<String, dynamic> _authentication;

  SupervisedSocket? _socket;
  Completer<void>? _cancelSignal;
  bool _stopped = true;
  int _generation = 0;
  int _rateLimitRetries = 0;
  int _unavailableRetries = 0;
  int _networkRetries = 0;
  String? _serverErrorCode;
  int? _serverRetryAfter;

  Future<void> start() async {
    if (!_stopped) return;
    _stopped = false;
    _generation += 1;
    await _open(_generation);
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _generation += 1;
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  Future<void> _open(int generation) async {
    if (_stopped || generation != _generation) return;
    _serverErrorCode = null;
    _serverRetryAfter = null;
    final usedAuthentication = Map<String, dynamic>.from(_authentication);
    try {
      final opener = _opener;
      _socket = opener != null
          ? opener(
              authentication: usedAuthentication,
              onMessage: (message) => _handleMessage(message),
              onError: onTransportError,
              onDone: (code, reason) {
                _socket = null;
                unawaited(_handleClosed(
                  generation,
                  code,
                  reason,
                  usedAuthentication,
                ));
              },
              onInvalidPayload: onInvalidPayload,
            )
          : LiveSocketConnection.connect(
              url: url,
              authentication: usedAuthentication,
              onMessage: (message) => _handleMessage(message),
              onError: onTransportError,
              onDone: (code, reason) {
                _socket = null;
                unawaited(_handleClosed(
                  generation,
                  code,
                  reason,
                  usedAuthentication,
                ));
              },
              onInvalidPayload: onInvalidPayload,
            );
    } catch (error) {
      onTransportError(error);
      await _scheduleNetworkRetry(generation, null, null);
    }
  }

  void _handleMessage(Map<String, dynamic> message) {
    if (message['event'] == 'connection_error') {
      final payload = mapOrNull(message['payload']) ?? message;
      _serverErrorCode = payload['code']?.toString();
      _serverRetryAfter = _positiveInt(payload['retry_after']);
      onConnectionError(payload);
      return;
    }
    _rateLimitRetries = 0;
    _unavailableRetries = 0;
    _networkRetries = 0;
    onMessage(message);
  }

  Future<void> _handleClosed(
    int generation,
    int? closeCode,
    String? closeReason,
    Map<String, dynamic> usedAuthentication,
  ) async {
    if (_stopped || generation != _generation) return;
    final errorCode = _serverErrorCode;
    if (closeCode == 4003 &&
        errorCode == 'access_expired' &&
        recoverAuthentication != null) {
      try {
        final recovered = await recoverAuthentication!(
          Map<String, dynamic>.unmodifiable(usedAuthentication),
        );
        if (_stopped || generation != _generation) return;
        if (recovered == null) {
          _finish(closeCode, errorCode);
          return;
        }
        _authentication = Map<String, dynamic>.from(recovered);
        await _open(generation);
      } catch (error) {
        if (_stopped || generation != _generation) return;
        onTransportError(error);
        _finish(closeCode, errorCode);
      }
      return;
    }
    if (closeCode == 4429 || errorCode == 'rate_limited') {
      if (_rateLimitRetries >= 3) {
        _finish(closeCode, errorCode ?? closeReason);
        return;
      }
      _rateLimitRetries += 1;
      await _waitAndOpen(
        generation,
        Duration(seconds: _serverRetryAfter ?? 1),
      );
      return;
    }
    if (closeCode == 4503 || errorCode == 'limiter_unavailable') {
      if (_unavailableRetries >= 3) {
        _finish(closeCode, errorCode ?? closeReason);
        return;
      }
      final seconds = 3 * (1 << _unavailableRetries);
      _unavailableRetries += 1;
      await _waitAndOpen(generation, Duration(seconds: seconds));
      return;
    }
    if (closeCode == null || closeCode == 1006 || closeCode == 1012) {
      await _scheduleNetworkRetry(generation, closeCode, closeReason);
      return;
    }
    _finish(closeCode, errorCode ?? closeReason);
  }

  Future<void> _scheduleNetworkRetry(
    int generation,
    int? closeCode,
    String? closeReason,
  ) async {
    const seconds = [1, 2, 4, 8, 16, 30];
    if (_networkRetries >= seconds.length) {
      _finish(closeCode, closeReason);
      return;
    }
    final jittered = _jitter(seconds[_networkRetries].toDouble());
    _networkRetries += 1;
    await _waitAndOpen(
      generation,
      Duration(milliseconds: max(1, (jittered * 1000).round())),
    );
  }

  Future<void> _waitAndOpen(int generation, Duration duration) async {
    final signal = Completer<void>();
    _cancelSignal = signal;
    await Future.any([_delay(duration), signal.future]);
    if (_stopped || generation != _generation || signal.isCompleted) return;
    await _open(generation);
  }

  void _finish(int? closeCode, String? reason) {
    _stopped = true;
    _generation += 1;
    onStopped(closeCode, reason);
  }

  int? _positiveInt(Object? value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }
}

class SingleFlightTokenRefresh {
  Future<bool>? _inFlight;

  Future<bool> recover({
    required String tokenUsed,
    required String? Function() currentToken,
    required Future<bool> Function() refresh,
  }) {
    final current = currentToken();
    if (current != tokenUsed) {
      return Future<bool>.value(current != null && current.isNotEmpty);
    }
    final active = _inFlight;
    if (active != null) return active;
    final started = _run(refresh);
    _inFlight = started;
    return started;
  }

  Future<bool> _run(Future<bool> Function() refresh) async {
    try {
      return await refresh();
    } finally {
      _inFlight = null;
    }
  }
}
