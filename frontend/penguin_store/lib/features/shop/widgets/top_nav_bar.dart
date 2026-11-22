import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/core/providers/voice_provider.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/currency_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/widgets/product_comparison_sheet.dart';

class TopNavBar extends StatelessWidget implements PreferredSizeWidget {
  const TopNavBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final shopState = context.watch<ShopStateProvider>();
    final currency = context.watch<CurrencyProvider>();
    final unreadNotifs = shopState.unreadNotifications;
    final compareCount = shopState.compareList.length;
    final primaryColor = theme.primaryColor;

    return AppBar(
      backgroundColor: primaryColor,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      automaticallyImplyLeading: false,
      titleSpacing: 6,
      leadingWidth: 46,
      leading: Builder(
        builder: (context) => IconButton(
          icon: const Icon(Icons.menu_rounded, size: 24),
          tooltip: 'Menu',
          onPressed: () {
            final scaffold = Scaffold.maybeOf(context);
            if (scaffold?.hasDrawer == true) {
              scaffold!.openDrawer();
            } else if (scaffold?.hasEndDrawer == true) {
              scaffold!.openEndDrawer();
            }
          },
        ),
      ),
      title: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => context.go('/'),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PenguinBrandLogo(size: 32),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                'PenguinStore',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Live Multi-Currency Switcher (USD / PKR / EUR)
        PopupMenuButton<String>(
          tooltip: 'Currency (${currency.code})',
          onSelected: (code) => currency.setCurrency(code),
          itemBuilder: (context) => CurrencyProvider.supported
              .map(
                (opt) => PopupMenuItem<String>(
                  value: opt.code,
                  child: Row(
                    children: [
                      Icon(
                        opt.code == currency.code
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_off_rounded,
                        size: 17,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        opt.label,
                        style: TextStyle(
                          fontWeight: opt.code == currency.code
                              ? FontWeight.w800
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  currency.code,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Icon(
                  Icons.arrow_drop_down_rounded,
                  color: Colors.white,
                  size: 16,
                ),
              ],
            ),
          ),
        ),

        // Voice Control Pill (Mute / Settings)
        Consumer<VoiceProvider>(
          builder: (context, voice, _) {
            return IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: voice.voiceEnabled
                  ? 'Voice Mode On (${voice.speechRatePreset}) • Tap for settings'
                  : 'Voice Mode Muted • Tap to enable',
              onPressed: () => _showVoiceSettingsSheet(context),
              icon: Icon(
                voice.isSpeaking
                    ? Icons.graphic_eq_rounded
                    : (voice.voiceEnabled
                          ? Icons.volume_up_rounded
                          : Icons.volume_off_rounded),
                color: voice.isSpeaking
                    ? const Color(0xFF00E5FF)
                    : (voice.voiceEnabled ? Colors.white : Colors.white60),
                size: 20,
              ),
            );
          },
        ),

        // Side-by-Side Compare Tray button
        if (compareCount > 0)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Compare Products ($compareCount/3)',
            onPressed: () => showProductComparisonSheet(context),
            icon: Badge(
              label: Text(
                '$compareCount',
                style: const TextStyle(fontSize: 9.5),
              ),
              backgroundColor: const Color(0xFF00ACC1),
              child: const Icon(Icons.compare_arrows_rounded, size: 21),
            ),
          ),

        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(
            Icons.local_shipping_outlined,
            size: 20,
          ),
          tooltip: 'My Orders & Invoices',
          onPressed: () {
            final email = auth.userEmail ?? '';
            context.push(
              Uri(
                path: '/orders',
                queryParameters: {'email': email},
              ).toString(),
            );
          },
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Badge(
            isLabelVisible: unreadNotifs > 0,
            label: Text(
              unreadNotifs > 9 ? '9+' : '$unreadNotifs',
              style: const TextStyle(fontSize: 9.5),
            ),
            backgroundColor: theme.colorScheme.error,
            child: const Icon(
              Icons.notifications_none_rounded,
              size: 21,
            ),
          ),
          tooltip: 'Notifications',
          onPressed: () {
            final email = auth.userEmail ?? '';
            context.push(
              Uri(
                path: '/notifications',
                queryParameters: {'email': email},
              ).toString(),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.only(right: 10, left: 2),
          child: Tooltip(
            message: auth.isAuthenticated
                ? (auth.userEmail ?? 'My Account')
                : 'Account & Sign In',
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => context.go('/profile'),
              child: PenguinAccountAvatar(
                size: 32,
                isAuthenticated: auth.isAuthenticated,
                isAdmin: auth.isAdmin,
                email: auth.userEmail,
                lightRingOnPrimaryBar: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showVoiceSettingsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return Consumer<VoiceProvider>(
          builder: (ctx, voice, _) {
            final colors = Theme.of(ctx).colorScheme;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.record_voice_over_rounded,
                            color: colors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Voice Intelligence Controls',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        if (voice.isSpeaking)
                          FilledButton.tonalIcon(
                            onPressed: voice.stopSpeaking,
                            icon: const Icon(Icons.stop_rounded, size: 16),
                            label: const Text('Stop Audio'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enable Spoken Feedback (TTS)'),
                      subtitle: const Text(
                        'Allow Penguin Store to read confirmations and summaries aloud',
                      ),
                      value: voice.voiceEnabled,
                      onChanged: voice.setVoiceEnabled,
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto-Speak Order Confirmation'),
                      subtitle: const Text(
                        'Speak Order ID & total after Stripe/COD checkout',
                      ),
                      value: voice.autoSpeakOrderConfirmation,
                      onChanged: voice.setAutoSpeakOrderConfirmation,
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Always Auto-Speak CTRL-X Replies'),
                      subtitle: const Text(
                        'Also read typed chat replies aloud (mic prompts always auto-speak)',
                      ),
                      value: voice.autoSpeakCtrlX,
                      onChanged: voice.setAutoSpeakCtrlX,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Speech Speed',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'Slow', label: Text('Slow')),
                        ButtonSegment(value: 'Normal', label: Text('Normal')),
                        ButtonSegment(value: 'Fast', label: Text('Fast')),
                      ],
                      selected: {voice.speechRatePreset},
                      onSelectionChanged: (sel) =>
                          voice.setSpeechRatePreset(sel.first),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
