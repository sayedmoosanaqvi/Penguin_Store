import 'dart:typed_data';

import 'multipart_upload_helper_io.dart'
    if (dart.library.js_interop) 'multipart_upload_helper_web.dart' as impl;

class MultipartUploadFile {
  final String fieldName;
  final String fileName;
  final Uint8List bytes;
  final String contentType;

  const MultipartUploadFile({
    required this.fieldName,
    required this.fileName,
    required this.bytes,
    this.contentType = 'application/octet-stream',
  });
}

class MultipartUploadResponse {
  final int statusCode;
  final String body;

  const MultipartUploadResponse({
    required this.statusCode,
    required this.body,
  });
}

/// Sends a multipart/form-data POST request while emitting real byte-level
/// upload progress (`0.0` to `1.0`) on both Flutter Web (via XMLHttpRequest)
/// and mobile/desktop IO (via chunked ByteStream).
Future<MultipartUploadResponse> sendMultipartWithProgress({
  required Uri uri,
  required Map<String, String> headers,
  required Map<String, String> fields,
  required List<MultipartUploadFile> files,
  void Function(double progress)? onProgress,
  Duration timeout = const Duration(minutes: 4),
}) {
  return impl.sendMultipartWithProgressImpl(
    uri: uri,
    headers: headers,
    fields: fields,
    files: files,
    onProgress: onProgress,
    timeout: timeout,
  );
}
