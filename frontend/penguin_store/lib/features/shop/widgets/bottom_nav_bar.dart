
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';

class BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int>? onTapIndex;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    this.onTapIndex,
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
    final auth = context.watch<AuthProvider>();

    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.grey.withValues(alpha: 0.15),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.04),
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
          indicatorColor: theme.primaryColor.withValues(alpha: 0.12),
          selectedIndex: currentIndex,
          labelBehavior:
              NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (index) {
            if (onTapIndex != null) {
              onTapIndex!(index);
            } else if (index != currentIndex) {
              context.go(_routes[index]);
            }
          },
          destinations: [
            const NavigationDestination(
              tooltip: 'Home Storefront',
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            const NavigationDestination(
              tooltip: 'Discover Catalog',
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view_rounded),
              label: 'Discover',
            ),
            NavigationDestination(
              tooltip: 'Shopping Cart ($cartCount items)',
              icon: TweenAnimationBuilder<double>(
                key: ValueKey('cart-badge-$cartCount'),
                tween: Tween<double>(
                  begin: reduceMotion ? 1.0 : 1.24,
                  end: 1.0,
                ),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Badge(
                  isLabelVisible: cartCount > 0,
                  label: Text(
                    cartCount > 99 ? '99+' : '$cartCount',
                    style: const TextStyle(fontSize: 10),
                  ),
                  backgroundColor: theme.colorScheme.error,
                  child: const Icon(Icons.shopping_bag_outlined),
                ),
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
            NavigationDestination(
              icon: auth.isAuthenticated
                  ? PenguinAccountAvatar(
                      size: 24,
                      isAuthenticated: true,
                      isAdmin: auth.isAdmin,
                      email: auth.userEmail,
                    )
                  : const Icon(Icons.account_circle_outlined),
              selectedIcon: PenguinAccountAvatar(
                size: 26,
                isAuthenticated: auth.isAuthenticated,
                isAdmin: auth.isAdmin,
                email: auth.userEmail,
              ),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
