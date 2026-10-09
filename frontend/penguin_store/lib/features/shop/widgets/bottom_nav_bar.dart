
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';

class BottomNavBar extends StatelessWidget {
  final int currentIndex;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
  });

  static const List<String> _routes = [
    '/',
    '/discover',
    '/cart',
    '/support',
    '/profile',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cartCount = context.watch<CartProvider>().itemCount;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.grey.withOpacity(0.15),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.15 : 0.04),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: NavigationBar(
          height: 62,
          elevation: 0,
          backgroundColor: Colors.transparent,
          indicatorColor: theme.primaryColor.withOpacity(0.12),
          selectedIndex: currentIndex,
          labelBehavior:
              NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (index) {
            if (index != currentIndex) {
              context.go(_routes[index]);
            }
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            const NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view_rounded),
              label: 'Discover',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: cartCount > 0,
                label: Text(
                  cartCount > 99 ? '99+' : '$cartCount',
                  style: const TextStyle(fontSize: 10),
                ),
                backgroundColor: theme.colorScheme.error,
                child: const Icon(Icons.shopping_bag_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: cartCount > 0,
                label: Text(
                  cartCount > 99 ? '99+' : '$cartCount',
                  style: const TextStyle(fontSize: 10),
                ),
                backgroundColor: theme.colorScheme.error,
                child: const Icon(Icons.shopping_bag_rounded),
              ),
              label: 'Cart',
            ),
            const NavigationDestination(
              icon: Icon(Icons.headset_mic_outlined),
              selectedIcon: Icon(Icons.headset_mic_rounded),
              label: 'Support',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
