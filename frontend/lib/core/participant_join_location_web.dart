import 'package:web/web.dart' as web;

void replaceBrowserLocation(Uri uri) {
  web.window.history.replaceState(null, '', uri.toString());
}
