import 'package:web/web.dart' as web;

void openDisplayWindow({
  required int sessionId,
  required String apiBaseUrl,
}) {
  final queryParameters = <String, String>{
    'session': '$sessionId',
    if (apiBaseUrl.trim().isNotEmpty) 'api': apiBaseUrl.trim(),
  };
  final uri = Uri(path: '/display', queryParameters: queryParameters);
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
}
