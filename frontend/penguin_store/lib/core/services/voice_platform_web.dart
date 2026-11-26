import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

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

bool get usesPlatformWebSpeech => true;

bool get usesPlatformWebRecorder => true;

// ---- Web Speech Synthesis state ----
bool _webAudioInitialized = false;
bool _speechPrimed = false;
int _speechSessionId = 0;
Completer<VoiceAudioPlayStatus>? _activeSpeechCompleter;
// Keep active utterance referenced so Chromium/Safari don't GC it before onend fires.
final List<web.SpeechSynthesisUtterance> _retainedUtterances = [];
List<web.SpeechSynthesisVoice> _cachedVoices = const [];

// ---- Web WAV audio state ----
web.HTMLAudioElement? _activeAudioElement;
String? _activeBlobUrl;
Completer<VoiceAudioPlayStatus>? _activePlayCompleter;

// ---- Native Browser MediaRecorder state ----
web.MediaRecorder? _webMediaRecorder;
web.MediaStream? _webMediaStream;
web.AudioContext? _webMicAudioContext;
web.AnalyserNode? _webMicAnalyser;
List<web.Blob> _webRecordedChunks = <web.Blob>[];
String _webSelectedMime = '';
Completer<void>? _webRecorderStopCompleter;

bool _hasSpeechSynthesis() {
  try {
    return (web.window as JSObject).hasProperty('speechSynthesis'.toJS).toDart;
  } catch (_) {
    return false;
  }
}

void _refreshCachedVoices() {
  if (!_hasSpeechSynthesis()) return;
  try {
    final voices = web.window.speechSynthesis.getVoices().toDart;
    if (voices.isNotEmpty) {
      _cachedVoices = voices;
    }
  } catch (_) {}
}

void initWebAudio() {
  if (_webAudioInitialized) return;
  _webAudioInitialized = true;
  if (!_hasSpeechSynthesis()) return;
  try {
    final synth = web.window.speechSynthesis;
    _refreshCachedVoices();
    synth.onvoiceschanged = ((web.Event _) {
      _refreshCachedVoices();
    }).toJS;
  } catch (_) {}
}

/// Synchronously unlocks Mobile Safari / Android Chrome speech synthesis inside
/// a user tap/click handler so delayed async replies (e.g. CTRL-X chat or
/// Stripe verification) are permitted to speak aloud.
void primeWebSpeechOnUserGesture() {
  initWebAudio();
  if (_speechPrimed || !_hasSpeechSynthesis()) return;
  try {
    final synth = web.window.speechSynthesis;
    _refreshCachedVoices();
    if (!synth.speaking && !synth.pending) {
      final silentUtterance = web.SpeechSynthesisUtterance('')
        ..volume = 0
        ..rate = 1.0;
      _retainedUtterances
        ..clear()
        ..add(silentUtterance);
      synth.speak(silentUtterance);
    }
    _speechPrimed = true;
  } catch (_) {}
}

web.SpeechSynthesisVoice? _selectBestEnglishVoice(web.SpeechSynthesis synth) {
  List<web.SpeechSynthesisVoice> voices = _cachedVoices;
  if (voices.isEmpty) {
    try {
      voices = synth.getVoices().toDart;
      if (voices.isNotEmpty) {
        _cachedVoices = voices;
      }
    } catch (_) {}
  }
  if (voices.isEmpty) return null;

  for (final v in voices) {
    if (v.localService && v.lang.toLowerCase().startsWith('en-us')) return v;
  }
  for (final v in voices) {
    if (v.localService && v.lang.toLowerCase().startsWith('en')) return v;
  }
  for (final v in voices) {
    if (v.lang.toLowerCase().startsWith('en-us')) return v;
  }
  for (final v in voices) {
    if (v.lang.toLowerCase().startsWith('en')) return v;
  }
  return null;
}

void stopWebSpeechSync() {
  _speechSessionId++;
  final completer = _activeSpeechCompleter;
  if (completer != null && !completer.isCompleted) {
    completer.complete(VoiceAudioPlayStatus.stopped);
  }
  _activeSpeechCompleter = null;
  if (_retainedUtterances.isNotEmpty) {
    _retainedUtterances.clear();
  }

  if (_hasSpeechSynthesis()) {
    try {
      final synth = web.window.speechSynthesis;
      if (synth.speaking || synth.pending) {
        synth.cancel();
      }
    } catch (_) {}
  }
}

Future<VoiceAudioPlayStatus> speakWebChunks(
  List<String> chunks, {
  required double rate,
  VoidCallback? onStart,
}) async {
  initWebAudio();
  if (!_hasSpeechSynthesis() || chunks.isEmpty) {
    return VoiceAudioPlayStatus.fallbackToTts;
  }

  final synth = web.window.speechSynthesis;
  final int sessionId = ++_speechSessionId;

  // Cancel any prior pending utterance, or invalidate previous completer
  final prev = _activeSpeechCompleter;
  if (prev != null && !prev.isCompleted) {
    prev.complete(VoiceAudioPlayStatus.stopped);
  }
  _activeSpeechCompleter = null;

  final bool wasActive = synth.speaking || synth.pending;
  if (wasActive) {
    try {
      synth.cancel();
    } catch (_) {}
    // Brief pause when interrupting active Chrome speech so the new utterance
    // isn't immediately swallowed by cancel().
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (sessionId != _speechSessionId) {
      return VoiceAudioPlayStatus.stopped;
    }
  }

  _speechPrimed = true;
  onStart?.call();

  final bestVoice = _selectBestEnglishVoice(synth);
  final clampedRate = rate.clamp(0.65, 1.5);

  for (final chunk in chunks) {
    if (sessionId != _speechSessionId) {
      return VoiceAudioPlayStatus.stopped;
    }

    final completer = Completer<VoiceAudioPlayStatus>();
    _activeSpeechCompleter = completer;

    final utterance = web.SpeechSynthesisUtterance(chunk)
      ..lang = bestVoice?.lang ?? 'en-US'
      ..rate = clampedRate
      ..pitch = 1.0
      ..volume = 1.0;
    if (bestVoice != null) {
      utterance.voice = bestVoice;
    }
    _retainedUtterances
      ..clear()
      ..add(utterance);

    utterance.onend = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.complete(VoiceAudioPlayStatus.completed);
      }
    }).toJS;

    utterance.onerror = ((web.Event event) {
      String errCode = '';
      try {
        final jsEvt = event as JSObject;
        if (jsEvt.hasProperty('error'.toJS).toDart) {
          errCode = jsEvt['error']?.dartify()?.toString().toLowerCase() ?? '';
        }
      } catch (_) {}

      if (!completer.isCompleted) {
        if (errCode.contains('not-allowed')) {
          completer.complete(VoiceAudioPlayStatus.autoplayBlocked);
        } else if (errCode.contains('canceled') || errCode.contains('interrupted')) {
          completer.complete(VoiceAudioPlayStatus.stopped);
        } else {
          completer.complete(VoiceAudioPlayStatus.completed);
        }
      }
    }).toJS;

    // Crucial: invoke synth.speak synchronously inside the first turn before awaiting!
    try {
      synth.speak(utterance);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('notallowed') || msg.contains('not-allowed')) {
        return VoiceAudioPlayStatus.autoplayBlocked;
      }
      return VoiceAudioPlayStatus.fallbackToTts;
    }

    final maxWaitMs = (chunk.length * 110).clamp(4000, 20000);
    final chunkStatus = await completer.future.timeout(
      Duration(milliseconds: maxWaitMs),
      onTimeout: () => VoiceAudioPlayStatus.completed,
    );

    if (identical(_activeSpeechCompleter, completer)) {
      _activeSpeechCompleter = null;
    }

    if (sessionId != _speechSessionId ||
        chunkStatus == VoiceAudioPlayStatus.stopped) {
      return VoiceAudioPlayStatus.stopped;
    }
    if (chunkStatus == VoiceAudioPlayStatus.autoplayBlocked) {
      return VoiceAudioPlayStatus.autoplayBlocked;
    }
  }

  if (_retainedUtterances.isNotEmpty) {
    _retainedUtterances.clear();
  }
  return VoiceAudioPlayStatus.completed;
}

// ---- Native Browser MediaRecorder (Android Chrome & iOS Safari compatible) ----

String _pickSupportedRecordingMime() {
  const candidates = <String>[
    'audio/webm;codecs=opus',
    'audio/webm',
    'audio/mp4;codecs=mp4a.40.2',
    'audio/mp4',
    'audio/ogg;codecs=opus',
  ];
  for (final mime in candidates) {
    try {
      if (web.MediaRecorder.isTypeSupported(mime)) {
        return mime;
      }
    } catch (_) {}
  }
  return '';
}

String _mapWebErrorMessage(Object err) {
  final raw = err.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('notallowed') || lower.contains('permission')) {
    return 'Microphone permission denied. Please allow microphone access in your browser site settings.';
  }
  if (lower.contains('notfound') || lower.contains('requested device not found')) {
    return 'No microphone was found on this device.';
  }
  if (lower.contains('notreadable') || lower.contains('trackstart')) {
    return 'Microphone is currently busy in another app. Close other audio apps and try again.';
  }
  if (lower.contains('security') || lower.contains('insecure')) {
    return 'Microphone requires an HTTPS connection on mobile browsers.';
  }
  return 'Unable to start microphone recording cleanly.';
}

void _cleanupWebRecorderState() {
  final mr = _webMediaRecorder;
  if (mr != null) {
    try {
      mr.ondataavailable = null;
      mr.onstop = null;
      mr.onerror = null;
    } catch (_) {}
  }
  _webMediaRecorder = null;

  _webMicAnalyser = null;
  final audioCtx = _webMicAudioContext;
  _webMicAudioContext = null;
  if (audioCtx != null) {
    try {
      audioCtx.close();
    } catch (_) {}
  }

  final ms = _webMediaStream;
  if (ms != null) {
    try {
      for (final track in ms.getTracks().toDart) {
        track.stop();
      }
    } catch (_) {}
  }
  _webMediaStream = null;
  _webRecordedChunks = <web.Blob>[];
  _webSelectedMime = '';
  _webRecorderStopCompleter = null;
}

double sampleWebMicLevel() {
  final analyser = _webMicAnalyser;
  if (analyser == null) return 0.0;
  try {
    final buf = Uint8List(128);
    final jsArr = buf.toJS;
    analyser.getByteTimeDomainData(jsArr);
    final samples = jsArr.toDart;
    double sumSq = 0.0;
    for (int i = 0; i < samples.length; i++) {
      final centered = (samples[i] - 128) / 128.0;
      sumSq += centered * centered;
    }
    final rms = sumSq > 0 ? (sumSq / samples.length) : 0.0;
    // Map quiet speech RMS (~0.01..0.25) smoothly into [0.05, 1.0]
    final scaled = (rms * 18.0).clamp(0.0, 1.0);
    return scaled;
  } catch (_) {
    return 0.0;
  }
}

Future<PlatformRecordStartResult> startWebRecording() async {
  stopWebSpeechSync();
  await cancelWebRecording();

  try {
    if (!web.window.isSecureContext) {
      return const PlatformRecordStartResult(
        started: false,
        errorMessage:
            'Microphone access requires HTTPS (or localhost). Open Penguin Store via HTTPS on your mobile browser.',
      );
    }
    if (!(web.window.navigator as JSObject)
        .hasProperty('mediaDevices'.toJS)
        .toDart) {
      return const PlatformRecordStartResult(
        started: false,
        errorMessage: 'Microphone API is unavailable in this browser.',
      );
    }
    if (!(web.window as JSObject).hasProperty('MediaRecorder'.toJS).toDart) {
      return const PlatformRecordStartResult(
        started: false,
        errorMessage: 'Audio recording is not supported in this browser.',
      );
    }

    web.MediaStream stream;
    try {
      final constraints = web.MediaStreamConstraints(
        audio: {
          'sampleRate': 16000,
          'channelCount': 1,
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        }.jsify()!,
      );
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
    } catch (firstErr) {
      final lower = firstErr.toString().toLowerCase();
      if (lower.contains('notallowed') || lower.contains('permission')) {
        return PlatformRecordStartResult(
          started: false,
          errorMessage: _mapWebErrorMessage(firstErr),
        );
      }
      // Fallback with simple boolean constraint for stricter mobile WebViews/iOS Safari
      final simple = web.MediaStreamConstraints(audio: true.toJS);
      stream = await web.window.navigator.mediaDevices.getUserMedia(simple).toDart;
    }

    // Attach lightweight Web Audio AnalyserNode for live mic amplitude visualization
    try {
      final audioCtx = web.AudioContext();
      final source = audioCtx.createMediaStreamSource(stream);
      final analyser = audioCtx.createAnalyser()..fftSize = 256;
      source.connect(analyser);
      _webMicAudioContext = audioCtx;
      _webMicAnalyser = analyser;
    } catch (_) {
      _webMicAudioContext = null;
      _webMicAnalyser = null;
    }

    final chosenMime = _pickSupportedRecordingMime();
    web.MediaRecorder mr;
    if (chosenMime.isNotEmpty) {
      try {
        mr = web.MediaRecorder(
          stream,
          web.MediaRecorderOptions(mimeType: chosenMime),
        );
      } catch (_) {
        mr = web.MediaRecorder(stream);
      }
    } else {
      mr = web.MediaRecorder(stream);
    }

    final chunks = <web.Blob>[];
    final stopCompleter = Completer<void>();

    mr.ondataavailable = ((web.BlobEvent event) {
      final data = event.data;
      if (data.size > 0) {
        chunks.add(data);
      }
    }).toJS;

    mr.onstop = ((web.Event _) {
      if (!stopCompleter.isCompleted) {
        stopCompleter.complete();
      }
    }).toJS;

    mr.onerror = ((web.Event _) {
      if (!stopCompleter.isCompleted) {
        stopCompleter.complete();
      }
    }).toJS;

    _webMediaStream = stream;
    _webMediaRecorder = mr;
    _webRecordedChunks = chunks;
    _webSelectedMime = chosenMime;
    _webRecorderStopCompleter = stopCompleter;

    // Request 250ms timeslices so even short taps produce audio chunks on mobile Safari/Chrome
    mr.start(250);
    return const PlatformRecordStartResult(started: true);
  } catch (err) {
    _cleanupWebRecorderState();
    return PlatformRecordStartResult(
      started: false,
      errorMessage: _mapWebErrorMessage(err),
    );
  }
}

Future<PlatformRecordedAudio?> stopWebRecording() async {
  final mr = _webMediaRecorder;
  final stopCompleter = _webRecorderStopCompleter;
  if (mr == null) {
    _cleanupWebRecorderState();
    return null;
  }

  try {
    if (mr.state == 'recording' || mr.state == 'paused') {
      try {
        mr.requestData();
      } catch (_) {}
      mr.stop();
      if (stopCompleter != null && !stopCompleter.isCompleted) {
        await stopCompleter.future.timeout(
          const Duration(milliseconds: 2500),
          onTimeout: () {},
        );
      }
    }
  } catch (_) {}

  // Immediately stop hardware mic stream tracks so mobile indicator disappears
  final ms = _webMediaStream;
  if (ms != null) {
    try {
      for (final track in ms.getTracks().toDart) {
        track.stop();
      }
    } catch (_) {}
  }

  final chunks = List<web.Blob>.from(_webRecordedChunks);
  String mime = _webSelectedMime;
  if (mime.isEmpty) {
    try {
      mime = mr.mimeType;
    } catch (_) {}
  }

  _cleanupWebRecorderState();

  if (chunks.isEmpty) {
    return null;
  }

  final effectiveMime = mime.isNotEmpty ? mime : 'audio/webm';
  try {
    final blob = web.Blob(
      chunks.toJS,
      web.BlobPropertyBag(type: effectiveMime),
    );
    final ab = await blob.arrayBuffer().toDart;
    final bytes = ab.toDart.asUint8List();
    if (bytes.isEmpty) return null;

    final lowerMime = effectiveMime.toLowerCase();
    String ext = 'webm';
    String cleanMime = 'audio/webm';
    if (lowerMime.contains('mp4') ||
        lowerMime.contains('m4a') ||
        lowerMime.contains('aac')) {
      ext = 'mp4';
      cleanMime = 'audio/mp4';
    } else if (lowerMime.contains('ogg')) {
      ext = 'ogg';
      cleanMime = 'audio/ogg';
    } else if (lowerMime.contains('wav')) {
      ext = 'wav';
      cleanMime = 'audio/wav';
    }

    return PlatformRecordedAudio(
      bytes: bytes,
      filename: 'recording.$ext',
      mimeType: cleanMime,
    );
  } catch (e) {
    debugPrint('stopWebRecording blob read error: $e');
    return null;
  }
}

Future<void> cancelWebRecording() async {
  final mr = _webMediaRecorder;
  final stopCompleter = _webRecorderStopCompleter;
  if (mr != null) {
    try {
      if (mr.state == 'recording' || mr.state == 'paused') {
        mr.stop();
        if (stopCompleter != null && !stopCompleter.isCompleted) {
          await stopCompleter.future.timeout(
            const Duration(milliseconds: 800),
            onTimeout: () {},
          );
        }
      }
    } catch (_) {}
  }
  _cleanupWebRecorderState();
}

Future<String> createTempRecordingPath({String extension = 'm4a'}) async {
  return 'penguin_web_voice.$extension';
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
      if (msg.contains('notallowed') ||
          msg.contains('autoplay') ||
          msg.contains('gesture')) {
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
