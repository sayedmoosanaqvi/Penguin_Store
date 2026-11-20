import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'multipart_upload_helper.dart';

Future<MultipartUploadResponse> sendMultipartWithProgressImpl({
  required Uri uri,
  required Map<String, String> headers,
  required Map<String, String> fields,
  required List<MultipartUploadFile> files,
  void Function(double progress)? onProgress,
  Duration timeout = const Duration(minutes: 4),
}) async {
  final request = http.MultipartRequest('POST', uri)
    ..headers.addAll(headers)
    ..fields.addAll(fields);

  for (final file in files) {
    request.files.add(
      http.MultipartFile.fromBytes(
        file.fieldName,
        file.bytes,
        filename: file.fileName,
        contentType: MediaType.parse(file.contentType),
      ),
    );
  }

  final totalBytes = request.contentLength;
  final byteStream = request.finalize();
  int sentBytes = 0;

  final trackedStream = byteStream.transform<List<int>>(
    StreamTransformer.fromHandlers(
      handleData: (chunk, sink) {
        sentBytes += chunk.length;
        if (totalBytes > 0) {
          onProgress?.call((sentBytes / totalBytes).clamp(0.0, 1.0));
        }
        sink.add(chunk);
      },
    ),
  );

  final streamedRequest = http.StreamedRequest('POST', uri)
    ..headers.addAll(request.headers)
    ..contentLength = totalBytes;

  final client = http.Client();
  try {
    final responseFuture = client.send(streamedRequest).timeout(timeout);
    await trackedStream.pipe(streamedRequest.sink);
    final streamedResponse = await responseFuture;
    final response =
        await http.Response.fromStream(streamedResponse).timeout(timeout);
    onProgress?.call(1.0);
    return MultipartUploadResponse(
      statusCode: response.statusCode,
      body: response.body,
    );
  } finally {
    client.close();
  }
}
