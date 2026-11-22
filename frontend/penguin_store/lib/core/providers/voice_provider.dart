import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:penguin_store/core/services/voice_service.dart';

/// Global Voice Preferences & Live Speech State Provider (Phase 2 & Voice Concierge).
class VoiceProvider with ChangeNotifier {
  static const String _keyVoiceEnabled = 'penguin_voice_enabled_v1';
  static const String _keyAutoOrder = 'penguin_voice_auto_order_v1';
  static const String _keyAutoCtrlX = 'penguin_voice_auto_ctrlx_v2';
  static const String _keyRatePreset = 'penguin_voice_rate_preset_v1';

  final VoiceService _voice = VoiceService.instance;
  final String conciergeThreadId = const Uuid().v4();

  bool _voiceEnabled = true;
  bool _autoSpeakOrderConfirmation = true;
  bool _autoSpeakCtrlX = true;
  String _speechRatePreset = 'Normal'; // 'Slow' | 'Normal' | 'Fast'

  bool _isRecording = false;
  bool _isTranscribing = false;
  bool _isSpeaking = false;
  bool _autoplayBlocked = false;
  bool _suppressNextRouteStop = false;
  double _lastSttLatencyMs = 0.0;
  String? _activeLabel;
  String? _lastError;

  VoiceProvider() {
    _loadPrefs();
  }

  bool get voiceEnabled => _voiceEnabled;
  bool get autoSpeakOrderConfirmation => _autoSpeakOrderConfirmation;
  bool get autoSpeakCtrlX => _autoSpeakCtrlX;
  String get speechRatePreset => _speechRatePreset;

  bool get isRecording => _isRecording;
  bool get isTranscribing => _isTranscribing;
  bool get isSpeaking => _isSpeaking;
  bool get autoplayBlocked => _autoplayBlocked;
  double get lastSttLatencyMs => _lastSttLatencyMs;
  String? get activeLabel => _activeLabel;
  String? get lastError => _lastError;

  void markNavigationConfirmation() {
    _suppressNextRouteStop = true;
  }

  bool consumeSuppressRouteStop() {
    final val = _suppressNextRouteStop;
    _suppressNextRouteStop = false;
    return val;
  }

  double get speechRateMultiplier {
    switch (_speechRatePreset) {
      case 'Slow':
        return 0.85;
      case 'Fast':
        return 1.18;
      default:
        return 1.0;
    }
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _voiceEnabled = prefs.getBool(_keyVoiceEnabled) ?? true;
      _autoSpeakOrderConfirmation = prefs.getBool(_keyAutoOrder) ?? true;
      _autoSpeakCtrlX = prefs.getBool(_keyAutoCtrlX) ?? true;
      final savedRate = prefs.getString(_keyRatePreset) ?? 'Normal';
      if (const {'Slow', 'Normal', 'Fast'}.contains(savedRate)) {
        _speechRatePreset = savedRate;
      }
      notifyListeners();
    } catch (_) {}
  }

  /// Synchronously unlocks speech synthesis inside a user gesture handler so
  /// delayed async responses (CTRL-X / checkout) are permitted to speak.
  void primeSpeech() => _voice.primeSpeechOnUserGesture();

  Future<VoiceSpeakOutcome> testVoice() {
    return speakText(
      'Hello! Penguin Store voice assistant is ready and working clearly.',
      label: 'Voice Check',
      forceEvenIfMuted: true,
    );
  }

  Future<void> setVoiceEnabled(bool value) async {
    _voiceEnabled = value;
    if (value) {
      _voice.primeSpeechOnUserGesture();
    } else {
      await stopSpeaking();
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyVoiceEnabled, value);
    } catch (_) {}
  }

  Future<void> toggleVoiceEnabled() => setVoiceEnabled(!_voiceEnabled);

  Future<void> setAutoSpeakOrderConfirmation(bool value) async {
    _autoSpeakOrderConfirmation = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAutoOrder, value);
    } catch (_) {}
  }

  Future<void> setAutoSpeakCtrlX(bool value) async {
    _autoSpeakCtrlX = value;
    if (value) {
      _voice.primeSpeechOnUserGesture();
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAutoCtrlX, value);
    } catch (_) {}
  }

  Future<void> setSpeechRatePreset(String preset) async {
    if (!const {'Slow', 'Normal', 'Fast'}.contains(preset)) return;
    _speechRatePreset = preset;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyRatePreset, preset);
    } catch (_) {}
  }

  /// Toggles microphone recording:
  /// - First call starts recording and returns `null`.
  /// - Second call stops recording, releases browser mic tracks immediately,
  ///   transcribes via Groq Whisper (`/api/v1/ai/transcribe`), and returns the transcript.
  Future<String?> toggleRecordingAndTranscribe({BuildContext? context}) async {
    if (_isTranscribing) return null;
    _lastError = null;
    _voice.primeSpeechOnUserGesture();

    if (!_isRecording) {
      final started = await _voice.startRecording();
      if (!started) {
        _isRecording = false;
        _lastError =
            _voice.lastRecordError ??
            'Microphone access was denied or unavailable. Enable mic permission in your browser/device settings.';
        notifyListeners();
        if (context != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_lastError!),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return null;
      }
      _isRecording = true;
      notifyListeners();
      return null;
    }

    _isRecording = false;
    _isTranscribing = true;
    notifyListeners();

    final result = await _voice.stopRecordingAndTranscribe();
    _isTranscribing = false;
    _lastSttLatencyMs = result.latencyMs;

    if (result.hasError && !result.hasTranscript) {
      _lastError = result.errorMessage;
      notifyListeners();
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.errorMessage!),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return null;
    }

    notifyListeners();
    return result.transcript;
  }

  Future<bool> startListeningBargeIn({BuildContext? context}) async {
    if (_isTranscribing) return false;
    _lastError = null;
    _voice.primeSpeechOnUserGesture();
    if (_isSpeaking) {
      await stopSpeaking();
    }
    if (_isRecording) return true;
    final started = await _voice.startRecording();
    if (!started) {
      _lastError =
          _voice.lastRecordError ??
          'Microphone access was denied or unavailable. You can type below instead.';
      notifyListeners();
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_lastError!),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }
    _isRecording = true;
    notifyListeners();
    return true;
  }

  Future<void> cancelRecording() async {
    _isRecording = false;
    _isTranscribing = false;
    await _voice.cancelRecording();
    notifyListeners();
  }

  Future<VoiceSpeakOutcome> speakText(
    String text, {
    String label = 'Speaking...',
    bool preferNeural = false,
    bool forceEvenIfMuted = false,
  }) async {
    if (!forceEvenIfMuted && !_voiceEnabled) {
      return const VoiceSpeakOutcome();
    }

    if (forceEvenIfMuted) {
      _voice.primeSpeechOnUserGesture();
    }

    _autoplayBlocked = false;
    _activeLabel = label;

    return _voice.speak(
      text,
      preferNeuralTts: preferNeural,
      speechRate: speechRateMultiplier,
      onStart: () {
        _isSpeaking = true;
        notifyListeners();
      },
      onComplete: () {
        _isSpeaking = false;
        _activeLabel = null;
        notifyListeners();
      },
      onAutoplayBlocked: () {
        _autoplayBlocked = true;
        _isSpeaking = false;
        _activeLabel = null;
        notifyListeners();
      },
    );
  }

  Future<VoiceSpeakOutcome> speakOrderConfirmation({
    required String orderId,
    required String formattedTotal,
    required bool isStripe,
    bool force = false,
  }) async {
    if (!force && (!_voiceEnabled || !_autoSpeakOrderConfirmation)) {
      return const VoiceSpeakOutcome();
    }

    final script = isStripe
        ? 'Payment confirmed! Thank you for shopping at Penguin Store. '
            'Your order #$orderId for $formattedTotal has been placed successfully. '
            'Your confirmation receipt has been sent to your email.'
        : 'Order placed successfully! Your Cash on Delivery order #$orderId '
            'for $formattedTotal is confirmed.';

    return speakText(
      script,
      label: 'Order #$orderId Receipt',
      preferNeural: true,
      forceEvenIfMuted: force,
    );
  }

  Future<void> stopSpeaking() async {
    await _voice.stopSpeaking();
    _isSpeaking = false;
    _activeLabel = null;
    notifyListeners();
  }
}
