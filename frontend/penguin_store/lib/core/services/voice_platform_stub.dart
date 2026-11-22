import 'dart:io';
import 'dart:typed_data';

enum VoiceAudioPlayStatus { completed, stopped, autoplayBlocked, fallbackToTts }

Future<String> createTempRecordingPath() async {
  final dir = Directory.systemTemp;
  final ts = DateTime.now().millisecondsSinceEpoch;
  return '${dir.path}${Platform.pathSeparator}penguin_voice_$ts.m4a';
}

Future<Uint8List?> readRecordedAudioBytes(String pathOrUrl) async {
  try {
    final file = File(pathOrUrl);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {}
    return bytes;
  } catch (_) {
    return null;
  }
}

Future<VoiceAudioPlayStatus> playWavBytesPlatform(Uint8List wavBytes) async {
  // On non-web targets, delegate seamlessly to FlutterTts or native playback.
  return VoiceAudioPlayStatus.fallbackToTts;
}

Future<void> stopWavAudioPlatform() async {}
