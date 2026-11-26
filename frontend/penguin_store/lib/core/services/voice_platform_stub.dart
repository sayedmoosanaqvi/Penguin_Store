import 'dart:io';

import 'package:flutter/foundation.dart';

enum VoiceAudioPlayStatus { completed, stopped, autoplayBlocked, fallbackToTts }

class PlatformRecordedAudio {
  final Uint8List bytes;
  final String filename;
  final String mimeType;

  const PlatformRecordedAudio({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });
}

class PlatformRecordStartResult {
  final bool started;
  final String? errorMessage;

  const PlatformRecordStartResult({
    required this.started,
    this.errorMessage,
  });
}

bool get usesPlatformWebSpeech => false;

bool get usesPlatformWebRecorder => false;

void initWebAudio() {}

void primeWebSpeechOnUserGesture() {}

Future<VoiceAudioPlayStatus> speakWebChunks(
  List<String> chunks, {
  required double rate,
  VoidCallback? onStart,
}) async {
  return VoiceAudioPlayStatus.fallbackToTts;
}

void stopWebSpeechSync() {}

Future<PlatformRecordStartResult> startWebRecording() async {
  return const PlatformRecordStartResult(
    started: false,
    errorMessage: 'Web recorder unavailable on native platform.',
  );
}

Future<PlatformRecordedAudio?> stopWebRecording() async => null;

Future<void> cancelWebRecording() async {}

double sampleWebMicLevel() => 0.0;

Future<String> createTempRecordingPath({String extension = 'm4a'}) async {
  final dir = Directory.systemTemp;
  final ts = DateTime.now().millisecondsSinceEpoch;
  return '${dir.path}${Platform.pathSeparator}penguin_voice_$ts.$extension';
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
  return VoiceAudioPlayStatus.fallbackToTts;
}

Future<void> stopWavAudioPlatform() async {}
