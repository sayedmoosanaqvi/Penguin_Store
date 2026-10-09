
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:penguin_store/features/shop/screens/home_screen.dart';
import 'package:penguin_store/features/shop/screens/ctrlx_screen.dart';
import 'package:penguin_store/features/shop/screens/order_tracking_screen.dart';
import 'package:penguin_store/features/shop/screens/product_details_screen.dart';
import 'package:penguin_store/features/shop/screens/notification_screen.dart';
import 'package:penguin_store/features/shop/screens/splash_screen.dart';
import 'package:penguin_store/features/shop/screens/cart_screen.dart';
import 'package:penguin_store/features/shop/screens/discover_screen.dart';
import 'package:penguin_store/features/shop/screens/support_screen.dart';
import 'package:penguin_store/features/shop/screens/profile_screen.dart';
import 'package:penguin_store/features/shop/services/notification_service.dart';
import 'package:penguin_store/features/shop/widgets/bottom_nav_bar.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/splash',
  routes: [
    GoRoute(
      path: '/splash',
      builder: (context, state) => const SplashScreen(),
    ),

    ShellRoute(
      builder: (context, state, child) {
        final path = state.uri.path;

        int currentIndex = 0;

        switch (path) {
          case '/discover':
            currentIndex = 1;
            break;
          case '/cart':
            currentIndex = 2;
            break;
          case '/support':
            currentIndex = 3;
            break;
          case '/profile':
            currentIndex = 4;
            break;
        }

        return Scaffold(
          body: child,
          bottomNavigationBar: BottomNavBar(
            currentIndex: currentIndex,
          ),
        );
      },
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: '/discover',
          builder: (context, state) => const DiscoverScreen(),
        ),
        GoRoute(
          path: '/cart',
          builder: (context, state) => const CartScreen(),
        ),
        GoRoute(
          path: '/support',
          builder: (context, state) => const SupportScreen(),
        ),
        GoRoute(
          path: '/profile',
          builder: (context, state) => const ProfileScreen(),
        ),
      ],
    ),

    GoRoute(
      path: '/ctrlx',
      builder: (context, state) => const CtrlXScreen(),
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
      path: '/success',
      builder: (context, state) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          NotificationService.showPushBanner(
            context,
            'Payment Successful! 🎉',
            'Your order is confirmed and processing.',
          );
        });

        return Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Colors.green,
                  size: 80,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Payment Successful!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your order has been placed and dispatched.',
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => context.go('/'),
                  child: const Text('Back to Home'),
                ),
              ],
            ),
          ),
        );
      },
    ),
    GoRoute(
      path: '/cancel',
      builder: (context, state) => const HomeScreen(),
    ),
  ],
);
