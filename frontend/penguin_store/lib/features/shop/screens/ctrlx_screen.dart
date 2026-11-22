import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/core/services/voice_action_dispatcher.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/models/product_model.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';
import 'package:penguin_store/features/shop/widgets/studio_product_image.dart';

class AgentMessage {
  final String role; // "user" or "bot"
  final String text;
  final String? spokenSummary;
  final String
      dataType; // "text", "product_list", "bundle", "comparison", "cart_update", "order_tracker"
  final List<Product> suggestedProducts;
  final Map<String, dynamic>? orderAction;
  final Map<String, dynamic>? bundle;
  final Map<String, dynamic>? comparison;
  final List<Map<String, dynamic>> reasoningSteps;
  final String routedAgent;

  AgentMessage({
    required this.role,
    required this.text,
    this.spokenSummary,
    this.dataType = "text",
    this.suggestedProducts = const [],
    this.orderAction,
    this.bundle,
    this.comparison,
    this.reasoningSteps = const [],
    this.routedAgent = "CTRL-X",
  });
}

class CtrlXScreen extends StatefulWidget {
  final String? initialQuery;

  const CtrlXScreen({super.key, this.initialQuery});

  @override
  State<CtrlXScreen> createState() => _CtrlXScreenState();
}

class _CtrlXScreenState extends State<CtrlXScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<AgentMessage> _messages = [];
  bool _isLoading = false;
  bool _lastQueryWasVoice = false;
  String? _speakingMsgKey;

  // Unique session thread ID for multi-turn LangGraph memory persistence
  final String _threadId = const Uuid().v4();

  static const List<String> _quickPrompts = [
    'Plan a party setup',
    'Compare best audio',
    'Top 3D products under \$500',
    'Build a \$1,000 bundle',
    'Gift for a gamer under \$300',
    'Compare the first two',
  ];

  static const List<IconData> _promptIcons = [
    Icons.celebration_rounded,
    Icons.compare_arrows_rounded,
    Icons.view_in_ar_rounded,
    Icons.auto_awesome_mosaic_rounded,
    Icons.sports_esports_rounded,
    Icons.balance_rounded,
  ];

  @override
  void initState() {
    super.initState();
    final initQ = widget.initialQuery?.trim() ?? '';
    if (initQ.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _sendPromptText(initQ);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _handleMicTap() async {
    if (_isLoading) return;
    final voice = context.read<VoiceProvider>();
    if (voice.isTranscribing) return;
    // Dismiss mobile soft keyboard & synchronously unlock speech on gesture
    FocusScope.of(context).unfocus();
    voice.primeSpeech();
    final transcript = await voice.toggleRecordingAndTranscribe(
      context: context,
    );
    if (!mounted || transcript == null || transcript.trim().isEmpty) return;

    _lastQueryWasVoice = true;
    _controller.text = transcript.trim();
    await _sendMessage();
  }

  String _buildCtrlXSpokenSummary({
    required String aiReply,
    required String dataType,
    Map<String, dynamic>? comparisonData,
    Map<String, dynamic>? bundleData,
    List<Product> products = const [],
  }) {
    if (dataType == 'comparison' && comparisonData != null) {
      final winner = (comparisonData['winner_name'] ??
              comparisonData['winner'] ??
              '')
          .toString()
          .trim();
      final verdict = (comparisonData['verdict'] ??
              comparisonData['summary'] ??
              '')
          .toString()
          .trim();
      if (winner.isNotEmpty || verdict.isNotEmpty) {
        return 'Comparison ready. ${winner.isNotEmpty ? 'Top pick is $winner. ' : ''}$verdict';
      }
    }
    if (dataType == 'bundle' && bundleData != null) {
      final title = (bundleData['title'] ?? 'Custom bundle').toString().trim();
      final total = bundleData['total_price'];
      if (total != null) {
        return '$title is ready with a total of $total dollars.';
      }
    }
    if (products.isNotEmpty && aiReply.length > 260) {
      final names = products.take(2).map((p) => p.name).join(' and ');
      return 'I found ${products.length} matching products, starting with $names.';
    }
    return aiReply.length > 340 ? '${aiReply.substring(0, 340)}...' : aiReply;
  }

  Future<void> _sendPromptText(String prompt) async {
    _lastQueryWasVoice = false;
    _controller.text = prompt;
    await _sendMessage();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    // Synchronously unlock speech synthesis inside user send/tap gesture
    context.read<VoiceProvider>().primeSpeech();
    final bool triggeredByVoice = _lastQueryWasVoice;
    _lastQueryWasVoice = false;

    setState(() {
      _messages.add(AgentMessage(role: "user", text: text));
      _isLoading = true;
    });

    _controller.clear();
    _scrollToBottom();

    try {
      final voice = context.read<VoiceProvider>();
      final screenCtx = VoiceActionDispatcher.collectScreenContext(
        context,
        currentRoute: '/ctrlx',
      );
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      final url = Uri.parse('$base/api/agent/chat');

      final response = await http
          .post(
            url,
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              "user_input": text,
              "thread_id": _threadId,
              "current_route": "/ctrlx",
              "cart_item_count": screenCtx['cart_item_count'],
              "cart_total": screenCtx['cart_total'],
              "cart_items": screenCtx['cart_items'],
              "is_voice": triggeredByVoice,
              "stt_latency_ms": triggeredByVoice ? voice.lastSttLatencyMs : null,
              "voice_transcript": triggeredByVoice ? text : null,
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final aiReply =
            (data['reply'] ?? data['response'] ?? "No response received.").toString();
        final serverSpokenSummary =
            (data['spoken_summary'] ?? '').toString().trim();
        final dataType = (data['data_type'] ?? "text").toString();
        final routedAgent = (data['routed_agent'] ?? "CTRL-X").toString();
        final clientAction = data['client_action'] is Map
            ? Map<String, dynamic>.from(data['client_action'] as Map)
            : null;

        List<Product> products = [];
        Map<String, dynamic>? orderData;
        Map<String, dynamic>? bundleData;
        Map<String, dynamic>? comparisonData;
        List<Map<String, dynamic>> reasoningSteps = [];

        if (data['reasoning_steps'] is List) {
          reasoningSteps = (data['reasoning_steps'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }

        if (data['bundle'] is Map) {
          bundleData = Map<String, dynamic>.from(data['bundle'] as Map);
        }

        if (data['comparison'] is Map) {
          comparisonData = Map<String, dynamic>.from(data['comparison'] as Map);
        }

        if (data['suggested_products'] is List) {
          final List<dynamic> rawProducts = data['suggested_products'];
          products = rawProducts
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
                  imageUrl: (p['image_url'] ?? '').toString().trim(),
                  description:
                      (p['description'] ?? 'Suggested by CTRL-X').toString(),
                  rating:
                      ((p['trust_weighted_rating'] ?? p['rating']) as num?)
                              ?.toDouble() ??
                          4.8,
                  reviews: (p['reviews'] as num?)?.toInt() ?? 12,
                  stock: (p['stock'] as num?)?.toInt() ?? 50,
                ),
              )
              .toList();
        }

        if (dataType == "cart_update" && data['cart_action'] is Map) {
          final cartAction =
              Map<String, dynamic>.from(data['cart_action'] as Map);
          if (cartAction['action'] == "add_to_cart" &&
              cartAction['product'] is Map) {
            final productData = Map<String, dynamic>.from(
              cartAction['product'] as Map,
            );
            final int qty = (cartAction['quantity'] as num?)?.toInt() ?? 1;

            final aiProduct = Product(
              id: (productData['id'] as num?)?.toInt() ?? 0,
              name: (productData['name'] ?? 'Product').toString(),
              price: (productData['price'] as num?)?.toDouble() ?? 0.0,
              category: (productData['category'] ?? 'CATALOG').toString(),
              imageUrl: (productData['image_url'] ?? '').toString().trim(),
              description: 'Added via CTRL-X Autonomous Agent',
              rating: 4.9,
              reviews: 12,
            );

            if (mounted) {
              context.read<CartProvider>().addToCart(aiProduct, quantity: qty);
              CustomToast.show(
                context,
                'CTRL-X added ${aiProduct.name} (×$qty) to your cart!',
              );
            }
          }
        } else if (dataType == "order_tracker" && data['order_action'] is Map) {
          orderData = Map<String, dynamic>.from(data['order_action'] as Map);
        }

        if (clientAction != null &&
            !(dataType == "cart_update" &&
                clientAction['type'] == 'add_to_cart' &&
                data['cart_action'] is Map &&
                data['cart_action']['action'] == 'add_to_cart')) {
          await VoiceActionDispatcher.dispatch(context, clientAction);
          if (!mounted) return;
        }

        final speechScript = serverSpokenSummary.isNotEmpty
            ? serverSpokenSummary
            : _buildCtrlXSpokenSummary(
                aiReply: aiReply,
                dataType: dataType,
                comparisonData: comparisonData,
                bundleData: bundleData,
                products: products,
              );

        setState(() {
          _messages.add(
            AgentMessage(
              role: "bot",
              text: aiReply,
              spokenSummary: speechScript,
              dataType: dataType,
              suggestedProducts: products,
              orderAction: orderData,
              bundle: bundleData,
              comparison: comparisonData,
              reasoningSteps: reasoningSteps,
              routedAgent: routedAgent,
            ),
          );
        });

        if (mounted) {
          final voice = context.read<VoiceProvider>();
          if (triggeredByVoice || voice.autoSpeakCtrlX) {
            if (speechScript.trim().isNotEmpty) {
              _speakingMsgKey = '${aiReply.hashCode}';
              voice
                  .speakText(
                    speechScript,
                    label: 'CTRL-X speaking...',
                    preferNeural: false,
                    forceEvenIfMuted: triggeredByVoice,
                  )
                  .then((outcome) {
                if (mounted && outcome.autoplayBlocked) {
                  CustomToast.show(
                    context,
                    'Tap "Listen" on the message to hear CTRL-X aloud.',
                  );
                }
              });
            }
          }
        }
      } else {
        String errorDetail =
            "Server returned status ${response.statusCode}. Please try again.";
        try {
          final errJson = jsonDecode(response.body);
          if (errJson is Map && errJson['detail'] is String) {
            errorDetail = errJson['detail'] as String;
          }
        } catch (_) {}

        setState(() {
          _messages.add(AgentMessage(role: "bot", text: errorDetail));
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messages.add(
          AgentMessage(
            role: "bot",
            text:
                "Unable to reach the CTRL-X AI server right now. Please check your connection and try again.",
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _scrollToBottom();
      }
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 120), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  /// Phase 1.2: Interactive Price & Feature Comparison Matrix Card inside CTRL-X Chat
  Widget _buildComparisonMatrixCard(
    Map<String, dynamic> comparison,
    List<Product> products,
    ThemeData theme,
    CurrencyProvider currency,
  ) {
    final colors = theme.colorScheme;
    final title =
        (comparison['title'] ?? 'AI Side-by-Side Product Comparison').toString();
    final rawRows = comparison['rows'] is List
        ? List<Map<String, dynamic>>.from(
            (comparison['rows'] as List)
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m)),
          )
        : const <Map<String, dynamic>>[];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 18, top: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.compare_arrows_rounded,
                  color: colors.onPrimaryContainer,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800,
                        fontSize: 15.5,
                        color: colors.onSurface,
                      ),
                    ),
                    Text(
                      'Normalized on Live Price, AI Trust Score, 3D Studio Twin & Stock',
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: rawRows.map((row) {
                final pid = (row['id'] as num?)?.toInt() ?? 0;
                final name = (row['name'] ?? 'Product').toString();
                final price = (row['price'] as num?)?.toDouble() ?? 0.0;
                final trust = (row['trust_rating'] as num?)?.toDouble() ?? 4.8;
                final has3D = row['has_3d'] == true || Catalog3D.has(pid);
                final stockStatus =
                    (row['stock_status'] ?? 'In Stock').toString();
                final bestFor =
                    (row['best_for'] ?? 'Verified Choice').toString();
                final badge = row['badge']?.toString();
                final imageUrl = (row['image_url'] ?? '').toString();
                final matchingProd = products
                    .where((p) => p.id == pid)
                    .firstOrNull ??
                    Product(
                      id: pid,
                      name: name,
                      description: (row['key_features'] ?? '').toString(),
                      price: price,
                      imageUrl: imageUrl,
                      category: (row['category'] ?? 'CATALOG').toString(),
                      rating: trust,
                      reviews: 12,
                    );

                final isTopBadge = badge != null && badge.contains('TOP');

                return Container(
                  width: 245,
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: badge != null
                          ? (isTopBadge
                                ? colors.primary
                                : const Color(0xFF10B981))
                          : colors.outlineVariant.withValues(alpha: 0.45),
                      width: badge != null ? 1.8 : 1.0,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (badge != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isTopBadge
                                ? colors.primary
                                : const Color(0xFF10B981),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            badge,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      SizedBox(
                        height: 110,
                        width: double.infinity,
                        child: StudioProductImage(
                          productId: pid,
                          imageUrl: imageUrl,
                          padding: 8.0,
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        currency.format(price),
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                          color: colors.primary,
                        ),
                      ),
                      const Divider(height: 16),
                      _cmpSpecRow(
                        'AI Trust',
                        '${trust.toStringAsFixed(1)} ★ Verified',
                        colors,
                        valueColor: const Color(0xFF10B981),
                      ),
                      _cmpSpecRow(
                        '3D Studio',
                        has3D ? '3D GLB Ready' : '2D Studio',
                        colors,
                        valueColor: has3D ? const Color(0xFF00ACC1) : null,
                      ),
                      _cmpSpecRow('Availability', stockStatus, colors),
                      _cmpSpecRow('Best For', bestFor, colors),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 34,
                              child: FilledButton.icon(
                                onPressed: () {
                                  context
                                      .read<CartProvider>()
                                      .addToCart(matchingProd);
                                  CustomToast.show(
                                    context,
                                    'Added "${matchingProd.name}" to cart!',
                                  );
                                },
                                icon: const Icon(
                                  Icons.add_shopping_cart_rounded,
                                  size: 14,
                                ),
                                label: const Text(
                                  'Add',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          SizedBox(
                            height: 34,
                            child: OutlinedButton(
                              onPressed: () => context.push('/product/$pid'),
                              child: Text(
                                has3D ? '3D / View' : 'Details',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ),
                        ],
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

  Widget _cmpSpecRow(
    String label,
    String value,
    ColorScheme colors, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: valueColor ?? colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Phase 1.2: Rich Interactive Product Cards inside CTRL-X Chat
  /// Includes thumbnail, live price, star/trust badge, one-tap "Add to Cart",
  /// "3D View", and "Details" buttons.
  Widget _buildInteractiveChatProductCard(
    Product prod,
    ThemeData theme,
    CurrencyProvider currency,
  ) {
    final colors = theme.colorScheme;
    final has3D = Catalog3D.has(prod.id);

    return Container(
      width: 228,
      margin: const EdgeInsets.only(right: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => context.push('/product/${prod.id}'),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  StudioProductImage(
                    productId: prod.id,
                    imageUrl: prod.imageUrl,
                    padding: 10.0,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  Positioned(
                    top: 7,
                    left: 7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${prod.rating.toStringAsFixed(1)}★ Trust',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  if (has3D)
                    Positioned(
                      top: 7,
                      right: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B132B),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF00E5FF)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.view_in_ar_rounded,
                              size: 11,
                              color: Color(0xFF00E5FF),
                            ),
                            SizedBox(width: 3),
                            Text(
                              '3D',
                              style: TextStyle(
                                color: Color(0xFF00E5FF),
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            prod.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w800,
              fontSize: 13.5,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                currency.format(prod.price),
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w900,
                  fontSize: 15.5,
                  color: colors.primary,
                ),
              ),
              Text(
                prod.stock > 0 ? 'In Stock (${prod.stock})' : 'Out of Stock',
                style: GoogleFonts.inter(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: prod.stock > 0
                      ? const Color(0xFF10B981)
                      : Colors.redAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: FilledButton.icon(
                    onPressed: prod.stock <= 0
                        ? null
                        : () {
                            context.read<CartProvider>().addToCart(prod);
                            CustomToast.show(
                              context,
                              'Added "${prod.name}" to cart!',
                            );
                          },
                    icon: const Icon(
                      Icons.add_shopping_cart_rounded,
                      size: 14,
                    ),
                    label: const Text(
                      'Add to Cart',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 34,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: () => context.push('/product/${prod.id}'),
                  child: Text(
                    has3D ? '3D View' : 'Details',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOrderTrackerCard(
    Map<String, dynamic> orderDetails,
    ThemeData theme,
    CurrencyProvider currency,
  ) {
    final order = orderDetails['order'] is Map
        ? Map<String, dynamic>.from(orderDetails['order'] as Map)
        : <String, dynamic>{};
    final orderId = (order['order_id'] ?? 'N/A').toString();
    final status =
        (order['overall_status'] ?? order['status'] ?? 'PROCESSING').toString();
    final total = (order['total'] as num?)?.toDouble() ?? 0.0;
    final trackingNumbers = order['tracking_numbers'] is List
        ? List<dynamic>.from(order['tracking_numbers'] as List)
        : const [];
    final address = (order['shipping_address'] ??
            (trackingNumbers.isNotEmpty
                ? trackingNumbers.join(', ')
                : 'Pending Assignment'))
        .toString();
    final delivery =
        (order['estimated_delivery'] ?? 'Standard Delivery').toString();
    final items = order['items'] is List
        ? List<dynamic>.from(order['items'] as List)
        : const [];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16, top: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.primaryColor.withValues(alpha: 0.3),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.local_shipping_rounded,
                    color: theme.primaryColor,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Order #$orderId",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Total Amount:",
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              Text(
                currency.format(total),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Est. Delivery:",
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              Flexible(
                child: Text(
                  delivery,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: theme.primaryColor,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Tracking:",
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  address,
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const Divider(height: 18),
            ...items.whereType<Map>().map((item) {
              final pName = (item['product_name'] ?? 'Item').toString();
              final qty = (item['quantity'] ?? 1).toString();
              final fType =
                  (item['fulfillment_type'] ?? 'IN_HOUSE').toString();
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        '$pName (×$qty)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      fType,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: theme.primaryColor,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildBundleCard(
    Map<String, dynamic> bundle,
    List<Product> bundleProducts,
    ThemeData theme,
    CurrencyProvider currency,
  ) {
    final title =
        (bundle['title'] ?? 'CTRL-X Trust-Verified Bundle').toString();
    final totalPrice = (bundle['total_price'] as num?)?.toDouble() ?? 0.0;
    final budget = (bundle['budget'] as num?)?.toDouble();
    final budgetRemaining =
        (bundle['budget_remaining'] as num?)?.toDouble() ?? 0.0;
    final avgTrust =
        (bundle['average_trust_rating'] as num?)?.toDouble() ?? 4.8;
    final rationale = (bundle['rationale'] ?? '').toString();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20, top: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.primaryColor.withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.auto_awesome_mosaic_rounded,
                  color: theme.primaryColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15.5,
                      ),
                    ),
                    Text(
                      '${bundleProducts.length} items • Avg Trust ${avgTrust.toStringAsFixed(1)}★',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  budget != null
                      ? '${currency.format(budgetRemaining)} Under Budget'
                      : 'Trust Verified',
                  style: const TextStyle(
                    color: Colors.green,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (rationale.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              rationale,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const Divider(height: 20),
          ...bundleProducts.map((prod) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: StudioProductImage(
                      productId: prod.id,
                      imageUrl: prod.imageUrl,
                      padding: 4.0,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          prod.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Row(
                          children: [
                            Text(
                              prod.category,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.verified_rounded,
                              size: 12,
                              color: Colors.green,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${prod.rating.toStringAsFixed(1)}★ Trust',
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.green,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Text(
                    currency.format(prod.price),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: theme.primaryColor,
                    ),
                  ),
                ],
              ),
            );
          }),
          const Divider(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Bundle Total',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  Text(
                    currency.format(totalPrice),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: theme.primaryColor,
                    ),
                  ),
                ],
              ),
              FilledButton.icon(
                onPressed: bundleProducts.isEmpty
                    ? null
                    : () {
                        final cart = context.read<CartProvider>();
                        for (final item in bundleProducts) {
                          cart.addToCart(item);
                        }
                        CustomToast.show(
                          context,
                          'Added all ${bundleProducts.length} bundle items (${currency.format(totalPrice)}) to cart!',
                        );
                      },
                icon: const Icon(Icons.add_shopping_cart_rounded, size: 17),
                label: const Text('Add Full Bundle to Cart'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _botAvatar() {
    return Container(
      width: 30,
      height: 30,
      margin: const EdgeInsets.only(right: 8, bottom: 8),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF42A5F5), Color(0xFF00ACC1)],
        ),
      ),
      child: const Icon(
        Icons.auto_awesome_rounded,
        color: Colors.white,
        size: 16,
      ),
    );
  }

  Widget _buildBubble(AgentMessage msg, ThemeData theme, bool isDark) {
    final isUser = msg.role == "user";
    final maxWidth = MediaQuery.of(context).size.width * 0.74;

    final bubble = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(220.0, 580.0)),
      decoration: BoxDecoration(
        gradient: isUser
            ? const LinearGradient(
                colors: [Color(0xFF1E88E5), Color(0xFF3949AB)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isUser
            ? null
            : (isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.94)),
        border: isUser
            ? null
            : Border.all(color: theme.primaryColor.withValues(alpha: 0.16)),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isUser ? 18 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 18),
        ),
      ),
      child: SelectableText(
        msg.text,
        style: TextStyle(
          fontSize: 14.2,
          height: 1.48,
          color: isUser ? Colors.white : theme.colorScheme.onSurface,
        ),
      ),
    );

    final msgKey = '${msg.text.hashCode}';
    return Row(
      mainAxisAlignment:
          isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!isUser) _botAvatar(),
        Flexible(
          child: isUser
              ? bubble
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    bubble,
                    const SizedBox(height: 4),
                    Consumer<VoiceProvider>(
                      builder: (context, voice, _) {
                        final isThisPlaying =
                            voice.isSpeaking && _speakingMsgKey == msgKey;
                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            if (isThisPlaying) {
                              voice.stopSpeaking();
                              setState(() => _speakingMsgKey = null);
                            } else {
                              setState(() => _speakingMsgKey = msgKey);
                              final rawSpoken =
                                  (msg.spokenSummary != null &&
                                          msg.spokenSummary!.trim().isNotEmpty)
                                      ? msg.spokenSummary!.trim()
                                      : msg.text;
                              voice.speakText(
                                rawSpoken,
                                label: 'CTRL-X reply',
                                preferNeural: false,
                                forceEvenIfMuted: true,
                              );
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isThisPlaying
                                      ? Icons.stop_circle_rounded
                                      : Icons.volume_up_rounded,
                                  size: 14,
                                  color: isThisPlaying
                                      ? theme.colorScheme.error
                                      : theme.primaryColor,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  isThisPlaying ? 'Stop' : 'Listen',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: isThisPlaying
                                        ? theme.colorScheme.error
                                        : theme.primaryColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 90, 22, 20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const PulsingOrb(size: 92),
            const SizedBox(height: 22),
            FadeSlideIn(
              delay: const Duration(milliseconds: 150),
              child: ShaderMask(
                shaderCallback: (rect) => const LinearGradient(
                  colors: [Color(0xFF1E88E5), Color(0xFF00ACC1)],
                ).createShader(rect),
                child: const Text(
                  'Hi, I\'m CTRL‑X',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FadeSlideIn(
              delay: const Duration(milliseconds: 260),
              child: Text(
                'Occasion-aware AI shopping & comparison assistant.\n'
                'Plan setups, compare live prices & 3D twins, build bundles, and track orders.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 12.8,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 26),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: List.generate(_quickPrompts.length, (i) {
                  final prompt = _quickPrompts[i];
                  return FadeSlideIn(
                    delay: Duration(milliseconds: 320 + i * 70),
                    child: PressableScale(
                      onTap: _isLoading ? null : () => _sendPromptText(prompt),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.primaryColor.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _promptIcons[i % _promptIcons.length],
                              size: 17,
                              color: theme.primaryColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              prompt,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickPromptBar(ThemeData theme) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        scrollDirection: Axis.horizontal,
        itemCount: _quickPrompts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final prompt = _quickPrompts[index];
          return ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(
              _promptIcons[index % _promptIcons.length],
              size: 14,
              color: theme.primaryColor,
            ),
            label: Text(
              prompt,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: _isLoading ? null : () => _sendPromptText(prompt),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currency = context.watch<CurrencyProvider>();

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: theme.primaryColor,
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'CTRL‑X AI Shopping & Comparison Agent',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _isLoading
                        ? const Color(0xFF00E5FF)
                        : const Color(0xFF22C55E),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _isLoading
                      ? 'expanding query & ranking live catalog…'
                      : 'online • Supabase grounded',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          Consumer<VoiceProvider>(
            builder: (context, voice, _) {
              return IconButton(
                tooltip: voice.autoSpeakCtrlX
                    ? 'Auto-Speak CTRL-X Replies: ON'
                    : 'Auto-Speak CTRL-X Replies: OFF',
                onPressed: () {
                  final next = !voice.autoSpeakCtrlX;
                  voice.setAutoSpeakCtrlX(next);
                  CustomToast.show(
                    context,
                    next
                        ? 'CTRL-X Voice Replies enabled'
                        : 'CTRL-X Voice Replies muted (tap Listen anytime)',
                  );
                },
                icon: Icon(
                  voice.autoSpeakCtrlX
                      ? Icons.record_voice_over_rounded
                      : Icons.voice_over_off_outlined,
                ),
              );
            },
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? const [Color(0xFF0B1624), Color(0xFF10243B)]
                : const [Color(0xFFFFFFFF), Color(0xFFE8F3FE)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SnowfallBackground(
          flakes: 22,
          color: isDark ? Colors.white : const Color(0xFF9CC9F2),
          child: Column(
            children: [
              Expanded(
                child: _messages.isEmpty
                    ? _buildEmptyState(theme)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(14, 96, 14, 12),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final isUser = msg.role == "user";

                          return FadeSlideIn(
                            key: ValueKey('msg-$index'),
                            offset: Offset(isUser ? 0.06 : -0.06, 0.04),
                            duration: const Duration(milliseconds: 340),
                            child: Column(
                              crossAxisAlignment: isUser
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              children: [
                                if (!isUser && msg.reasoningSteps.isNotEmpty)
                                  _ReasoningTraceAccordion(
                                    steps: msg.reasoningSteps,
                                    routedAgent: msg.routedAgent,
                                  ),
                                _buildBubble(msg, theme, isDark),

                                // 1. Side-by-Side Comparison Matrix Card (Phase 1.2)
                                if (!isUser && msg.comparison != null)
                                  _buildComparisonMatrixCard(
                                    msg.comparison!,
                                    msg.suggestedProducts,
                                    theme,
                                    currency,
                                  ),

                                // 2. Bundle Card Injection
                                if (!isUser &&
                                    msg.bundle != null &&
                                    msg.suggestedProducts.isNotEmpty)
                                  _buildBundleCard(
                                    msg.bundle!,
                                    msg.suggestedProducts,
                                    theme,
                                    currency,
                                  ),

                                // 3. Interactive Product Cards Carousel
                                if (!isUser &&
                                    msg.bundle == null &&
                                    msg.comparison == null &&
                                    msg.suggestedProducts.isNotEmpty)
                                  Container(
                                    height: 292,
                                    margin: const EdgeInsets.only(
                                      bottom: 20,
                                      top: 8,
                                    ),
                                    child: ListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: msg.suggestedProducts.length,
                                      itemBuilder: (context, productIndex) {
                                        final prod =
                                            msg.suggestedProducts[productIndex];
                                        return FadeSlideIn.staggered(
                                          index: productIndex,
                                          child:
                                              _buildInteractiveChatProductCard(
                                            prod,
                                            theme,
                                            currency,
                                          ),
                                        );
                                      },
                                    ),
                                  ),

                                // 4. Order Tracker Card Injection
                                if (!isUser &&
                                    msg.dataType == "order_tracker" &&
                                    msg.orderAction != null)
                                  _buildOrderTrackerCard(
                                    msg.orderAction!,
                                    theme,
                                    currency,
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              if (_isLoading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: Row(
                    children: [
                      _botAvatar(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: theme.primaryColor.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TypingDots(color: theme.primaryColor),
                            const SizedBox(width: 10),
                            Text(
                              'Running hybrid catalog & trust analysis…',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (_messages.isNotEmpty) ...[
                _buildQuickPromptBar(theme),
                const SizedBox(height: 6),
              ],
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: theme.primaryColor.withValues(alpha: 0.2),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Consumer<VoiceProvider>(
                        builder: (context, voice, _) {
                          if (!voice.isRecording && !voice.isTranscribing) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            width: double.infinity,
                            margin: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: voice.isRecording
                                  ? theme.colorScheme.errorContainer
                                  : theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                if (voice.isTranscribing)
                                  SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: theme.colorScheme.onPrimaryContainer,
                                    ),
                                  )
                                else
                                  Icon(
                                    Icons.graphic_eq_rounded,
                                    size: 16,
                                    color: theme.colorScheme.onErrorContainer,
                                  ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    voice.isRecording
                                        ? 'Listening... tap mic again to send via Groq Whisper'
                                        : 'Transcribing speech with Groq Whisper...',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: voice.isRecording
                                          ? theme.colorScheme.onErrorContainer
                                          : theme.colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              style: TextStyle(
                                color: theme.textTheme.bodyLarge?.color,
                              ),
                              enabled: !_isLoading,
                              onSubmitted: (_) {
                                if (!_isLoading) _sendMessage();
                              },
                              decoration: InputDecoration(
                                hintText:
                                    'Ask "I need a party", "Compare best audio", or "Build a \$500 bundle"...',
                                hintStyle: TextStyle(
                                  fontSize: 12.8,
                                  color: theme.textTheme.bodySmall?.color,
                                ),
                                filled: false,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          Consumer<VoiceProvider>(
                            builder: (context, voice, _) {
                              final canTapMic =
                                  !_isLoading && !voice.isTranscribing;
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Tooltip(
                                  message: voice.isRecording
                                      ? 'Stop & Send Voice Query'
                                      : 'Speak to CTRL-X',
                                  child: Material(
                                    color: voice.isRecording
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.primaryContainer
                                            .withValues(alpha: 0.78),
                                    shape: const CircleBorder(),
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: canTapMic ? _handleMicTap : null,
                                      child: SizedBox(
                                        width: 44,
                                        height: 44,
                                        child: voice.isTranscribing
                                            ? Center(
                                                child: SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color: theme
                                                        .colorScheme.primary,
                                                  ),
                                                ),
                                              )
                                            : Icon(
                                                voice.isRecording
                                                    ? Icons.stop_rounded
                                                    : Icons.mic_rounded,
                                                size: 21,
                                                color: voice.isRecording
                                                    ? Colors.white
                                                    : theme.colorScheme.primary,
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          PressableScale(
                            onTap: _isLoading ? null : _sendMessage,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: _isLoading
                                      ? [Colors.grey.shade400, Colors.grey.shade500]
                                      : const [
                                          Color(0xFF1E88E5),
                                          Color(0xFF00ACC1),
                                        ],
                                ),
                              ),
                              child: const Icon(
                                Icons.arrow_upward_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReasoningTraceAccordion extends StatefulWidget {
  final List<Map<String, dynamic>> steps;
  final String routedAgent;

  const _ReasoningTraceAccordion({
    required this.steps,
    required this.routedAgent,
  });

  @override
  State<_ReasoningTraceAccordion> createState() =>
      _ReasoningTraceAccordionState();
}

class _ReasoningTraceAccordionState extends State<_ReasoningTraceAccordion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMs = widget.steps.fold<double>(
      0.0,
      (sum, s) => sum + ((s['duration_ms'] as num?)?.toDouble() ?? 0.0),
    );

    return Container(
      margin: const EdgeInsets.only(left: 38, bottom: 6),
      constraints: const BoxConstraints(maxWidth: 540),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.primaryColor.withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 16,
                    color: theme.primaryColor,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Agent Reasoning Trace • ${widget.routedAgent} (${widget.steps.length} steps • ${totalMs.toStringAsFixed(1)} ms)',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: theme.primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 17,
                    color: theme.primaryColor,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                children: widget.steps.map((s) {
                  final stepName = (s['step'] ?? 'Step').toString();
                  final summary = (s['summary'] ?? '').toString();
                  final ms = (s['duration_ms'] as num?)?.toDouble() ?? 0.0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 14,
                            color: Color(0xFF16A34A),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                    child: Text(
                                      stepName,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${ms.toStringAsFixed(1)} ms',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: theme.primaryColor,
                                    ),
                                  ),
                                ],
                              ),
                              if (summary.isNotEmpty)
                                Text(
                                  summary,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
