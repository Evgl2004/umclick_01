import 'participant_join_location_stub.dart'
    if (dart.library.html) 'participant_join_location_web.dart' as platform;
import 'session_uuid.dart';

Uri canonicalParticipantJoinUri(Uri current, String sessionUuid) {
  final uuid = normalizeSessionUuid(sessionUuid);
  return current.replace(
    path: '/join',
    queryParameters: {'token': uuid},
  ).removeFragment();
}

void replaceParticipantJoinLocation(String sessionUuid) {
  platform.replaceBrowserLocation(
    canonicalParticipantJoinUri(Uri.base, sessionUuid),
  );
}
