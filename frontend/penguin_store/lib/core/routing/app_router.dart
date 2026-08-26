import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/shop/screens/home_screen.dart';
import '../../features/shop/screens/ctrlx_screen.dart';
import '../../features/shop/screens/order_tracking_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/ctrlx',
      builder: (context, state) => const CtrlXScreen(),
    ),
    GoRoute(
      path: '/orders',
      builder: (context, state) {
        // You can pass email via query params or fallback to your test email
        final email = state.uri.queryParameters['email'] ?? 'moosa@penguin.com';
        return OrderTrackingScreen(customerEmail: email);
      },
    ),
    GoRoute(
      path: '/success',
      builder: (context, state) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 80),
              const SizedBox(height: 16),
              const Text(
                'Payment Successful!',
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your order has been placed and dispatched.',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.go('/'),
                child: const Text('Back to Home'),
              ),
            ],
          ),
        ),
      ),
    ),
    GoRoute(
      path: '/cancel',
      builder: (context, state) => const HomeScreen(),
    ),
  ],
);