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

/// Centralized, singleton-backed Voice Intelligence Engine (Phase 2).
///
/// Handles:
/// - Cross-platform microphone recording (echo cancellation + noise suppression)
///   uploading to `POST /api/v1/ai/transcribe` (Groq Whisper `whisper-large-v3-turbo`)
/// - Hybrid Text-to-Speech: Groq Orpheus Neural WAV (`POST /api/v1/ai/speak`) for short
///   announcements + `FlutterTts` with <=165-char sentence chunking to avoid Web cutoff.
class VoiceService {
  VoiceService._() {
    _initTts();
  }

  static final VoiceService instance = VoiceService._();

  final FlutterTts _tts = FlutterTts();
  AudioRecorder? _recorder;

  bool _ttsInitialized = false;
  bool _isRecording = false;
  bool _cancelSpeakRequested = false;
  Completer<void>? _chunkCompleter;

  bool get isRecording => _isRecording;

  static String get _base =>
      ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

  Future<void> _initTts() async {
    if (_ttsInitialized) return;
    _ttsInitialized = true;
    try {
      await _tts.setLanguage('en-US');
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(true);
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

  /// Strips Markdown, URLs, and symbols, and formats Order IDs and currencies
  /// so TTS reads naturally.
  static String cleanTextForSpeech(String raw) {
    var text = raw;

    // Remove fenced code blocks & markdown links
    text = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (m) => m.group(1) ?? '',
    );
    text = text.replaceAll(RegExp(r'https?://\S+'), '');

    // Format Order IDs like #PS-4829 or Order #144 -> spaced characters/digits
    text = text.replaceAllMapped(
      RegExp(r'(?:Order\s*#\s*|#)([A-Za-z0-9-]+)', caseSensitive: false),
      (m) {
        final token = (m.group(1) ?? '').replaceAll('-', ' ');
        final spaced = token.split('').join(' ');
        return 'order number $spaced';
      },
    );

    // Format USD prices: $1,299.00 -> 1,299 dollars; $24.50 -> 24 dollars and 50 cents
    text = text.replaceAllMapped(
      RegExp(r'\$\s*([0-9][0-9,]*)(?:\.(\d{2}))?'),
      (m) {
        final whole = m.group(1) ?? '0';
        final cents = m.group(2);
        if (cents == null || cents == '00') {
          return '$whole dollars';
        }
        return '$whole dollars and $cents cents';
      },
    );

    // Format EUR and PKR
    text = text.replaceAllMapped(
      RegExp(r'€\s*([0-9][0-9,]*(?:\.\d{2})?)'),
      (m) => '${m.group(1)} euros',
    );
    text = text.replaceAllMapped(
      RegExp(r'Rs\.?\s*([0-9][0-9,]*)'),
      (m) => '${m.group(1)} rupees',
    );

    // Friendly symbol replacements & Markdown stripping
    text = text.replaceAll('★', ' star ');
    text = text.replaceAll('&', ' and ');
    text = text.replaceAll('•', '. ');
    text = text.replaceAll('🔊', ' ');
    text = text.replaceAll('⏹', ' ');
    text = text.replaceAll('✓', ' ');
    text = text.replaceAll(RegExp(r'[*_#`~|>]+'), ' ');
    text = text.replaceAll(RegExp(r'\n+'), '. ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  /// Splits text into crisp chunks (`<= maxChunkLength` chars) at sentence
  /// boundaries so Chrome `speechSynthesis` never truncates long utterances.
  static List<String> splitIntoSpeechChunks(
    String cleanedText, {
    int maxChunkLength = 165,
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
        // Split long sentence by comma or word boundary
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
    await stopSpeaking();
    if (_isRecording) return true;

    try {
      final recorder = AudioRecorder();
      _recorder = recorder;

      final hasPerm = await recorder.hasPermission();
      if (!hasPerm) {
        await recorder.dispose();
        _recorder = null;
        return false;
      }

      final path = await platform_audio.createTempRecordingPath();
      final encoder = kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc;
      final supported = await recorder.isEncoderSupported(encoder);

      await recorder.start(
        RecordConfig(
          encoder: supported ? encoder : AudioEncoder.wav,
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
      await cancelRecording();
      return false;
    }
  }

  Future<VoiceTranscriptionResult> stopRecordingAndTranscribe() async {
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
        errorMessage: 'Clip was too short or silent. Tap the mic and speak.',
      );
    }

    return transcribeAudioBytes(
      bytes,
      filename: kIsWeb ? 'speech.webm' : 'speech.m4a',
    );
  }

  Future<void> cancelRecording() async {
    _isRecording = false;
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

  Future<VoiceTranscriptionResult> transcribeAudioBytes(
    Uint8List audioBytes, {
    String filename = 'speech.webm',
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/api/v1/ai/transcribe'),
      );
      request.headers['Accept'] = 'application/json';
      final ext = filename.split('.').last.toLowerCase();
      final mime = ext == 'wav'
          ? MediaType('audio', 'wav')
          : (ext == 'm4a'
                ? MediaType('audio', 'mp4')
                : MediaType('audio', 'webm'));

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          audioBytes,
          filename: filename,
          contentType: mime,
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
  // HYBRID TEXT-TO-SPEECH (GROQ ORPHEUS WAV + FLUTTER_TTS CHUNKED)
  // -------------------------------------------------------------------------

  Future<VoiceSpeakOutcome> speak(
    String rawText, {
    bool preferNeuralTts = false,
    double speechRate = 1.0,
    VoidCallback? onStart,
    VoidCallback? onComplete,
    VoidCallback? onAutoplayBlocked,
  }) async {
    await stopSpeaking();
    await _initTts();

    final cleaned = cleanTextForSpeech(rawText);
    if (cleaned.isEmpty) {
      onComplete?.call();
      return const VoiceSpeakOutcome(completed: true);
    }

    _cancelSpeakRequested = false;
    onStart?.call();

    // 1. Optional Expressive Neural TTS for short announcements (<= 195 chars)
    if (preferNeuralTts && cleaned.length <= 195) {
      try {
        final res = await http
            .post(
              Uri.parse('$_base/api/v1/ai/speak'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'text': cleaned, 'voice': 'troy'}),
            )
            .timeout(const Duration(seconds: 4));

        if (_cancelSpeakRequested) {
          onComplete?.call();
          return const VoiceSpeakOutcome(stopped: true);
        }

        final contentType = res.headers['content-type'] ?? '';
        if (res.statusCode == 200 &&
            contentType.contains('audio/wav') &&
            res.bodyBytes.length > 44) {
          final status = await platform_audio.playWavBytesPlatform(
            res.bodyBytes,
          );
          if (status == platform_audio.VoiceAudioPlayStatus.autoplayBlocked) {
            onAutoplayBlocked?.call();
            onComplete?.call();
            return const VoiceSpeakOutcome(autoplayBlocked: true);
          }
          if (status == platform_audio.VoiceAudioPlayStatus.completed) {
            onComplete?.call();
            return const VoiceSpeakOutcome(
              completed: true,
              usedNeuralTts: true,
            );
          }
          if (status == platform_audio.VoiceAudioPlayStatus.stopped) {
            onComplete?.call();
            return const VoiceSpeakOutcome(stopped: true);
          }
        }
      } catch (_) {
        // Silently fall back to FlutterTts
      }
    }

    // 2. Client/Browser FlutterTts with sentence chunking (<= 165 chars each)
    final chunks = splitIntoSpeechChunks(cleaned);
    // Normalize rate into flutter_tts range (Web 0.5–1.5; Native 0.4–0.65)
    final effectiveRate = kIsWeb
        ? speechRate.clamp(0.65, 1.45)
        : (speechRate * 0.5).clamp(0.35, 0.75);

    try {
      await _tts.setSpeechRate(effectiveRate);
    } catch (_) {}

    for (final chunk in chunks) {
      if (_cancelSpeakRequested) break;
      final completer = Completer<void>();
      _chunkCompleter = completer;

      try {
        final speakResult = await _tts.speak(chunk);
        // If platform returned synchronously or error (e.g. Web autoplay blocked without gesture)
        if (!completer.isCompleted) {
          // Wait up to a reasonable ceiling for this chunk so it can't hang forever
          final maxWaitMs = (chunk.length * 95).clamp(2500, 16000);
          await completer.future.timeout(
            Duration(milliseconds: maxWaitMs),
            onTimeout: () {
              if (!completer.isCompleted) completer.complete();
            },
          );
        }
        if (speakResult == 0 && kIsWeb && chunks.first == chunk) {
          onAutoplayBlocked?.call();
          onComplete?.call();
          return const VoiceSpeakOutcome(autoplayBlocked: true);
        }
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('notallowed') || msg.contains('autoplay')) {
          onAutoplayBlocked?.call();
          onComplete?.call();
          return const VoiceSpeakOutcome(autoplayBlocked: true);
        }
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

  Future<void> stopSpeaking() async {
    _cancelSpeakRequested = true;
    final c = _chunkCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _chunkCompleter = null;
    await platform_audio.stopWavAudioPlatform();
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
