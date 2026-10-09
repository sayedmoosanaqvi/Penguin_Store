
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/screens/auth_screen.dart';
import 'package:penguin_store/features/shop/screens/admin_screen.dart';
import 'package:penguin_store/helpers/theme_provider.dart';

class RightDrawer extends StatelessWidget {
  const RightDrawer({super.key});

  void _navigate(BuildContext context, String route) {
    Navigator.of(context).pop();
    context.go(route);
  }

  void _openPage(BuildContext context, String route) {
    Navigator.of(context).pop();
    context.push(route);
  }

  void _openLogin(BuildContext context) {
    Navigator.of(context).pop();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AuthScreen(),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final auth = context.read<AuthProvider>();
    Navigator.of(context).pop();

    await auth.logout();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Successfully logged out')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final primary = theme.primaryColor;
    final isDark = theme.brightness == Brightness.dark;

    final email = auth.userEmail ?? '';

    return Drawer(
      width: 300,
      backgroundColor: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 20,
              left: 18,
              right: 18,
              bottom: 20,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  primary,
                  theme.colorScheme.tertiary,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 43,
                      height: 43,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.17),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        Icons.storefront_rounded,
                        color: Colors.white,
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Penguin Store',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close Menu',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 21,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 23,
                      backgroundColor: Colors.white,
                      child: Icon(
                        Icons.person_rounded,
                        color: primary,
                        size: 27,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            auth.isAuthenticated
                                ? 'Welcome Back!'
                                : 'Welcome, Guest!',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            auth.isAuthenticated
                                ? email
                                : 'Log in to manage your account',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                          if (auth.isAdmin)
                            const Padding(
                              padding: EdgeInsets.only(top: 5),
                              child: Text(
                                'ADMINISTRATOR',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                _sectionTitle('SHOPPING', theme),
                _drawerTile(
                  context,
                  icon: Icons.home_outlined,
                  title: 'Home',
                  onTap: () => _navigate(context, '/'),
                ),
                _drawerTile(
                  context,
                  icon: Icons.grid_view_outlined,
                  title: 'Discover Categories',
                  onTap: () => _navigate(context, '/discover'),
                ),
                _drawerTile(
                  context,
                  icon: Icons.shopping_bag_outlined,
                  title: 'My Cart',
                  onTap: () => _navigate(context, '/cart'),
                ),
                _drawerTile(
                  context,
                  icon: Icons.local_shipping_outlined,
                  title: 'My Orders',
                  onTap: () {
                    _openPage(
                      context,
                      Uri(
                        path: '/orders',
                        queryParameters: {'email': email},
                      ).toString(),
                    );
                  },
                ),
                _divider(theme),
                _sectionTitle('ACCOUNT', theme),
                _drawerTile(
                  context,
                  icon: Icons.person_outline_rounded,
                  title: 'My Profile',
                  onTap: () => _navigate(context, '/profile'),
                ),
                _drawerTile(
                  context,
                  icon: Icons.notifications_none_rounded,
                  title: 'Notifications',
                  onTap: () {
                    _openPage(
                      context,
                      Uri(
                        path: '/notifications',
                        queryParameters: {'email': email},
                      ).toString(),
                    );
                  },
                ),
                _divider(theme),
                _sectionTitle('HELP & SUPPORT', theme),
                _drawerTile(
                  context,
                  icon: Icons.help_outline_rounded,
                  title: 'Help Center & FAQs',
                  onTap: () => _navigate(context, '/support'),
                ),
                _drawerTile(
                  context,
                  icon: Icons.smart_toy_outlined,
                  title: 'CTRL-X AI Agent',
                  subtitle: 'Products, orders & AI assistance',
                  onTap: () => _openPage(context, '/ctrlx'),
                ),
                _divider(theme),
                _sectionTitle('PREFERENCES', theme),
                SwitchListTile(
                  dense: true,
                  value: themeProvider.isDarkMode,
                  activeColor: primary,
                  secondary: Icon(
                    isDark
                        ? Icons.dark_mode_outlined
                        : Icons.light_mode_outlined,
                    color: primary,
                    size: 21,
                  ),
                  title: const Text(
                    'Dark Mode',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onChanged: (value) {
                    themeProvider.setTheme(
                      value ? ThemeMode.dark : ThemeMode.light,
                    );
                  },
                ),
                if (auth.isAdmin) ...[
                  _divider(theme),
                  _sectionTitle('ADMINISTRATION', theme),
                  _drawerTile(
                    context,
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Admin Dashboard',
                    onTap: () {
                      Navigator.of(context).pop();

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AdminScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: theme.dividerColor.withOpacity(0.2),
                ),
              ),
            ),
            child: Column(
              children: [
                if (auth.isAuthenticated)
                  _drawerTile(
                    context,
                    icon: Icons.logout_rounded,
                    title: 'Log Out',
                    color: theme.colorScheme.error,
                    onTap: () => _logout(context),
                  )
                else
                  _drawerTile(
                    context,
                    icon: Icons.login_rounded,
                    title: 'Log In / Register',
                    onTap: () => _openLogin(context),
                  ),
                const SizedBox(height: 5),
                Text(
                  'Penguin Store',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 7),
      child: Text(
        title,
        style: TextStyle(
          color: theme.primaryColor,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _divider(ThemeData theme) {
    return Divider(
      height: 20,
      indent: 16,
      endIndent: 16,
      color: theme.dividerColor.withOpacity(0.2),
    );
  }

  Widget _drawerTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    String? subtitle,
    Color? color,
  }) {
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 1,
      ),
      leading: Icon(
        icon,
        color: color ?? theme.primaryColor,
        size: 21,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: color ?? theme.colorScheme.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 17,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
