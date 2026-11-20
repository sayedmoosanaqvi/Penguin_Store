import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/helpers/theme_provider.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';
import 'package:penguin_store/features/shop/services/showcase_3d_service.dart';

class RightDrawer extends StatelessWidget {
  const RightDrawer({super.key});

  String _currentPath(BuildContext context) {
    try {
      return GoRouterState.of(context).uri.path;
    } catch (_) {
      return '/';
    }
  }

  static const Set<String> _shellRoutes = {
    '/',
    '/discover',
    '/cart',
    '/support',
    '/profile',
  };

  void _navigate(BuildContext context, String route) {
    final current = _currentPath(context);
    Navigator.pop(context);
    if (current == route) return;
    if (_shellRoutes.contains(route)) {
      context.go(route);
    } else {
      context.push(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);
    final cartProvider = Provider.of<CartProvider>(context);
    final shopState = Provider.of<ShopStateProvider>(context);

    final isDark = themeProvider.isDarkMode;
    final isAuthenticated = authProvider.isAuthenticated;
    final isAdmin = authProvider.isAdmin;
    final currentPath = _currentPath(context);

    final drawerBg = isDark ? const Color(0xFF0B1120) : const Color(0xFFF6FAFF);
    final cardBg = isDark ? const Color(0xFF131C31) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor = isDark ? Colors.white60 : const Color(0xFF64748B);

    return Drawer(
      width: 325,
      backgroundColor: drawerBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(left: Radius.circular(28)),
      ),
      child: Column(
        children: [
          _buildArcticHeader(
            context: context,
            isAuthenticated: isAuthenticated,
            isAdmin: isAdmin,
            email: authProvider.userEmail,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
              children: [
                FadeSlideIn.staggered(
                  index: 0,
                  child: _buildQuickStatsRow(
                    context: context,
                    cartCount: cartProvider.itemCount,
                    wishlistCount: shopState.wishlist.length,
                    unreadCount: shopState.unreadNotifications,
                    isDark: isDark,
                  ),
                ),
                const SizedBox(height: 16),
                _buildSectionHeader('EXPLORE STORE', subTextColor),
                FadeSlideIn.staggered(
                  index: 1,
                  child: _buildNavTile(
                    context: context,
                    icon: Icons.storefront_rounded,
                    title: 'Home Showroom',
                    subtitle: 'Featured drops & visual search',
                    route: '/',
                    currentPath: currentPath,
                    isDark: isDark,
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                ),
                FadeSlideIn.staggered(
                  index: 2,
                  child: _buildNavTile(
                    context: context,
                    icon: Icons.explore_rounded,
                    title: 'Discover Categories',
                    subtitle: 'Curated collections & filters',
                    route: '/discover',
                    currentPath: currentPath,
                    isDark: isDark,
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                ),
                FadeSlideIn.staggered(
                  index: 3,
                  child: ValueListenableBuilder<Set<int>>(
                    valueListenable: Catalog3D.ids,
                    builder: (_, ids, _) => _buildNavTile(
                      context: context,
                      icon: Icons.view_in_ar_rounded,
                      title: '3D Models Showroom',
                      subtitle: 'Interactive 360° GLB viewer',
                      route: '/showcase-3d',
                      currentPath: currentPath,
                      isDark: isDark,
                      cardBg: cardBg,
                      textColor: textColor,
                      accentColor: const Color(0xFF00ACC1),
                      trailingBadge: ids.isNotEmpty ? '${ids.length} 3D' : '3D',
                    ),
                  ),
                ),
                FadeSlideIn.staggered(
                  index: 4,
                  child: _buildNavTile(
                    context: context,
                    icon: Icons.auto_awesome_rounded,
                    title: 'CTRL-X AI Assistant',
                    subtitle: 'Autonomous bundles & live trace',
                    route: '/ctrlx',
                    currentPath: currentPath,
                    isDark: isDark,
                    cardBg: cardBg,
                    textColor: textColor,
                    accentColor: const Color(0xFF6366F1),
                    trailingBadge: 'AI',
                  ),
                ),
                const SizedBox(height: 14),
                _buildSectionHeader('YOUR SHOPPING', subTextColor),
                FadeSlideIn.staggered(
                  index: 5,
                  child: _buildNavTile(
                    context: context,
                    icon: Icons.shopping_bag_rounded,
                    title: 'Shopping Cart',
                    subtitle: cartProvider.itemCount > 0
                        ? '${cartProvider.totalUnits} items ready for checkout'
                        : 'Your cart is currently empty',
                    route: '/cart',
                    currentPath: currentPath,
                    isDark: isDark,
                    cardBg: cardBg,
                    textColor: textColor,
                    badgeCount: cartProvider.itemCount,
                  ),
                ),
                FadeSlideIn.staggered(
                  index: 6,
                  child: _buildNavTile(
                    context: context,
                    icon: Icons.favorite_rounded,
                    title: 'Saved Wishlist',
                    subtitle: 'Your favorite items & price alerts',
                    route: '/wishlist',
                    currentPath: currentPath,
                    isDark: isDark,
                    cardBg: cardBg,
                    textColor: textColor,
                    accentColor: const Color(0xFFE11D48),
                    badgeCount: shopState.wishlist.length,
                  ),
                ),
                FadeSlideIn.staggered(
                  index: 7,
                  child: _buildNavTile(
                    context: context,
                    icon: Icons.local_shipping_rounded,
                    title: isAuthenticated ? 'My Orders' : 'Track an Order',
                    subtitle: 'Real-time shipment & delivery status',
                    route: Uri(
                      path: '/orders',
                      queryParameters: {'email': authProvider.userEmail ?? ''},
                    ).toString(),
                    currentPath: currentPath,
                    isDark: isDark,
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                ),
                if (isAuthenticated)
                  FadeSlideIn.staggered(
                    index: 8,
                    child: _buildNavTile(
                      context: context,
                      icon: Icons.manage_accounts_rounded,
                      title: 'Account & Addresses',
                      subtitle: 'Profile, security & notifications',
                      route: '/profile',
                      currentPath: currentPath,
                      isDark: isDark,
                      cardBg: cardBg,
                      textColor: textColor,
                      badgeCount: shopState.unreadNotifications,
                    ),
                  ),
                if (isAdmin) ...[
                  const SizedBox(height: 14),
                  _buildSectionHeader('ADMINISTRATION', const Color(0xFF00ACC1)),
                  FadeSlideIn.staggered(
                    index: 9,
                    child: _buildNavTile(
                      context: context,
                      icon: Icons.admin_panel_settings_rounded,
                      title: 'Admin Studio',
                      subtitle: 'Products, 3D GLB studio, reviews & FYP metrics',
                      route: '/admin',
                      currentPath: currentPath,
                      isDark: isDark,
                      cardBg: cardBg,
                      textColor: textColor,
                      accentColor: const Color(0xFF1E88E5),
                      trailingBadge: 'STUDIO',
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                _buildSectionHeader('PREFERENCES & HELP', subTextColor),
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.07)
                          : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: SwitchListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    secondary: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E88E5).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        isDark
                            ? Icons.nights_stay_rounded
                            : Icons.wb_sunny_rounded,
                        color: const Color(0xFF1E88E5),
                        size: 20,
                      ),
                    ),
                    title: Text(
                      'Arctic Dark Mode',
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    subtitle: Text(
                      isDark ? 'Midnight glacier theme' : 'Daylight ice theme',
                      style: TextStyle(color: subTextColor, fontSize: 11.5),
                    ),
                    value: isDark,
                    activeThumbColor: const Color(0xFF1E88E5),
                    onChanged: (_) => themeProvider.toggleTheme(),
                  ),
                ),
                _buildNavTile(
                  context: context,
                  icon: Icons.support_agent_rounded,
                  title: 'Help & Support Center',
                  subtitle: 'FAQs, policies & live contact',
                  route: '/support',
                  currentPath: currentPath,
                  isDark: isDark,
                  cardBg: cardBg,
                  textColor: textColor,
                ),
              ],
            ),
          ),
          _buildFooterAction(
            context: context,
            authProvider: authProvider,
            isAuthenticated: isAuthenticated,
            isDark: isDark,
            cardBg: cardBg,
          ),
        ],
      ),
    );
  }

  Widget _buildArcticHeader({
    required BuildContext context,
    required bool isAuthenticated,
    required bool isAdmin,
    required String? email,
  }) {
    final displayName = isAuthenticated
        ? (isAdmin
              ? 'Penguin Administrator'
              : (email?.split('@').first ?? 'Valued Customer'))
        : 'Welcome to Penguin Store';

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFF0A192F),
            Color(0xFF1565C0),
            Color(0xFF00ACC1),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(28),
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
        child: SnowfallBackground(
          flakes: 22,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const PenguinBrandLogo(size: 38),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'PENGUIN STORE',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.1,
                              ),
                            ),
                            Text(
                              'AI-Native 3D Commerce',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close Menu',
                        onPressed: () => Navigator.pop(context),
                        icon: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _navigate(
                      context,
                      isAuthenticated ? '/profile' : '/login',
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.24),
                        ),
                      ),
                      child: Row(
                        children: [
                          PenguinAccountAvatar(
                            size: 44,
                            isAuthenticated: isAuthenticated,
                            isAdmin: isAdmin,
                            email: email,
                            lightRingOnPrimaryBar: true,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    if (isAdmin) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.cyanAccent,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: const Text(
                                          'ADMIN',
                                          style: TextStyle(
                                            color: Color(0xFF0A192F),
                                            fontSize: 9,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  isAuthenticated
                                      ? (email ?? 'Verified Session')
                                      : 'Tap to sign in or create account',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white70,
                          ),
                        ],
                      ),
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

  Widget _buildQuickStatsRow({
    required BuildContext context,
    required int cartCount,
    required int wishlistCount,
    required int unreadCount,
    required bool isDark,
  }) {
    Widget pill({
      required IconData icon,
      required String label,
      required String count,
      required Color color,
      required String route,
    }) {
      return Expanded(
        child: PressableScale(
          onTap: () => _navigate(context, route),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF131C31) : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: color.withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 16, color: color),
                    const SizedBox(width: 5),
                    Text(
                      count,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white60 : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill(
          icon: Icons.shopping_bag_rounded,
          label: 'Cart',
          count: '$cartCount',
          color: const Color(0xFF1E88E5),
          route: '/cart',
        ),
        const SizedBox(width: 8),
        pill(
          icon: Icons.favorite_rounded,
          label: 'Wishlist',
          count: '$wishlistCount',
          color: const Color(0xFFE11D48),
          route: '/wishlist',
        ),
        const SizedBox(width: 8),
        ValueListenableBuilder<Set<int>>(
          valueListenable: Catalog3D.ids,
          builder: (_, ids, _) => pill(
            icon: Icons.view_in_ar_rounded,
            label: '3D Models',
            count: '${ids.length}',
            color: const Color(0xFF00ACC1),
            route: '/showcase-3d',
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
      child: Text(
        title,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildNavTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required String route,
    required String currentPath,
    required bool isDark,
    required Color cardBg,
    required Color textColor,
    Color accentColor = const Color(0xFF1E88E5),
    int badgeCount = 0,
    String? trailingBadge,
  }) {
    final isActive = currentPath == route;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PressableScale(
        onTap: () => _navigate(context, route),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isActive
                ? accentColor.withValues(alpha: isDark ? 0.22 : 0.11)
                : cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive
                  ? accentColor.withValues(alpha: 0.65)
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFFE2E8F0)),
              width: isActive ? 1.4 : 1.0,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  gradient: isActive
                      ? LinearGradient(
                          colors: [
                            accentColor,
                            accentColor.withValues(alpha: 0.75),
                          ],
                        )
                      : null,
                  color: isActive
                      ? null
                      : accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: isActive ? Colors.white : accentColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: textColor,
                        fontWeight:
                            isActive ? FontWeight.w800 : FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isDark
                            ? Colors.white60
                            : const Color(0xFF64748B),
                        fontSize: 11.2,
                      ),
                    ),
                  ],
                ),
              ),
              if (badgeCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$badgeCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                )
              else if (trailingBadge != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        accentColor,
                        accentColor.withValues(alpha: 0.78),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    trailingBadge,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: isActive
                      ? accentColor
                      : (isDark ? Colors.white38 : Colors.black26),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooterAction({
    required BuildContext context,
    required AuthProvider authProvider,
    required bool isAuthenticated,
    required bool isDark,
    required Color cardBg,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFE2E8F0),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: isAuthenticated
              ? OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: BorderSide(
                      color: Colors.redAccent.withValues(alpha: 0.45),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () {
                    authProvider.logout();
                    Navigator.pop(context);
                    context.go('/');
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Signed out of Penguin Store.'),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                  },
                  icon: const Icon(Icons.logout_rounded, size: 18),
                  label: const Text(
                    'Sign Out',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                )
              : FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E88E5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => _navigate(context, '/login'),
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text(
                    'Sign In / Create Account',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
        ),
      ),
    );
  }
}
