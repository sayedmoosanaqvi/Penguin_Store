import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/product_provider.dart';
import 'package:penguin_store/features/shop/services/notification_service.dart';
import 'package:penguin_store/features/shop/services/stripe_payment_service.dart';
import 'package:penguin_store/features/shop/widgets/custom_toast.dart';

/// Phase 2.2 & Phase 5.2: Celebratory Checkout Success Screen
/// Verifies the Stripe Checkout Session with FastAPI, triggers the confirmation
/// email & stock update idempotently, plays a custom GPU-smooth Checkmark animation,
/// and displays the itemized receipt with one-click Invoice copy/download.
class CheckoutSuccessScreen extends StatefulWidget {
  final String? sessionId;
  final int? orderId;
  final String? mode;

  const CheckoutSuccessScreen({
    super.key,
    this.sessionId,
    this.orderId,
    this.mode,
  });

  @override
  State<CheckoutSuccessScreen> createState() => _CheckoutSuccessScreenState();
}

class _CheckoutSuccessScreenState extends State<CheckoutSuccessScreen> {
  bool _isVerifying = true;
  String? _errorMessage;
  Map<String, dynamic>? _orderRecord;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _verifyAndLoadOrder();
    });
  }

  Future<void> _verifyAndLoadOrder() async {
    final sessionId = widget.sessionId?.trim() ?? '';
    final orderId = widget.orderId;

    try {
      if (sessionId.isNotEmpty) {
        final res = await StripePaymentService.verifyCheckoutSession(
          sessionId: sessionId,
          orderId: orderId,
        );
        final paid = res['paid'] == true;
        final ord = res['order'] is Map
            ? Map<String, dynamic>.from(res['order'] as Map)
            : null;

        if (!mounted) return;
        if (paid) {
          context.read<CartProvider>().clear();
          context
              .read<ProductProvider>()
              .ensureProductsLoaded(forceRefresh: true);
          NotificationService.showPushBanner(
            context,
            'Stripe Payment Verified!',
            'Order #${ord?['order_id'] ?? orderId ?? ''} is confirmed and a receipt email has been sent.',
          );
          final resolvedOid =
              (ord?['order_id'] ?? orderId ?? '').toString();
          final totalUsd = (ord?['total_amount'] as num?)?.toDouble() ?? 0.0;
          final formattedTotal =
              context.read<CurrencyProvider>().format(totalUsd);
          context.read<VoiceProvider>().speakOrderConfirmation(
                orderId: resolvedOid.isEmpty ? 'confirmed' : resolvedOid,
                formattedTotal: formattedTotal,
                isStripe: true,
              );
        }
        setState(() {
          _orderRecord = ord;
          _isVerifying = false;
        });
        return;
      }

      if (orderId != null && orderId > 0) {
        final ord = await StripePaymentService.fetchOrderDetail(orderId);
        if (!mounted) return;
        context.read<CartProvider>().clear();
        context
            .read<ProductProvider>()
            .ensureProductsLoaded(forceRefresh: true);
        NotificationService.showPushBanner(
          context,
          'Order Confirmed!',
          'Order #$orderId has been placed and queued for dispatch.',
        );
        final totalUsd = (ord?['total_amount'] as num?)?.toDouble() ?? 0.0;
        final formattedTotal =
            context.read<CurrencyProvider>().format(totalUsd);
        context.read<VoiceProvider>().speakOrderConfirmation(
              orderId: orderId.toString(),
              formattedTotal: formattedTotal,
              isStripe: false,
            );
        setState(() {
          _orderRecord = ord;
          _isVerifying = false;
        });
        return;
      }

      // Fallback when navigated to /success directly
      if (!mounted) return;
      context.read<CartProvider>().clear();
      setState(() {
        _isVerifying = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isVerifying = false;
      });
    }
  }

  String _formatInvoiceText(CurrencyProvider currency) {
    final ord = _orderRecord;
    final oid = ord?['order_id'] ?? widget.orderId ?? 'CONFIRMED';
    final name = ord?['customer_name'] ?? 'Valued Customer';
    final email = ord?['customer_email'] ?? '';
    final address =
        '${ord?['shipping_address'] ?? ''}, ${ord?['city'] ?? ''}, ${ord?['country'] ?? 'Pakistan'}';
    final payMethod = (ord?['payment_method'] ??
            (widget.sessionId != null ? 'STRIPE' : 'COD'))
        .toString();
    final payStatus = (ord?['payment_status'] ?? 'paid').toString().toUpperCase();
    final subtotal = (ord?['subtotal_amount'] as num?)?.toDouble() ??
        (ord?['total_amount'] as num?)?.toDouble() ??
        0.0;
    final discount = (ord?['discount_amount'] as num?)?.toDouble() ?? 0.0;
    final tax = (ord?['tax_amount'] as num?)?.toDouble() ?? 0.0;
    final total = (ord?['total_amount'] as num?)?.toDouble() ?? 0.0;
    final items = ord?['items'] is List
        ? List<Map<String, dynamic>>.from(
            (ord!['items'] as List).whereType<Map>().map(
                  (m) => Map<String, dynamic>.from(m),
                ),
          )
        : const <Map<String, dynamic>>[];

    final buf = StringBuffer()
      ..writeln('====================================================')
      ..writeln('           PENGUIN STORE OFFICIAL INVOICE           ')
      ..writeln('====================================================')
      ..writeln('Order ID       : #$oid')
      ..writeln('Payment Method : $payMethod ($payStatus)')
      ..writeln('Customer       : $name ($email)')
      ..writeln('Ship To        : $address')
      ..writeln('----------------------------------------------------');

    for (final item in items) {
      final qty = item['quantity'] ?? 1;
      final pName = item['product_name'] ?? 'Product';
      final unit = (item['unit_price'] as num?)?.toDouble() ?? 0.0;
      final variant = item['selected_variant'];
      buf.writeln(
        '• ${qty}x $pName${variant != null ? ' [$variant]' : ''} — ${currency.format(unit * (qty as num))}',
      );
    }

    buf
      ..writeln('----------------------------------------------------')
      ..writeln('Subtotal       : ${currency.format(subtotal)}')
      ..writeln('Discount       : -${currency.format(discount)}')
      ..writeln('Tax (5%)       : ${currency.format(tax)}')
      ..writeln('GRAND TOTAL    : ${currency.format(total)}')
      ..writeln('====================================================');
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currency = context.watch<CurrencyProvider>();

    if (_isVerifying) {
      return Scaffold(
        backgroundColor: colors.surface,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 52,
                height: 52,
                child: CircularProgressIndicator(strokeWidth: 3.5),
              ),
              const SizedBox(height: 20),
              Text(
                'Verifying Payment with Stripe...',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Confirming transaction signature & dispatching your receipt email.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final ord = _orderRecord;
    final orderId = ord?['order_id'] ?? widget.orderId;
    final isStripe = (widget.sessionId?.isNotEmpty ?? false) ||
        (ord?['payment_method']?.toString().toUpperCase() == 'STRIPE');
    final items = ord?['items'] is List
        ? List<Map<String, dynamic>>.from(
            (ord!['items'] as List).whereType<Map>().map(
                  (m) => Map<String, dynamic>.from(m),
                ),
          )
        : const <Map<String, dynamic>>[];
    final total = (ord?['total_amount'] as num?)?.toDouble() ?? 0.0;
    final subtotal = (ord?['subtotal_amount'] as num?)?.toDouble() ?? total;
    final discount = (ord?['discount_amount'] as num?)?.toDouble() ?? 0.0;
    final tax = (ord?['tax_amount'] as num?)?.toDouble() ?? 0.0;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Order Confirmation',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w800,
            fontSize: 17,
            color: colors.onSurface,
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
            children: [
              // 4-Step Checkout Progress Bar (Step 4 Active)
              const CheckoutStepperBanner(activeStep: 3),
              const SizedBox(height: 24),

              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: const Color(0xFF10B981).withValues(alpha: 0.45),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF10B981).withValues(alpha: 0.08),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const _AnimatedSuccessCheckmark(size: 86),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        isStripe
                            ? 'STRIPE PAYMENT VERIFIED • PAID'
                            : 'CASH ON DELIVERY • CONFIRMED',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                          color: const Color(0xFF10B981),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      orderId != null
                          ? 'Thank You! Order #$orderId is Confirmed'
                          : 'Payment Successful & Order Confirmed!',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _errorMessage != null
                          ? 'Notice: $_errorMessage'
                          : 'An official confirmation email and itemized receipt have been dispatched to ${ord?['customer_email'] ?? 'your email'}.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 13.5,
                        height: 1.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Consumer<VoiceProvider>(
                      builder: (context, voice, _) {
                        final oidStr = (orderId ?? 'confirmed').toString();
                        final formattedTotal = currency.format(total);
                        final isBlocked = voice.autoplayBlocked;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: isBlocked
                                ? colors.primaryContainer.withValues(alpha: 0.7)
                                : colors.surfaceContainerHighest.withValues(
                                    alpha: 0.45,
                                  ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isBlocked
                                  ? colors.primary
                                  : colors.outlineVariant.withValues(
                                      alpha: 0.4,
                                    ),
                            ),
                          ),
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Icon(
                                voice.isSpeaking
                                    ? Icons.graphic_eq_rounded
                                    : Icons.volume_up_rounded,
                                color: colors.primary,
                                size: 20,
                              ),
                              Text(
                                isBlocked
                                    ? 'Browser paused auto-audio after Stripe redirect'
                                    : (voice.isSpeaking
                                          ? 'Reading your order confirmation aloud...'
                                          : 'Spoken Order & Payment Confirmation'),
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: colors.onSurface,
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () {
                                  if (voice.isSpeaking) {
                                    voice.stopSpeaking();
                                  } else {
                                    voice.speakOrderConfirmation(
                                      orderId: oidStr,
                                      formattedTotal: formattedTotal,
                                      isStripe: isStripe,
                                      force: true,
                                    );
                                  }
                                },
                                icon: Icon(
                                  voice.isSpeaking
                                      ? Icons.stop_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 17,
                                ),
                                label: Text(
                                  voice.isSpeaking
                                      ? 'Stop Audio'
                                      : (isBlocked
                                            ? '🔊 Listen to Order Confirmation'
                                            : '🔁 Replay Voice Receipt'),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    if (ord != null) ...[
                      const SizedBox(height: 20),
                      Divider(
                        color: colors.outlineVariant.withValues(alpha: 0.45),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'ITEMIZED RECEIPT',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: colors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      ...items.map((item) {
                        final qty = (item['quantity'] as num?)?.toInt() ?? 1;
                        final unit =
                            (item['unit_price'] as num?)?.toDouble() ?? 0.0;
                        final variant = item['selected_variant']?.toString();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  '$qty× ${item['product_name'] ?? 'Product'}${variant != null && variant.isNotEmpty ? ' ($variant)' : ''}',
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: colors.onSurface,
                                  ),
                                ),
                              ),
                              Text(
                                currency.format(unit * qty),
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: colors.onSurface,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                      Divider(
                        height: 22,
                        color: colors.outlineVariant.withValues(alpha: 0.45),
                      ),
                      _receiptRow(
                        'Items Subtotal',
                        currency.format(subtotal),
                        colors,
                      ),
                      if (discount > 0)
                        _receiptRow(
                          'Promo Discount (${ord['promo_code'] ?? 'APPLIED'})',
                          '-${currency.format(discount)}',
                          colors,
                          valueColor: const Color(0xFF10B981),
                        ),
                      _receiptRow(
                        'Estimated Tax (5%)',
                        currency.format(tax),
                        colors,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Total Paid',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: colors.onSurface,
                            ),
                          ),
                          Text(
                            currency.format(total),
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              color: colors.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 22),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(
                                text: _formatInvoiceText(currency),
                              ),
                            );
                            CustomToast.show(
                              context,
                              'Official Invoice copied to clipboard!',
                            );
                          },
                          icon: const Icon(Icons.receipt_long_rounded, size: 18),
                          label: const Text('Copy / Download Invoice'),
                        ),
                        FilledButton.icon(
                          onPressed: () {
                            final email =
                                ord?['customer_email']?.toString() ?? '';
                            context.go(
                              email.isNotEmpty
                                  ? '/orders?email=${Uri.encodeComponent(email)}'
                                  : '/orders',
                            );
                          },
                          icon: const Icon(
                            Icons.local_shipping_outlined,
                            size: 18,
                          ),
                          label: const Text('Track Order & Receipt'),
                        ),
                        TextButton.icon(
                          onPressed: () => context.go('/'),
                          icon: const Icon(Icons.storefront_rounded, size: 18),
                          label: const Text('Continue Shopping'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _receiptRow(
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
              fontSize: 12.5,
              color: colors.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: valueColor ?? colors.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// Phase 2.2: Polished Checkout Cancel Screen
/// Preserves the user's cart intact and offers a one-tap "Retry Stripe Payment" button.
class CheckoutCancelScreen extends StatefulWidget {
  final int? orderId;

  const CheckoutCancelScreen({super.key, this.orderId});

  @override
  State<CheckoutCancelScreen> createState() => _CheckoutCancelScreenState();
}

class _CheckoutCancelScreenState extends State<CheckoutCancelScreen> {
  bool _isRetrying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final voice = context.read<VoiceProvider>();
      if (voice.voiceEnabled && voice.autoSpeakOrderConfirmation) {
        voice.speakText(
          'Payment was cancelled. Your cart items are still saved.',
          label: 'Payment Cancelled',
          preferNeural: true,
        );
      }
    });
  }

  Future<void> _retryPayment() async {
    final oid = widget.orderId;
    if (oid == null || oid <= 0) {
      context.go('/cart');
      return;
    }
    setState(() => _isRetrying = true);
    try {
      await StripePaymentService.startCheckout(orderId: oid, currency: 'usd');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRetrying = false);
      CustomToast.show(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Payment Paused',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w800,
            fontSize: 17,
            color: colors.onSurface,
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.amber.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.lock_clock_rounded,
                      size: 38,
                      color: Colors.amber.shade800,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Stripe Payment Was Cancelled',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No charge was made to your card, and no confirmation email was sent. '
                    'Your shopping cart, selected editions, and promo discounts are safely preserved.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 13.5,
                      height: 1.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _isRetrying ? null : _retryPayment,
                      icon: _isRetrying
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.credit_card_rounded, size: 19),
                      label: Text(
                        _isRetrying
                            ? 'OPENING STRIPE...'
                            : (widget.orderId != null
                                  ? 'RETRY STRIPE PAYMENT (ORDER #${widget.orderId})'
                                  : 'RETURN TO CART & RETRY'),
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: OutlinedButton.icon(
                      onPressed: () => context.go('/cart'),
                      icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                      label: const Text('Return to Cart or Switch to COD'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Phase 5.1: Guided 4-Step Checkout Stepper Banner
/// (`1. Shipping → 2. Review & Promo → 3. Payment → 4. Confirmed`)
class CheckoutStepperBanner extends StatelessWidget {
  final int activeStep;

  const CheckoutStepperBanner({super.key, required this.activeStep});

  static const List<(String, IconData)> _steps = [
    ('1. Shipping', Icons.local_shipping_outlined),
    ('2. Promo & Review', Icons.discount_outlined),
    ('3. Payment', Icons.credit_card_rounded),
    ('4. Confirmed', Icons.verified_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: List.generate(_steps.length, (i) {
          final isDone = i < activeStep;
          final isCurrent = i == activeStep;
          final color = isDone
              ? const Color(0xFF10B981)
              : (isCurrent ? colors.primary : colors.onSurfaceVariant);

          return Expanded(
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: (isDone || isCurrent)
                        ? color.withValues(alpha: 0.16)
                        : colors.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: 1.4),
                  ),
                  child: Icon(
                    isDone ? Icons.check_rounded : _steps[i].$2,
                    size: 14,
                    color: color,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _steps[i].$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: (isDone || isCurrent)
                          ? FontWeight.w800
                          : FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

/// Phase 5.2: Custom GPU-friendly Animated Order Success Checkmark (`CustomPainter`)
class _AnimatedSuccessCheckmark extends StatelessWidget {
  final double size;

  const _AnimatedSuccessCheckmark({this.size = 84});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 850),
      curve: Curves.easeOutBack,
      builder: (context, progress, _) {
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _SuccessCheckPainter(progress: progress.clamp(0.0, 1.0)),
          ),
        );
      },
    );
  }
}

class _SuccessCheckPainter extends CustomPainter {
  final double progress;

  _SuccessCheckPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) * 0.86;

    // Soft glowing outer halo
    final haloPaint = Paint()
      ..color = const Color(0xFF10B981).withValues(alpha: 0.15 * progress)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * (0.95 + 0.15 * progress), haloPaint);

    // Animated progress arc
    final arcPaint = Paint()
      ..color = const Color(0xFF10B981)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      arcPaint,
    );

    // Animated checkmark stroke
    if (progress > 0.35) {
      final checkProgress = ((progress - 0.35) / 0.65).clamp(0.0, 1.0);
      final p1 = Offset(size.width * 0.30, size.height * 0.52);
      final p2 = Offset(size.width * 0.45, size.height * 0.66);
      final p3 = Offset(size.width * 0.72, size.height * 0.37);

      final path = Path()..moveTo(p1.dx, p1.dy);
      if (checkProgress < 0.45) {
        final t = checkProgress / 0.45;
        path.lineTo(
          p1.dx + (p2.dx - p1.dx) * t,
          p1.dy + (p2.dy - p1.dy) * t,
        );
      } else {
        path.lineTo(p2.dx, p2.dy);
        final t = (checkProgress - 0.45) / 0.55;
        path.lineTo(
          p2.dx + (p3.dx - p2.dx) * t,
          p2.dy + (p3.dy - p2.dy) * t,
        );
      }

      final checkPaint = Paint()
        ..color = const Color(0xFF10B981)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, checkPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SuccessCheckPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
