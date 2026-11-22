import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:record/record.dart';

import 'package:penguin_store/config/api_config.dart';

import 'voice_platform_stub.dart'
    if (dart.library.js_interop) 'voice_platform_web.dart' as platform_audio;

class VoiceTranscriptionResult {
  final String transcript;
  final String language;
  final double latencyMs;
  final bool emptyClip;
  final String? errorMessage;

  const VoiceTranscriptionResult({
    this.transcript = '',
    this.language = 'en',
    this.latencyMs = 0.0,
    this.emptyClip = false,
    this.errorMessage,
  });

  bool get hasTranscript => transcript.trim().isNotEmpty;
  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
}

class VoiceSpeakOutcome {
  final bool completed;
  final bool stopped;
  final bool autoplayBlocked;
  final bool usedNeuralTts;

  const VoiceSpeakOutcome({
    this.completed = false,
    this.stopped = false,
    this.autoplayBlocked = false,
    this.usedNeuralTts = false,
  });
}

/// Defense-in-depth sanitizer eliminating Markdown syntax ("dash dash dash",
/// pipes, asterisks, underscores, raw tables) before text reaches any TTS engine.
class SpeechTextCleaner {
  SpeechTextCleaner._();

  static String clean(String raw) {
    if (raw.trim().isEmpty) return '';
    var text = raw;

    // 1. Strip fenced code blocks, Markdown links, and bare URLs
    text = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (m) => m.group(1) ?? '',
    );
    text = text.replaceAll(RegExp(r'https?://\S+'), '');

    // 2. Drop Markdown table rows and horizontal rule lines line-by-line
    final keptLines = <String>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final s = line.trim();
      if (s.isEmpty) continue;
      if (RegExp(r'^[-:=_*+|•·\s\u2500-\u257f]+$').hasMatch(s)) continue;
      if (s.startsWith('|') || '|'.allMatches(s).length >= 2) continue;
      final noBullet = s.replaceFirst(RegExp(r'^\s*(?:#{1,6}|[-*+•>]+)\s+'), '');
      if (noBullet.trim().isNotEmpty) keptLines.add(noBullet.trim());
    }
    text = keptLines.join('. ');

    // 3. Order numbers & currencies
    text = text.replaceAllMapped(
      RegExp(r'(?:Order\s*#\s*|#)([A-Za-z0-9-]+)', caseSensitive: false),
      (m) {
        final token = (m.group(1) ?? '').replaceAll('-', ' ');
        return 'order number $token';
      },
    );
    text = text.replaceAllMapped(
      RegExp(r'\$\s*([0-9][0-9,]*)(?:\.(\d{1,2}))?'),
      (m) {
        final whole = (m.group(1) ?? '0').replaceAll(',', '');
        final cents = m.group(2);
        if (cents == null || cents == '00') {
          return '$whole dollars';
        }
        return '$whole dollars and $cents cents';
      },
    );
    text = text.replaceAllMapped(
      RegExp(r'€\s*([0-9][0-9,]*(?:\.\d{1,2})?)'),
      (m) => '${(m.group(1) ?? '0').replaceAll(',', '')} euros',
    );
    text = text.replaceAllMapped(
      RegExp(r'Rs\.?\s*([0-9][0-9,]*)'),
      (m) => '${(m.group(1) ?? '0').replaceAll(',', '')} rupees',
    );

    // 4. Symbols, emojis, and dash/underscore runs
    text = text.replaceAll('%', ' percent');
    text = text.replaceAll('&', ' and ');
    text = text.replaceAll(RegExp(r'\s*[★☆⭐]+\s*'), ' star ');
    text = text.replaceAll(RegExp(r'[✅☑️❌⚠️🔥🔊⏹🎉📦🤖🛡️✨💎]+'), ' ');
    text = text.replaceAll(RegExp(r'[\u{10000}-\u{10FFFF}]', unicode: true), ' ');
    text = text.replaceAll(RegExp(r'[*_#`~|<>^\\]+'), ' ');
    text = text.replaceAll(RegExp(r'[-–—]{2,}|_{2,}|\.{2,}|={2,}'), ', ');
    text = text.replaceAll(RegExp(r'\s+[-–—]\s+'), ', ');
    text = text.replaceAll(RegExp(r'(?<!\w)[-–—]+|[-–—]+(?!\w)'), ' ');
    text = text.replaceAll(RegExp(r'\s*,\s*(?:,\s*)+'), ', ');
    text = text.replaceAll(RegExp(r'\.\s*,'), '.');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }
}

/// Centralized, singleton-backed Voice Intelligence Engine (Phase 2).
///
/// Handles:
/// - Cross-platform microphone recording (native browser `MediaRecorder` on
///   Web/Mobile Web; `AudioRecorder` on Android/iOS) uploading to
///   `POST /api/v1/ai/transcribe` (Groq Whisper `whisper-large-v3-turbo`)
/// - Cross-platform Text-to-Speech: native browser `window.speechSynthesis`
///   with gesture priming on Web/Mobile Safari/Chrome, and `FlutterTts` with
///   iOS playback audio-session & Android queue configuration on mobile apps.
class VoiceService {
  VoiceService._() {
    if (kIsWeb) {
      platform_audio.initWebAudio();
    } else {
      _initNativeTts();
    }
  }

  static final VoiceService instance = VoiceService._();

  final FlutterTts _tts = FlutterTts();
  AudioRecorder? _recorder;

  bool _ttsInitialized = false;
  bool _isRecording = false;
  bool _cancelSpeakRequested = false;
  String _nativeRecordingExt = 'm4a';
  String? _lastRecordError;
  Completer<void>? _chunkCompleter;

  bool get isRecording => _isRecording;
  String? get lastRecordError => _lastRecordError;

  static String get _base =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  /// Must be called synchronously inside a user tap/click handler on Web
  /// (especially Mobile Safari / Chrome) so delayed async replies can speak.
  void primeSpeechOnUserGesture() {
    platform_audio.primeWebSpeechOnUserGesture();
  }

  Future<void> _configureIosPlaybackSession() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
        IosTextToSpeechAudioMode.spokenAudio,
      );
    } catch (e) {
      debugPrint('VoiceService iOS audio category notice: $e');
    }
  }

  Future<void> _initNativeTts() async {
    if (kIsWeb || _ttsInitialized) return;
    _ttsInitialized = true;
    try {
      await _configureIosPlaybackSession();
      await _tts.setLanguage('en-US');
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _tts.setQueueMode(0);
      }
      await _tts.awaitSpeakCompletion(false);

      _tts.setCompletionHandler(() {
        final c = _chunkCompleter;
        if (c != null && !c.isCompleted) c.complete();
      });
      _tts.setCancelHandler(() {
        final c = _chunkCompleter;
        if (c != null && !c.isCompleted) c.complete();
      });
      _tts.setErrorHandler((_) {
        final c = _chunkCompleter;
        if (c != null && !c.isCompleted) c.complete();
      });
    } catch (e) {
      debugPrint('VoiceService TTS init notice: $e');
    }
  }

  // -------------------------------------------------------------------------
  // SPEECH CLEANUP & CHUNKING UTILITIES
  // -------------------------------------------------------------------------

  /// Defense-in-depth sanitizer ensuring Markdown tables (`| --- | --- |`),
  /// horizontal rules, bullets, emojis, and punctuation runs never get read
  /// literally as "dash dash dash" or "underscore" by any TTS engine.
  static String cleanTextForSpeech(String raw) =>
      SpeechTextCleaner.clean(raw);

  /// Splits text into crisp chunks (`<= maxChunkLength` chars) at sentence
  /// boundaries so browser `speechSynthesis` never truncates long utterances.
  static List<String> splitIntoSpeechChunks(
    String cleanedText, {
    int maxChunkLength = 160,
  }) {
    final text = cleanedText.trim();
    if (text.isEmpty) return const [];
    if (text.length <= maxChunkLength) return [text];

    final rawSentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final chunks = <String>[];
    final current = StringBuffer();

    void flushCurrent() {
      final str = current.toString().trim();
      if (str.isNotEmpty) chunks.add(str);
      current.clear();
    }

    for (final s in rawSentences) {
      final sentence = s.trim();
      if (sentence.isEmpty) continue;

      if (sentence.length > maxChunkLength) {
        flushCurrent();
        final words = sentence.split(RegExp(r'\s+'));
        for (final w in words) {
          if (current.length + w.length + 1 > maxChunkLength &&
              current.isNotEmpty) {
            flushCurrent();
          }
          if (current.isNotEmpty) current.write(' ');
          current.write(w);
        }
        flushCurrent();
      } else if (current.isEmpty) {
        current.write(sentence);
      } else if (current.length + sentence.length + 1 <= maxChunkLength) {
        current.write(' ');
        current.write(sentence);
      } else {
        flushCurrent();
        current.write(sentence);
      }
    }
    flushCurrent();
    return chunks;
  }

  // -------------------------------------------------------------------------
  // SPEECH-TO-TEXT RECORDING + GROQ WHISPER TRANSCRIPTION
  // -------------------------------------------------------------------------

  Future<bool> startRecording() async {
    _lastRecordError = null;
    stopSpeakingSync();
    if (!kIsWeb) {
      await stopSpeaking();
    }
    if (_isRecording) return true;

    if (platform_audio.usesPlatformWebRecorder) {
      final res = await platform_audio.startWebRecording();
      if (!res.started) {
        _lastRecordError = res.errorMessage;
        return false;
      }
      _isRecording = true;
      return true;
    }

    try {
      final recorder = AudioRecorder();
      _recorder = recorder;

      final hasPerm = await recorder.hasPermission();
      if (!hasPerm) {
        _lastRecordError =
            'Microphone permission denied. Please grant Microphone access in your device settings.';
        await recorder.dispose();
        _recorder = null;
        return false;
      }

      final aacSupported = await recorder.isEncoderSupported(AudioEncoder.aacLc);
      final chosenEncoder = aacSupported ? AudioEncoder.aacLc : AudioEncoder.wav;
      _nativeRecordingExt = aacSupported ? 'm4a' : 'wav';
      final path = await platform_audio.createTempRecordingPath(
        extension: _nativeRecordingExt,
      );

      await recorder.start(
        RecordConfig(
          encoder: chosenEncoder,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
          numChannels: 1,
          sampleRate: 16000,
        ),
        path: path,
      );

      _isRecording = true;
      return true;
    } catch (e) {
      debugPrint('VoiceService startRecording error: $e');
      _lastRecordError = 'Unable to start native microphone recording.';
      await cancelRecording();
      return false;
    }
  }

  Future<VoiceTranscriptionResult> stopRecordingAndTranscribe() async {
    if (platform_audio.usesPlatformWebRecorder) {
      _isRecording = false;
      final captured = await platform_audio.stopWebRecording();
      if (captured == null || captured.bytes.length < 128) {
        return const VoiceTranscriptionResult(
          emptyClip: true,
          errorMessage:
              'Clip was too short or silent. Tap the mic, speak clearly, then tap stop.',
        );
      }
      return transcribeAudioBytes(
        captured.bytes,
        filename: captured.filename,
        mimeType: captured.mimeType,
      );
    }

    final recorder = _recorder;
    _isRecording = false;
    _recorder = null;

    if (recorder == null) {
      return const VoiceTranscriptionResult(
        emptyClip: true,
        errorMessage: 'No active microphone recording.',
      );
    }

    String? recordedPath;
    try {
      recordedPath = await recorder.stop();
    } catch (e) {
      debugPrint('VoiceService stop error: $e');
    } finally {
      try {
        await recorder.dispose();
      } catch (_) {}
    }

    if (recordedPath == null || recordedPath.trim().isEmpty) {
      return const VoiceTranscriptionResult(
        emptyClip: true,
        errorMessage: 'No audio captured. Please speak clearly and try again.',
      );
    }

    final bytes = await platform_audio.readRecordedAudioBytes(recordedPath);
    if (bytes == null || bytes.length < 128) {
      return const VoiceTranscriptionResult(
        emptyClip: true,
        errorMessage:
            'Clip was too short or silent. Tap the mic, speak clearly, then tap stop.',
      );
    }

    return transcribeAudioBytes(
      bytes,
      filename: 'speech.$_nativeRecordingExt',
    );
  }

  Future<void> cancelRecording() async {
    _isRecording = false;
    if (platform_audio.usesPlatformWebRecorder) {
      await platform_audio.cancelWebRecording();
      return;
    }
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.cancel();
      } catch (_) {}
      try {
        await recorder.dispose();
      } catch (_) {}
    }
  }

  MediaType _resolveAudioMediaType(String filename, String? mimeType) {
    final hint = (mimeType ?? '').toLowerCase();
    final ext = filename.split('.').last.toLowerCase();
    if (hint.contains('mp4') || ext == 'mp4' || ext == 'm4a') {
      return MediaType('audio', 'mp4');
    }
    if (hint.contains('wav') || ext == 'wav') {
      return MediaType('audio', 'wav');
    }
    if (hint.contains('ogg') || ext == 'ogg') {
      return MediaType('audio', 'ogg');
    }
    if (hint.contains('mpeg') || ext == 'mp3') {
      return MediaType('audio', 'mpeg');
    }
    return MediaType('audio', 'webm');
  }

  Future<VoiceTranscriptionResult> transcribeAudioBytes(
    Uint8List audioBytes, {
    String filename = 'speech.webm',
    String? mimeType,
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/api/v1/ai/transcribe'),
      );
      request.headers['Accept'] = 'application/json';
      final mediaType = _resolveAudioMediaType(filename, mimeType);

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          audioBytes,
          filename: filename,
          contentType: mediaType,
        ),
      );

      final streamed = await request.send().timeout(const Duration(seconds: 25));
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map;
        final transcript = (decoded['transcript'] ?? '').toString().trim();
        final lang = (decoded['language'] ?? 'en').toString();
        final latency = (decoded['latency_ms'] as num?)?.toDouble() ?? 0.0;
        final empty = decoded['empty_clip'] == true || transcript.isEmpty;

        return VoiceTranscriptionResult(
          transcript: transcript,
          language: lang,
          latencyMs: latency,
          emptyClip: empty,
          errorMessage: empty ? 'No speech detected in audio clip.' : null,
        );
      }

      String detail = 'Transcription failed (${response.statusCode}).';
      try {
        final err = jsonDecode(response.body);
        if (err is Map && err['detail'] is String) {
          detail = err['detail'] as String;
        }
      } catch (_) {}

      return VoiceTranscriptionResult(errorMessage: detail);
    } catch (e) {
      debugPrint('VoiceService transcribeAudioBytes error: $e');
      return const VoiceTranscriptionResult(
        errorMessage: 'Unable to reach voice transcription service.',
      );
    }
  }

  // -------------------------------------------------------------------------
  // CROSS-PLATFORM TEXT-TO-SPEECH
  // -------------------------------------------------------------------------

  Future<VoiceSpeakOutcome> speak(
    String rawText, {
    bool preferNeuralTts = false,
    double speechRate = 1.0,
    VoidCallback? onStart,
    VoidCallback? onComplete,
    VoidCallback? onAutoplayBlocked,
  }) async {
    final cleaned = cleanTextForSpeech(rawText);
    if (cleaned.isEmpty) {
      onComplete?.call();
      return const VoiceSpeakOutcome(completed: true);
    }

    // Web Fast Path: execute window.speechSynthesis synchronously in user gesture!
    if (platform_audio.usesPlatformWebSpeech) {
      _cancelSpeakRequested = false;
      final chunks = splitIntoSpeechChunks(cleaned, maxChunkLength: 160);
      final status = await platform_audio.speakWebChunks(
        chunks,
        rate: speechRate.clamp(0.7, 1.45),
        onStart: onStart,
      );
      if (status == platform_audio.VoiceAudioPlayStatus.autoplayBlocked) {
        onAutoplayBlocked?.call();
        onComplete?.call();
        return const VoiceSpeakOutcome(autoplayBlocked: true);
      }
      onComplete?.call();
      final wasStopped =
          status == platform_audio.VoiceAudioPlayStatus.stopped ||
          _cancelSpeakRequested;
      return VoiceSpeakOutcome(
        completed: !wasStopped,
        stopped: wasStopped,
      );
    }

    // Native Android / iOS / Desktop path via FlutterTts
    await stopSpeaking();
    await _initNativeTts();
    await _configureIosPlaybackSession();

    _cancelSpeakRequested = false;
    onStart?.call();

    final chunks = splitIntoSpeechChunks(cleaned, maxChunkLength: 165);
    final effectiveRate = (speechRate * 0.5).clamp(0.35, 0.75);

    try {
      await _tts.setSpeechRate(effectiveRate);
    } catch (_) {}

    for (final chunk in chunks) {
      if (_cancelSpeakRequested) break;
      final completer = Completer<void>();
      _chunkCompleter = completer;

      try {
        await _tts.speak(chunk, focus: true);
        if (!completer.isCompleted) {
          final maxWaitMs = (chunk.length * 105).clamp(3000, 18000);
          await completer.future.timeout(
            Duration(milliseconds: maxWaitMs),
            onTimeout: () {
              if (!completer.isCompleted) completer.complete();
            },
          );
        }
      } catch (e) {
        debugPrint('Native TTS speak chunk error: $e');
      } finally {
        _chunkCompleter = null;
      }
    }

    onComplete?.call();
    return VoiceSpeakOutcome(
      completed: !_cancelSpeakRequested,
      stopped: _cancelSpeakRequested,
    );
  }

  void stopSpeakingSync() {
    _cancelSpeakRequested = true;
    final c = _chunkCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _chunkCompleter = null;
    platform_audio.stopWebSpeechSync();
  }

  Future<void> stopSpeaking() async {
    stopSpeakingSync();
    await platform_audio.stopWavAudioPlatform();
    if (!kIsWeb) {
      try {
        await _tts.stop();
      } catch (_) {}
    }
  }
}
