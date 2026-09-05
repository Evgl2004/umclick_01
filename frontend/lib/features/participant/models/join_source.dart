class ParticipantJoinSource {
  const ParticipantJoinSource({
    this.joinToken,
    this.pin,
  });

  factory ParticipantJoinSource.fromUri(Uri uri) {
    return ParticipantJoinSource(
      joinToken: _queryValue(uri, 'token'),
      pin: _queryValue(uri, 'pin'),
    );
  }

  final String? joinToken;
  final String? pin;

  bool get hasJoinTarget => joinToken != null || pin != null;
  bool get shouldUseJoinToken => joinToken != null;

  static String? _queryValue(Uri uri, String key) {
    final value = uri.queryParameters[key]?.trim() ?? '';
    return value.isEmpty ? null : value;
  }
}
