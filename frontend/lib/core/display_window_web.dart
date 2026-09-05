import 'package:web/web.dart' as web;

void openDisplayWindow({
  required String sessionUuid,
}) {
  final queryParameters = <String, String>{
    'session': sessionUuid,
  };
  final uri = Uri(path: '/display', queryParameters: queryParameters);
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
}
