import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/core/routing/app_router.dart';
import 'package:penguin_store/core/services/voice_action_dispatcher.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

enum ConciergeStatus { idle, listening, queryingDb, deciding, speaking }

/// App-wide overlay hosted inside `MaterialApp.router(builder: ...)`.
/// Provides:
///  1. Floating speaking/transcribing bar with one-tap Stop across every screen.
///  2. Sleek pulsing **Penguin Voice Concierge Orb** floating cleanly above
///     bottom chrome on storefront views, launching the interactive Voice Sheet.
///  3. Static `GlobalVoiceOverlay.openConcierge(...)` entry point so search bar
///     "Voice AI" pills on Home and Discover can launch the Concierge directly.
class GlobalVoiceOverlay extends StatefulWidget {
  const GlobalVoiceOverlay({super.key});

  static _GlobalVoiceOverlayState? _activeInstance;

  /// Opens the Penguin Voice Concierge sheet from anywhere in the app (such as
  /// the glowing "Voice AI" pill in the Home or Discover search bars).
  static Future<void> openConcierge({
    String? initialQuery,
    bool autoStartMic = false,
  }) async {
    final instance = _activeInstance;
    if (instance != null && instance.mounted) {
      await instance._openConciergeSheet(
        initialQuery: initialQuery,
        autoStartMic: autoStartMic,
      );
    }
  }

  @override
  State<GlobalVoiceOverlay> createState() => _GlobalVoiceOverlayState();
}

class _GlobalVoiceOverlayState extends State<GlobalVoiceOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  String _currentRoute = '/splash';
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    GlobalVoiceOverlay._activeInstance = this;
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..repeat(reverse: true);

    appRouter.routerDelegate.addListener(_onRouteChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncRoute();
    });
  }

  @override
  void dispose() {
    if (GlobalVoiceOverlay._activeInstance == this) {
      GlobalVoiceOverlay._activeInstance = null;
    }
    appRouter.routerDelegate.removeListener(_onRouteChanged);
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _syncRoute() {
    if (!mounted) return;
    final nextPath = appRouter.routerDelegate.currentConfiguration.uri.path;
    if (nextPath != _currentRoute) {
      setState(() => _currentRoute = nextPath);
    }
  }

  void _onRouteChanged() {
    final nextPath = appRouter.routerDelegate.currentConfiguration.uri.path;
    if (nextPath != _currentRoute) {
      final voice = context.read<VoiceProvider>();
      // Stop stale TTS cleanly across manual route switches, unless a voice
      // concierge confirmation explicitly initiated this navigation.
      if (!voice.consumeSuppressRouteStop() && voice.isSpeaking) {
        voice.stopSpeaking();
      }
      if (mounted) {
        setState(() => _currentRoute = nextPath);
      }
    }
  }

  bool get _shouldShowOrb {
    if (_sheetOpen) return false;
    const hiddenExact = {
      '/splash',
      '/login',
      '/admin',
      '/ctrlx',
      '/checkout-success',
      '/success',
      '/checkout-cancel',
      '/cancel',
    };
    return !hiddenExact.contains(_currentRoute);
  }

  Future<void> _openConciergeSheet({
    String? initialQuery,
    bool autoStartMic = false,
  }) async {
    final navContext = rootNavigatorKey.currentContext;
    if (navContext == null || _sheetOpen) return;

    final voice = context.read<VoiceProvider>();
    voice.primeSpeech();
    final screenContext = VoiceActionDispatcher.collectScreenContext(
      navContext,
      currentRoute: _currentRoute,
    );

    setState(() => _sheetOpen = true);
    try {
      await showModalBottomSheet<void>(
        context: navContext,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => PenguinVoiceConciergeSheet(
          screenContext: screenContext,
          initialQuery: initialQuery,
          autoStartMic: autoStartMic,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sheetOpen = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isElevatedBottom =
        _currentRoute.startsWith('/product/') || _currentRoute == '/cart';
    final double orbBottom = isElevatedBottom ? 148.0 : 84.0;

    return Consumer<VoiceProvider>(
      builder: (context, voice, _) {
        final colors = Theme.of(context).colorScheme;
        return Stack(
          children: [
            // Speaking / Transcribing status bar
            if (voice.isSpeaking || voice.isTranscribing)
              Positioned(
                left: 16,
                bottom: orbBottom,
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(999),
                  color: colors.inverseSurface,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          voice.isTranscribing
                              ? Icons.graphic_eq_rounded
                              : Icons.volume_up_rounded,
                          color: const Color(0xFF00E5FF),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          voice.isTranscribing
                              ? 'Transcribing speech...'
                              : (voice.activeLabel ?? 'Speaking...'),
                          style: TextStyle(
                            color: colors.onInverseSurface,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (voice.isSpeaking) ...[
                          const SizedBox(width: 10),
                          InkWell(
                            onTap: voice.stopSpeaking,
                            borderRadius: BorderRadius.circular(999),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                'Stop',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

            // Floating Penguin Voice Concierge Orb
            if (_shouldShowOrb)
              Positioned(
                right: 16,
                bottom: orbBottom,
                child: AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (context, child) {
                    final glow = 0.28 + (_pulseCtrl.value * 0.25);
                    final scale = 1.0 + (_pulseCtrl.value * 0.045);
                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: (voice.isSpeaking || voice.isRecording
                                      ? const Color(0xFF00E5FF)
                                      : const Color(0xFF1E88E5))
                                  .withValues(alpha: glow),
                              blurRadius: 18,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: Semantics(
                    label: 'Open Penguin Voice Concierge',
                    button: true,
                    child: Material(
                      elevation: 10,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _openConciergeSheet(),
                        child: Ink(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFF0D47A1),
                                Color(0xFF1E88E5),
                                Color(0xFF00ACC1),
                              ],
                            ),
                          ),
                          child: Center(
                            child: Icon(
                              voice.isSpeaking
                                  ? Icons.graphic_eq_rounded
                                  : Icons.mic_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class PenguinVoiceConciergeSheet extends StatefulWidget {
  final Map<String, dynamic> screenContext;
  final String? initialQuery;
  final bool autoStartMic;

  const PenguinVoiceConciergeSheet({
    super.key,
    required this.screenContext,
    this.initialQuery,
    this.autoStartMic = false,
  });

  @override
  State<PenguinVoiceConciergeSheet> createState() =>
      _PenguinVoiceConciergeSheetState();
}

class _PenguinVoiceConciergeSheetState extends State<PenguinVoiceConciergeSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveCtrl;
  final TextEditingController _textCtrl = TextEditingController();

  ConciergeStatus _status = ConciergeStatus.idle;
  bool _handsFreeMode = false;
  String _userTranscript = '';
  String _visualReply =
      'Ask me to pick the best product based on real reviews, compare top items, apply the best coupon to your cart, draft a B2B wholesale quote, or open a 3D preview.';
  String _spokenSummary = '';
  String _routedAgent = 'Penguin Voice Concierge';
  List<Map<String, dynamic>> _reasoningSteps = const [];
  List<Map<String, dynamic>> _executedActions = const [];
  final Set<String> _undoneActionIds = <String>{};
  Map<String, dynamic>? _decisionCard;
  Map<String, dynamic>? _pendingConfirmation;
  List<Product> _products = const [];
  Map<String, dynamic>? _comparison;
  String? _executedActionBanner;

  List<String> get _contextQuickChips {
    final route = (widget.screenContext['current_route'] ?? '/').toString();
    final viewingPid = widget.screenContext['viewing_product_id'];
    if (viewingPid != null || route.startsWith('/product/')) {
      return const [
        'Is this worth buying and can I see it in 3D?',
        'Compare with a cheaper alternative',
        'What is the B2B bulk price for 20 units?',
        'Draft a wholesale quote for 30 units of this item',
        'Add this to my cart',
      ];
    }
    if (route == '/cart') {
      return const [
        'Apply the best coupon to my cart and tell me my final total',
        'Compare the top two products in the store',
        'Check my latest order status',
        'Go to checkout',
      ];
    }
    if (route == '/orders') {
      return const [
        'Check my latest order status',
        'What is your return and refund policy?',
        'Pick the best headphones under 350 dollars and add to cart',
      ];
    }
    return const [
      'Pick the best headphones under \$350 based on real reviews and add it to my cart',
      'Compare the top two products in the store',
      'Apply the best coupon to my cart and tell me my final total',
      'Check my latest order status',
      'Draft a wholesale quote for 30 units of product #144',
    ];
  }

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final initQ = widget.initialQuery?.trim();
      if (initQ != null && initQ.isNotEmpty) {
        _submitQuery(initQ, isVoice: true);
      } else if (widget.autoStartMic) {
        _onCentralOrbTap();
      }
    });
  }

  @override
  void dispose() {
    _waveCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _onCentralOrbTap() async {
    final voice = context.read<VoiceProvider>();
    voice.primeSpeech();

    // Instant Barge-In: interrupt speaking and immediately start listening
    if (voice.isSpeaking) {
      final started = await voice.startListeningBargeIn(context: context);
      if (mounted) {
        setState(() {
          _status = started ? ConciergeStatus.listening : ConciergeStatus.idle;
        });
      }
      return;
    }

    if (voice.isRecording) {
      // Stop recording -> Whisper STT -> Send to Voice Concierge Agent
      setState(() => _status = ConciergeStatus.queryingDb);
      final transcript = await voice.toggleRecordingAndTranscribe(
        context: context,
      );
      if (!mounted) return;
      if (transcript == null || transcript.trim().isEmpty) {
        setState(() => _status = ConciergeStatus.idle);
        return;
      }
      await _submitQuery(
        transcript.trim(),
        isVoice: true,
        sttLatencyMs: voice.lastSttLatencyMs,
      );
      return;
    }

    // Idle -> Start Listening immediately
    final started = await voice.startListeningBargeIn(context: context);
    if (mounted) {
      setState(() {
        _status = started ? ConciergeStatus.listening : ConciergeStatus.idle;
      });
    }
  }

  Future<void> _submitQuery(
    String query, {
    bool isVoice = false,
    double? sttLatencyMs,
    bool confirmPendingAction = false,
  }) async {
    final clean = query.trim();
    if (clean.isEmpty) return;

    final voice = context.read<VoiceProvider>();
    voice.primeSpeech();
    if (voice.isSpeaking) {
      await voice.stopSpeaking();
    }

    if (!mounted) return;
    final liveScreenCtx = VoiceActionDispatcher.collectScreenContext(
      context,
      currentRoute:
          (widget.screenContext['current_route'] ?? '/').toString(),
    );

    setState(() {
      _userTranscript = clean;
      _status = ConciergeStatus.queryingDb;
      _executedActionBanner = null;
    });

    // Brief transition from Querying Database -> Deciding so user sees live multi-phase progress
    Future<void>.delayed(const Duration(milliseconds: 360), () {
      if (mounted && _status == ConciergeStatus.queryingDb) {
        setState(() => _status = ConciergeStatus.deciding);
      }
    });

    try {
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      final res = await http
          .post(
            Uri.parse('$base/api/agent/chat'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'user_input': clean,
              'thread_id': voice.conciergeThreadId,
              'current_route': liveScreenCtx['current_route'],
              'viewing_product_id':
                  widget.screenContext['viewing_product_id'] ??
                      liveScreenCtx['viewing_product_id'],
              'cart_item_count': liveScreenCtx['cart_item_count'],
              'cart_total': liveScreenCtx['cart_total'],
              'cart_items': liveScreenCtx['cart_items'],
              'pending_confirmation': _pendingConfirmation,
              'confirm_pending_action': confirmPendingAction,
              'is_voice': isVoice,
              'stt_latency_ms': sttLatencyMs,
              'voice_transcript': isVoice ? clean : null,
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (!mounted) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map;
        final reply = (data['reply'] ?? data['response'] ?? '').toString();
        final spoken = (data['spoken_summary'] ?? reply).toString();
        final routed = (data['routed_agent'] ?? 'CTRL-X').toString();

        final rawProducts =
            (data['products'] ?? data['suggested_products']) as List? ??
                const [];
        final parsedProducts = rawProducts
            .whereType<Map>()
            .map(
              (p) => Product(
                id: (p['id'] as num?)?.toInt() ?? 0,
                name: (p['name'] ?? 'Product').toString(),
                price: (p['price'] as num?)?.toDouble() ?? 0.0,
                originalPrice: (p['original_price'] as num?)?.toDouble(),
                category: (p['category'] ?? 'CATALOG').toString(),
                isFeatured: p['is_featured'] == true,
                discountPercent: (p['discount_percent'] as num?)?.toInt(),
                imageUrl: Product.resolveImageUrl(p['image_url']?.toString()),
                description: (p['description'] ?? '').toString(),
                rating: ((p['trust_score'] ??
                            p['trust_weighted_rating'] ??
                            p['rating']) as num?)
                        ?.toDouble() ??
                    4.8,
                reviews: (p['reviews'] as num?)?.toInt() ?? 12,
                stock: (p['stock'] as num?)?.toInt() ?? 50,
              ),
            )
            .toList();

        final rawSteps =
            (data['reasoning_trace'] ?? data['reasoning_steps']) as List? ??
                const [];
        final parsedSteps = rawSteps
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();

        final cmpMap = data['comparison'] is Map
            ? Map<String, dynamic>.from(data['comparison'] as Map)
            : null;
        final decisionCardMap = data['decision_card'] is Map
            ? Map<String, dynamic>.from(data['decision_card'] as Map)
            : null;
        final pendingConfirmMap = data['pending_confirmation'] is Map
            ? Map<String, dynamic>.from(data['pending_confirmation'] as Map)
            : null;

        final clientAction = data['client_action'] is Map
            ? Map<String, dynamic>.from(data['client_action'] as Map)
            : null;
        final clientActionsList = data['client_actions'] as List?;

        final rawExecActions = data['executed_actions'] as List? ?? const [];
        final parsedExecActions = rawExecActions
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();

        bool navigatedAway = false;
        final actionLabels = await VoiceActionDispatcher.dispatchAll(
          context,
          clientActionsList,
          fallbackSingleAction: clientAction,
          closeOverlayBeforeNav: () {
            navigatedAway = true;
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        );
        final String? actionNote =
            actionLabels.isNotEmpty ? actionLabels.join(' • ') : null;

        if (spoken.trim().isNotEmpty) {
          if (mounted) {
            setState(() {
              _visualReply = reply;
              _spokenSummary = spoken;
              _routedAgent = routed;
              _products = parsedProducts;
              _comparison = cmpMap;
              _decisionCard = decisionCardMap;
              _pendingConfirmation = pendingConfirmMap;
              _reasoningSteps = parsedSteps;
              _executedActions = parsedExecActions;
              _executedActionBanner = actionNote;
              _status = ConciergeStatus.speaking;
            });
          }
          await voice.speakText(
            spoken,
            label: 'Penguin Concierge',
            forceEvenIfMuted: isVoice,
          );
          if (mounted && _status == ConciergeStatus.speaking) {
            setState(() => _status = ConciergeStatus.idle);
            // Hands-Free Continuous Conversation Mode: auto-resume listening
            if (_handsFreeMode &&
                !navigatedAway &&
                _pendingConfirmation == null) {
              await Future<void>.delayed(const Duration(milliseconds: 550));
              if (mounted &&
                  _handsFreeMode &&
                  !voice.isRecording &&
                  !voice.isSpeaking) {
                await _onCentralOrbTap();
              }
            }
          }
        } else if (mounted) {
          setState(() {
            _visualReply = reply;
            _spokenSummary = spoken;
            _routedAgent = routed;
            _products = parsedProducts;
            _comparison = cmpMap;
            _decisionCard = decisionCardMap;
            _pendingConfirmation = pendingConfirmMap;
            _reasoningSteps = parsedSteps;
            _executedActions = parsedExecActions;
            _executedActionBanner = actionNote;
            _status = ConciergeStatus.idle;
          });
        }
      } else {
        setState(() {
          _visualReply =
              'Concierge server returned ${res.statusCode}. Please try again.';
          _status = ConciergeStatus.idle;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _visualReply =
              'Unable to reach Penguin Voice Concierge right now. Check your connection.';
          _status = ConciergeStatus.idle;
        });
      }
    }
  }

  Future<void> _handleUndoAction(Map<String, dynamic> execAction) async {
    final actId = (execAction['action_id'] ?? '').toString();
    final undoneLabel = await VoiceActionDispatcher.undoExecutedAction(
      context,
      execAction,
    );
    if (!mounted) return;
    setState(() {
      if (actId.isNotEmpty) {
        _undoneActionIds.add(actId);
      }
      _executedActionBanner =
          undoneLabel != null ? 'Undone: $undoneLabel' : 'Action undone';
    });
  }

  String _statusHeadline(VoiceProvider voice) {
    if (voice.isRecording || _status == ConciergeStatus.listening) {
      return 'Listening... Tap orb to send';
    }
    if (voice.isTranscribing || _status == ConciergeStatus.queryingDb) {
      return 'Querying Live Supabase Database...';
    }
    if (_status == ConciergeStatus.deciding) {
      return 'Deciding • Scoring Trust & Pricing...';
    }
    if (voice.isSpeaking || _status == ConciergeStatus.speaking) {
      return 'Speaking • Tap orb to interrupt (barge-in)';
    }
    return _handsFreeMode
        ? 'Hands-Free Active • Tap orb to speak'
        : 'Tap the glowing orb to speak';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final voice = context.watch<VoiceProvider>();
    final currency = context.watch<CurrencyProvider>();
    final int? viewingPid = widget.screenContext['viewing_product_id'] as int?;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    final bool activeWave = voice.isRecording ||
        voice.isSpeaking ||
        _status == ConciergeStatus.queryingDb ||
        _status == ConciergeStatus.deciding;

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.97),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.25),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
            blurRadius: 28,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.90,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.outlineVariant,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Header row + Hands-Free Continuous Conversation toggle
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1E88E5), Color(0xFF00ACC1)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Penguin Voice Concierge',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: colors.onSurface,
                          ),
                        ),
                        Text(
                          viewingPid != null
                              ? 'Context-aware • Viewing Product #$viewingPid'
                              : '$_routedAgent • Live Supabase Autonomous Agent',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Hands-Free Continuous Mode Toggle Pill
                  FilterChip(
                    selected: _handsFreeMode,
                    onSelected: (val) {
                      setState(() => _handsFreeMode = val);
                      CustomToast.show(
                        context,
                        val
                            ? 'Hands-Free Continuous Conversation Mode ON'
                            : 'Hands-Free Mode OFF',
                      );
                    },
                    label: Text(
                      _handsFreeMode ? 'Hands-Free ON' : 'Hands-Free',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: _handsFreeMode
                            ? Colors.white
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    selectedColor: const Color(0xFF1E88E5),
                    checkmarkColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                  if (voice.isSpeaking)
                    IconButton(
                      tooltip: 'Stop Speech',
                      onPressed: () {
                        voice.stopSpeaking();
                        setState(() => _status = ConciergeStatus.idle);
                      },
                      icon: Icon(Icons.stop_circle_rounded, color: colors.error),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 4-Phase Status Pipeline Bar: Listening -> Querying DB -> Deciding -> Speaking
              _buildPhaseStatusPills(voice, colors),
              const SizedBox(height: 12),

              // Animated Reactive Visualizer + Central Barge-In Orb
              Center(
                child: GestureDetector(
                  onTap: _onCentralOrbTap,
                  child: AnimatedBuilder(
                    animation: _waveCtrl,
                    builder: (context, _) {
                      final t = _waveCtrl.value;
                      final outerSize =
                          activeWave ? (104.0 + t * 18.0) : 100.0;
                      final ringColor = voice.isRecording
                          ? colors.error
                          : (_status == ConciergeStatus.queryingDb ||
                                  _status == ConciergeStatus.deciding
                              ? Colors.amber
                              : const Color(0xFF00E5FF));
                      return SizedBox(
                        width: 126,
                        height: 126,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: outerSize,
                              height: outerSize,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: ringColor.withValues(
                                  alpha:
                                      activeWave ? (0.16 + t * 0.14) : 0.08,
                                ),
                                border: Border.all(
                                  color: ringColor.withValues(alpha: 0.45),
                                  width: 2,
                                ),
                              ),
                            ),
                            Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: voice.isRecording
                                      ? [colors.error, Colors.deepOrange]
                                      : const [
                                          Color(0xFF0D47A1),
                                          Color(0xFF1E88E5),
                                          Color(0xFF00ACC1),
                                        ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: ringColor.withValues(alpha: 0.35),
                                    blurRadius: 18,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: Center(
                                child: (_status == ConciergeStatus.queryingDb ||
                                        _status == ConciergeStatus.deciding)
                                    ? const SizedBox(
                                        width: 26,
                                        height: 26,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.8,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Icon(
                                        voice.isRecording
                                            ? Icons.stop_rounded
                                            : (voice.isSpeaking
                                                ? Icons.graphic_eq_rounded
                                                : Icons.mic_rounded),
                                        color: Colors.white,
                                        size: 32,
                                      ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 4),

              // Live Equalizer Bars
              if (activeWave) ...[
                Center(
                  child: AnimatedBuilder(
                    animation: _waveCtrl,
                    builder: (context, _) {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(9, (idx) {
                          final phase =
                              (_waveCtrl.value * 2 * math.pi) + idx * 0.7;
                          final h = 6.0 + (math.sin(phase).abs() * 14.0);
                          return Container(
                            width: 4,
                            height: h,
                            margin:
                                const EdgeInsets.symmetric(horizontal: 2.5),
                            decoration: BoxDecoration(
                              color: voice.isRecording
                                  ? colors.error
                                  : colors.primary,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          );
                        }),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 6),
              ],

              Text(
                _statusHeadline(voice),
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: voice.isRecording ? colors.error : colors.primary,
                ),
              ),

              if (_userTranscript.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.format_quote_rounded,
                        size: 16,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _userTranscript,
                          style: GoogleFonts.inter(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Live Executed DB Action Chips with 1-Tap [Undo]
              if (_executedActions.isNotEmpty ||
                  _executedActionBanner != null) ...[
                const SizedBox(height: 8),
                ..._buildExecutedActionChips(colors),
              ],

              // Confirm-Before-Commit Safety Card (B2B Wholesale RFQ / Clear Cart / Checkout)
              if (_pendingConfirmation != null) ...[
                const SizedBox(height: 10),
                _buildPendingConfirmationCard(
                  _pendingConfirmation!,
                  colors,
                ),
              ],

              // Autonomous Decision Verdict Card (Weighted Decision Score 0-100)
              if (_decisionCard != null) ...[
                const SizedBox(height: 10),
                _buildDecisionVerdictCard(
                  _decisionCard!,
                  colors,
                  currency,
                ),
              ],

              // Visual Assistant Reply Card + Replay Speech button
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colors.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _visualReply,
                      style: GoogleFonts.inter(
                        fontSize: 13.2,
                        height: 1.45,
                        color: colors.onSurface,
                      ),
                    ),
                    if (_spokenSummary.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () {
                            if (voice.isSpeaking) {
                              voice.stopSpeaking();
                              setState(() => _status = ConciergeStatus.idle);
                            } else {
                              setState(
                                () => _status = ConciergeStatus.speaking,
                              );
                              voice
                                  .speakText(
                                    _spokenSummary,
                                    label: 'Penguin Concierge',
                                    forceEvenIfMuted: true,
                                  )
                                  .whenComplete(() {
                                if (mounted) {
                                  setState(
                                    () => _status = ConciergeStatus.idle,
                                  );
                                }
                              });
                            }
                          },
                          icon: Icon(
                            voice.isSpeaking
                                ? Icons.stop_rounded
                                : Icons.volume_up_rounded,
                            size: 16,
                          ),
                          label: Text(
                            voice.isSpeaking ? 'Stop Audio' : 'Replay Voice',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Live Database Tool & Reasoning Trace Pills
              if (_reasoningSteps.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _reasoningSteps.map((s) {
                    final stepName = (s['step'] ?? 'Step').toString();
                    final ms = (s['duration_ms'] as num?)?.toDouble() ?? 0.0;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            colors.secondaryContainer.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '✓ $stepName (${ms.toStringAsFixed(0)}ms)',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: colors.onSecondaryContainer,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],

              // Inline Comparison Matrix Card
              if (_comparison != null) ...[
                const SizedBox(height: 12),
                _buildInlineComparisonMatrix(
                  _comparison!,
                  theme,
                  currency,
                ),
              ],

              // Horizontal Product Cards
              if (_products.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 186,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _products.length,
                    itemBuilder: (context, idx) {
                      return _buildMiniProductCard(
                        _products[idx],
                        theme,
                        currency,
                      );
                    },
                  ),
                ),
              ],

              // Context-Aware Quick Voice Chips
              const SizedBox(height: 14),
              Text(
                'Context-Aware Voice Suggestions',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _contextQuickChips.map((chip) {
                    final busy = _status == ConciergeStatus.queryingDb ||
                        _status == ConciergeStatus.deciding;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        avatar: Icon(
                          Icons.bolt_rounded,
                          size: 15,
                          color: colors.primary,
                        ),
                        label: Text(
                          chip,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed:
                            busy ? null : () => _submitQuery(chip, isVoice: true),
                      ),
                    );
                  }).toList(),
                ),
              ),

              // Fallback Text Input inside Concierge Sheet (in case mic is unavailable)
              const SizedBox(height: 10),
              TextField(
                controller: _textCtrl,
                enabled: _status != ConciergeStatus.queryingDb &&
                    _status != ConciergeStatus.deciding,
                onSubmitted: (v) {
                  _textCtrl.clear();
                  _submitQuery(v, isVoice: false);
                },
                decoration: InputDecoration(
                  hintText:
                      'Or type a command (e.g. "Pick best headphones under \$350 & add to cart")...',
                  hintStyle: const TextStyle(fontSize: 12.5),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  suffixIcon: IconButton(
                    tooltip: 'Send',
                    icon: Icon(Icons.send_rounded, color: colors.primary),
                    onPressed: (_status == ConciergeStatus.queryingDb ||
                            _status == ConciergeStatus.deciding)
                        ? null
                        : () {
                            final q = _textCtrl.text;
                            _textCtrl.clear();
                            _submitQuery(q, isVoice: false);
                          },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhaseStatusPills(VoiceProvider voice, ColorScheme colors) {
    final stages = [
      ('Listening', voice.isRecording || _status == ConciergeStatus.listening),
      (
        'Querying DB',
        voice.isTranscribing || _status == ConciergeStatus.queryingDb,
      ),
      ('Deciding', _status == ConciergeStatus.deciding),
      ('Speaking', voice.isSpeaking || _status == ConciergeStatus.speaking),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: stages.map((entry) {
        final label = entry.$1;
        final active = entry.$2;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? colors.primary
                : colors.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: active ? Colors.white : colors.onSurfaceVariant,
            ),
          ),
        );
      }).toList(),
    );
  }

  List<Widget> _buildExecutedActionChips(ColorScheme colors) {
    if (_executedActions.isEmpty && _executedActionBanner != null) {
      return [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF10B981).withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                size: 16,
                color: Color(0xFF10B981),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _executedActionBanner!,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF10B981),
                  ),
                ),
              ),
            ],
          ),
        ),
      ];
    }

    return _executedActions.map((act) {
      final actId = (act['action_id'] ?? '').toString();
      final label =
          (act['label'] ?? _executedActionBanner ?? 'Executed Action')
              .toString();
      final canUndo =
          act['can_undo'] == true && !_undoneActionIds.contains(actId);
      final isUndone = _undoneActionIds.contains(actId);

      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: (isUndone ? colors.surfaceContainerHighest : const Color(0xFF10B981))
              .withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: (isUndone ? colors.outline : const Color(0xFF10B981))
                .withValues(alpha: 0.45),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isUndone ? Icons.undo_rounded : Icons.check_circle_rounded,
              size: 16,
              color: isUndone ? colors.onSurfaceVariant : const Color(0xFF10B981),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isUndone ? 'Undone: $label' : '✓ $label',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isUndone
                      ? colors.onSurfaceVariant
                      : const Color(0xFF10B981),
                ),
              ),
            ),
            if (canUndo)
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: colors.surface,
                ),
                onPressed: () => _handleUndoAction(act),
                icon: const Icon(Icons.undo_rounded, size: 14),
                label: const Text(
                  'Undo',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                ),
              ),
          ],
        ),
      );
    }).toList();
  }

  Widget _buildPendingConfirmationCard(
    Map<String, dynamic> pending,
    ColorScheme colors,
  ) {
    final title = (pending['title'] ?? 'Confirm Action').toString();
    final summary = (pending['summary'] ?? '').toString();
    final confirmLabel =
        (pending['confirm_label'] ?? 'Confirm & Commit').toString();
    final cancelLabel = (pending['cancel_label'] ?? 'Cancel').toString();
    final voiceHint =
        (pending['voice_hint'] ?? "Say 'Yes, confirm' or tap Confirm.")
            .toString();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.amber.shade700.withValues(alpha: 0.6),
          width: 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_user_rounded,
                size: 18,
                color: Colors.amber.shade800,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.shade700,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'CONFIRM GATE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            summary,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            voiceHint,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _submitQuery(
                    'Yes, confirm',
                    isVoice: true,
                    confirmPendingAction: true,
                  ),
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: Text(
                    confirmLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  setState(() => _pendingConfirmation = null);
                  CustomToast.show(context, 'Cancelled pending action.');
                },
                child: Text(
                  cancelLabel,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDecisionVerdictCard(
    Map<String, dynamic> card,
    ColorScheme colors,
    CurrencyProvider currency,
  ) {
    final pid = (card['winner_product_id'] as num?)?.toInt() ?? 144;
    final winnerName = (card['winner_name'] ?? 'Top Pick').toString();
    final winnerPrice = (card['winner_price'] as num?)?.toDouble() ?? 0.0;
    final score = (card['confidence_score'] as num?)?.toInt() ?? 95;
    final whyChosen = (card['why_chosen'] ?? '').toString();
    final trustScore = (card['trust_score'] as num?)?.toInt() ?? 96;
    final has3D = card['has_3d'] == true || Catalog3D.has(pid);
    final alts = (card['alternatives'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colors.primaryContainer.withValues(alpha: 0.45),
            colors.secondaryContainer.withValues(alpha: 0.30),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.5),
          width: 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'AI DECISION VERDICT • $score/100',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$trustScore% Verified Reviews',
                  style: TextStyle(
                    color: colors.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  winnerName,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                  ),
                ),
              ),
              Text(
                currency.format(winnerPrice),
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w900,
                  color: colors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            whyChosen,
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (alts.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Runner-Up: ${alts.first['name']} (${currency.format((alts.first['price'] as num?)?.toDouble() ?? 0)}) — ${alts.first['tradeoff'] ?? ''}',
              style: TextStyle(
                fontSize: 11,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: FilledButton.icon(
                    onPressed: () => VoiceActionDispatcher.dispatch(
                      context,
                      {
                        'type': 'add_to_cart',
                        'product_id': pid,
                        'product_name': winnerName,
                        'price': winnerPrice,
                        'image_url': card['winner_image_url'] ?? '',
                        'quantity': 1,
                      },
                    ),
                    icon: const Icon(Icons.add_shopping_cart_rounded, size: 15),
                    label: const Text(
                      'Add Winner to Cart',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
              if (has3D) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 32,
                  child: OutlinedButton.icon(
                    onPressed: () => VoiceActionDispatcher.dispatch(
                      context,
                      {
                        'type': 'open_3d',
                        'product_id': pid,
                        'product_name': winnerName,
                      },
                      closeOverlayBeforeNav: () => Navigator.of(context).pop(),
                    ),
                    icon: const Icon(Icons.view_in_ar_rounded, size: 15),
                    label: const Text(
                      'Inspect 3D',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInlineComparisonMatrix(
    Map<String, dynamic> cmp,
    ThemeData theme,
    CurrencyProvider currency,
  ) {
    final colors = theme.colorScheme;
    final title = (cmp['title'] ?? 'Side-by-Side Comparison').toString();
    final rows = (cmp['rows'] as List? ?? const [])
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.compare_arrows_rounded, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: rows.map((row) {
                final pid = (row['id'] as num?)?.toInt() ?? 0;
                final name = (row['name'] ?? 'Product').toString();
                final price = (row['price'] as num?)?.toDouble() ?? 0.0;
                final bulk = (row['b2b_bulk_unit_price'] as num?)?.toDouble() ??
                    (price * 0.9);
                final trust = (row['trust_rating'] as num?)?.toDouble() ?? 4.8;
                final has3D = row['has_3d'] == true;
                final badge = row['badge']?.toString();
                final stockStatus = (row['stock_status'] ?? 'In Stock').toString();
                final imgUrl =
                    Product.resolveImageUrl(row['image_url']?.toString());

                final prod = Product(
                  id: pid,
                  name: name,
                  description: (row['key_features'] ?? '').toString(),
                  price: price,
                  imageUrl: imgUrl,
                  category: (row['category'] ?? 'CATALOG').toString(),
                  rating: trust,
                  reviews: 12,
                  stock: (row['stock'] as num?)?.toInt() ?? 50,
                );

                return Container(
                  width: 196,
                  margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: badge != null
                          ? colors.primary
                          : colors.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (badge != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            badge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        currency.format(price),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: colors.primary,
                        ),
                      ),
                      Text(
                        'B2B (10+): ${currency.format(bulk)}/u',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const Divider(height: 12),
                      Text(
                        '${trust.toStringAsFixed(1)}★ Trust • $stockStatus',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF10B981),
                        ),
                      ),
                      Text(
                        has3D ? '3D GLB Ready' : '2D Studio Image',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: has3D
                              ? const Color(0xFF00ACC1)
                              : colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        height: 30,
                        child: FilledButton(
                          onPressed: () {
                            context.read<CartProvider>().addToCart(prod);
                            CustomToast.show(
                              context,
                              'Added "$name" to your cart!',
                            );
                          },
                          child: const Text(
                            'Add Winner / Item',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniProductCard(
    Product prod,
    ThemeData theme,
    CurrencyProvider currency,
  ) {
    final colors = theme.colorScheme;
    final has3D = Catalog3D.has(prod.id);

    return Container(
      width: 186,
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              onTap: () => VoiceActionDispatcher.dispatch(
                context,
                {
                  'type': 'open_product',
                  'product_id': prod.id,
                  'product_name': prod.name,
                },
                closeOverlayBeforeNav: () => Navigator.of(context).pop(),
              ),
              child: StudioProductImage(
                productId: prod.id,
                imageUrl: prod.imageUrl,
                padding: 6,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            prod.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          Text(
            '${currency.format(prod.price)} • ${prod.rating.toStringAsFixed(1)}★',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: colors.primary,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () {
                      context.read<CartProvider>().addToCart(prod);
                      CustomToast.show(
                        context,
                        'Added "${prod.name}" to cart!',
                      );
                    },
                    child: const Text('Add', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ),
              if (has3D) ...[
                const SizedBox(width: 6),
                SizedBox(
                  height: 28,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => VoiceActionDispatcher.dispatch(
                      context,
                      {
                        'type': 'open_3d',
                        'product_id': prod.id,
                        'product_name': prod.name,
                      },
                      closeOverlayBeforeNav: () => Navigator.of(context).pop(),
                    ),
                    child: const Text('3D', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
