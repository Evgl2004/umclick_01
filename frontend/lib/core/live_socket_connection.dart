import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'value_utils.dart';

abstract interface class SupervisedSocket {
  Future<void> close();
}

class LiveSocketConnection implements SupervisedSocket {
  const LiveSocketConnection._({
    required WebSocketChannel channel,
    required StreamSubscription subscription,
  })  : _channel = channel,
        _subscription = subscription;

  final WebSocketChannel _channel;
  final StreamSubscription _subscription;

  static LiveSocketConnection connect({
    required String url,
    required Map<String, dynamic> authentication,
    required void Function(Map<String, dynamic> message) onMessage,
    required void Function(Object error) onError,
    required void Function(int? closeCode, String? closeReason) onDone,
    required void Function() onInvalidPayload,
    bool Function()? isActive,
  }) {
    bool canNotify() => isActive?.call() ?? true;

    final channel = WebSocketChannel.connect(Uri.parse(url));
    final subscription = channel.stream.listen(
      (raw) {
        if (!canNotify()) return;
        try {
          final decoded = jsonDecode(raw as String);
          final message = mapOrNull(decoded);
          if (message == null) {
            onInvalidPayload();
            return;
          }
          onMessage(message);
        } catch (_) {
          onInvalidPayload();
        }
      },
      onError: (error) {
        if (!canNotify()) return;
        onError(error);
      },
      onDone: () {
        if (!canNotify()) return;
        onDone(channel.closeCode, channel.closeReason);
      },
    );
    channel.sink.add(jsonEncode(authentication));

    return LiveSocketConnection._(
      channel: channel,
      subscription: subscription,
    );
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _channel.sink.close();
  }
}
