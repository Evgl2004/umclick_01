Future<void> downloadCsvFile({
  required String filename,
  required String content,
}) async {
  throw UnsupportedError('CSV download is supported only in web builds.');
}
