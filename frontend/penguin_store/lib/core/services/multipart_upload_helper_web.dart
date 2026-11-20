import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'multipart_upload_helper.dart';

Future<MultipartUploadResponse> sendMultipartWithProgressImpl({
  required Uri uri,
  required Map<String, String> headers,
  required Map<String, String> fields,
  required List<MultipartUploadFile> files,
  void Function(double progress)? onProgress,
  Duration timeout = const Duration(minutes: 4),
}) {
  final completer = Completer<MultipartUploadResponse>();
  final xhr = web.XMLHttpRequest();

  xhr.open('POST', uri.toString());
  xhr.timeout = timeout.inMilliseconds;

  headers.forEach((key, value) {
    if (key.toLowerCase() != 'content-type') {
      xhr.setRequestHeader(key, value);
    }
  });

  final formData = web.FormData();
  fields.forEach((key, value) {
    formData.append(key, value.toJS);
  });

  for (final file in files) {
    final blob = web.Blob(
      <JSAny>[file.bytes.toJS].toJS,
      web.BlobPropertyBag(type: file.contentType),
    );
    formData.append(file.fieldName, blob, file.fileName);
  }

  xhr.upload.onprogress = ((web.ProgressEvent event) {
    if (event.lengthComputable && event.total > 0) {
      final ratio = (event.loaded / event.total).clamp(0.0, 1.0);
      onProgress?.call(ratio);
    }
  }).toJS;

  xhr.onload = ((web.Event _) {
    onProgress?.call(1.0);
    if (!completer.isCompleted) {
      completer.complete(
        MultipartUploadResponse(
          statusCode: xhr.status,
          body: xhr.responseText,
        ),
      );
    }
  }).toJS;

  xhr.onerror = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        Exception('Network error while uploading file to server.'),
      );
    }
  }).toJS;

  xhr.ontimeout = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        TimeoutException('Upload timed out. Check connection and retry.'),
      );
    }
  }).toJS;

  xhr.send(formData);
  return completer.future;
}
