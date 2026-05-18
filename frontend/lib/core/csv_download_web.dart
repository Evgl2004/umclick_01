import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> downloadCsvFile({
  required String filename,
  required String content,
}) async {
  // Prefix with BOM so spreadsheet apps detect UTF-8 Cyrillic text reliably.
  final csvContent = '\ufeff$content';
  final blob = web.Blob(
    [csvContent.toJS].toJS,
    web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';

  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
