import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/screens/addresses_screen.dart';
import 'package:penguin_store/features/shop/screens/admin_screen.dart';
import 'package:penguin_store/features/shop/screens/auth_screen.dart';
import 'package:penguin_store/features/shop/screens/cart_screen.dart';
import 'package:penguin_store/features/shop/screens/checkout_result_screens.dart';
import 'package:penguin_store/features/shop/screens/ctrlx_screen.dart';
import 'package:penguin_store/features/shop/screens/discover_screen.dart';
import 'package:penguin_store/features/shop/screens/home_screen.dart';
import 'package:penguin_store/features/shop/screens/mcp_hub_screen.dart';
import 'package:penguin_store/features/shop/screens/notification_screen.dart';
import 'package:penguin_store/features/shop/screens/order_tracking_screen.dart';
import 'package:penguin_store/features/shop/screens/product_details_screen.dart';
import 'package:penguin_store/features/shop/screens/profile_screen.dart';
import 'package:penguin_store/features/shop/screens/showcase_3d_screen.dart';
import 'package:penguin_store/features/shop/screens/support_screen.dart';
import 'package:penguin_store/features/shop/screens/wishlist_screen.dart';
import 'package:penguin_store/features/shop/widgets/bottom_nav_bar.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/',
  errorBuilder: (context, state) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0A0F1D) : const Color(0xFFF3F7FB),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PulsingOrb(
                  icon: Icons.explore_off_rounded,
                  size: 72,
                ),
                const SizedBox(height: 18),
                Text(
                  'Page Not Found',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'The page "${state.uri.path}" does not exist or has moved.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : const Color(0xFF64748B),
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E88E5),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 13,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => context.go('/'),
                  icon: const Icon(Icons.home_rounded),
                  label: const Text(
                    'Return to Penguin Store',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  },
  routes: [
    GoRoute(
      path: '/splash',
      redirect: (_, __) => '/',
    ),

    // StatefulShellRoute keeps HomeScreen, Discover, Cart, Support & Profile
    // alive in an IndexedStack so returning to Home has 0ms delay and preserves
    // exact scroll position & filter state.
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return Scaffold(
          body: navigationShell,
          bottomNavigationBar: BottomNavBar(
            currentIndex: navigationShell.currentIndex,
            onTapIndex: (index) {
              navigationShell.goBranch(
                index,
                initialLocation: index == navigationShell.currentIndex,
              );
            },
          ),
        );
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const HomeScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/discover',
              builder: (context, state) {
                final q = state.uri.queryParameters['q'];
                final cat = state.uri.queryParameters['category'];
                return DiscoverScreen(
                  initialQuery: q,
                  initialCategory: cat,
                );
              },
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/cart',
              builder: (context, state) => const CartScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/support',
              builder: (context, state) => const SupportScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
      ],
    ),

    // Single unified Admin Studio route (with internal AuthProvider guard)
    GoRoute(
      path: '/admin',
      builder: (context, state) {
        final editId = int.tryParse(state.uri.queryParameters['editId'] ?? '');
        return AdminScreen(initialEditProductId: editId);
      },
    ),
    GoRoute(
      path: '/login',
      builder: (context, state) => const AuthScreen(),
    ),
    GoRoute(
      path: '/ctrlx',
      builder: (context, state) {
        final q = state.uri.queryParameters['q'];
        return CtrlXScreen(initialQuery: q);
      },
    ),
    GoRoute(
      path: '/mcp-hub',
      builder: (context, state) => const McpHubScreen(),
    ),
    GoRoute(
      path: '/showcase-3d',
      builder: (context, state) => const Showcase3DScreen(),
    ),
    GoRoute(
      path: '/orders',
      builder: (context, state) {
        final email = state.uri.queryParameters['email'] ?? '';
        return OrderTrackingScreen(customerEmail: email);
      },
    ),
    GoRoute(
      path: '/product/:id',
      builder: (context, state) {
        final productIdStr = state.pathParameters['id'] ?? '0';
        final productId = int.tryParse(productIdStr) ?? 0;
        return ProductDetailScreen(productId: productId);
      },
    ),
    GoRoute(
      path: '/notifications',
      builder: (context, state) {
        final email = state.uri.queryParameters['email'] ?? '';
        return NotificationScreen(userEmail: email);
      },
    ),
    GoRoute(
      path: '/wishlist',
      builder: (context, state) => const WishlistScreen(),
    ),
    GoRoute(
      path: '/addresses',
      builder: (context, state) => const AddressesScreen(),
    ),
    GoRoute(
      path: '/checkout-success',
      builder: (context, state) {
        final sessionId = state.uri.queryParameters['session_id'];
        final orderId = int.tryParse(
          state.uri.queryParameters['order_id'] ?? '',
        );
        final mode = state.uri.queryParameters['mode'];
        final receiptToken = state.uri.queryParameters['receipt_token'];
        return CheckoutSuccessScreen(
          sessionId: sessionId,
          orderId: orderId,
          mode: mode,
          receiptToken: receiptToken,
        );
      },
    ),
    GoRoute(
      path: '/success',
      builder: (context, state) {
        final sessionId = state.uri.queryParameters['session_id'];
        final orderId = int.tryParse(
          state.uri.queryParameters['order_id'] ?? '',
        );
        final mode = state.uri.queryParameters['mode'];
        final receiptToken = state.uri.queryParameters['receipt_token'];
        return CheckoutSuccessScreen(
          sessionId: sessionId,
          orderId: orderId,
          mode: mode,
          receiptToken: receiptToken,
        );
      },
    ),
    GoRoute(
      path: '/checkout-cancel',
      builder: (context, state) {
        final orderId = int.tryParse(
          state.uri.queryParameters['order_id'] ?? '',
        );
        return CheckoutCancelScreen(orderId: orderId);
      },
    ),
    GoRoute(
      path: '/cancel',
      builder: (context, state) {
        final orderId = int.tryParse(
          state.uri.queryParameters['order_id'] ?? '',
        );
        return CheckoutCancelScreen(orderId: orderId);
      },
    ),
  ],
);
