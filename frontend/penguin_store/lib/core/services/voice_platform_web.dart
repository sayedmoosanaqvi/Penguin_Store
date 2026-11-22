import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

enum VoiceAudioPlayStatus { completed, stopped, autoplayBlocked, fallbackToTts }

web.HTMLAudioElement? _activeAudioElement;
String? _activeBlobUrl;
Completer<VoiceAudioPlayStatus>? _activePlayCompleter;

Future<String> createTempRecordingPath() async {
  // Ignored on Web; record_web returns a blob: URL from stop().
  return 'penguin_web_voice.webm';
}

Future<Uint8List?> readRecordedAudioBytes(String pathOrUrl) async {
  if (pathOrUrl.trim().isEmpty) return null;
  try {
    final res = await http.get(Uri.parse(pathOrUrl));
    try {
      web.URL.revokeObjectURL(pathOrUrl);
    } catch (_) {}
    if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
      return res.bodyBytes;
    }
    return null;
  } catch (_) {
    return null;
  }
}

Future<VoiceAudioPlayStatus> playWavBytesPlatform(Uint8List wavBytes) async {
  await stopWavAudioPlatform();

  final completer = Completer<VoiceAudioPlayStatus>();
  _activePlayCompleter = completer;

  try {
    final jsParts = <JSAny>[wavBytes.toJS].toJS;
    final blob = web.Blob(jsParts, web.BlobPropertyBag(type: 'audio/wav'));
    final blobUrl = web.URL.createObjectURL(blob);
    _activeBlobUrl = blobUrl;

    final audio = web.HTMLAudioElement()
      ..src = blobUrl
      ..autoplay = false;
    _activeAudioElement = audio;

    void finish(VoiceAudioPlayStatus status) {
      if (!completer.isCompleted) {
        completer.complete(status);
      }
      _cleanupAudio();
    }

    audio.onEnded.listen((_) => finish(VoiceAudioPlayStatus.completed));
    audio.onError.listen((_) => finish(VoiceAudioPlayStatus.fallbackToTts));

    try {
      await audio.play().toDart;
    } catch (err) {
      final msg = err.toString().toLowerCase();
      if (msg.contains('notallowed') || msg.contains('autoplay') || msg.contains('gesture')) {
        finish(VoiceAudioPlayStatus.autoplayBlocked);
      } else {
        finish(VoiceAudioPlayStatus.fallbackToTts);
      }
      return completer.future;
    }

    return completer.future;
  } catch (_) {
    _cleanupAudio();
    return VoiceAudioPlayStatus.fallbackToTts;
  }
}

void _cleanupAudio() {
  final audio = _activeAudioElement;
  if (audio != null) {
    try {
      audio.pause();
      audio.src = '';
    } catch (_) {}
  }
  _activeAudioElement = null;

  final url = _activeBlobUrl;
  if (url != null) {
    try {
      web.URL.revokeObjectURL(url);
    } catch (_) {}
  }
  _activeBlobUrl = null;
}

Future<void> stopWavAudioPlatform() async {
  final c = _activePlayCompleter;
  if (c != null && !c.isCompleted) {
    c.complete(VoiceAudioPlayStatus.stopped);
  }
  _activePlayCompleter = null;
  _cleanupAudio();
}
