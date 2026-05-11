import 'package:go_router/go_router.dart';
import '../../features/shop/screens/home_screen.dart';

// This is the router configuration that main.dart was looking for!
final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    // We will add more routes here later, like:
    // GoRoute(path: '/cart', builder: (context, state) => const CartScreen()),
    // GoRoute(path: '/ai-chat', builder: (context, state) => const AiChatScreen()),
  ],
);