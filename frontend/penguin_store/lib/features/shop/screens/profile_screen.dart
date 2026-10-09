
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/screens/auth_screen.dart';
import 'package:penguin_store/features/shop/screens/admin_screen.dart';
import 'package:penguin_store/helpers/theme_provider.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  void _openLogin(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AuthScreen(),
      ),
    );
  }

  void _openOrders(BuildContext context, String? email) {
    context.push(
      Uri(
        path: '/orders',
        queryParameters: {'email': email ?? ''},
      ).toString(),
    );
  }

  void _openNotifications(BuildContext context, String? email) {
    context.push(
      Uri(
        path: '/notifications',
        queryParameters: {'email': email ?? ''},
      ).toString(),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text(
          'Are you sure you want to log out of Penguin Store?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (confirm != true || !context.mounted) return;

    await context.read<AuthProvider>().logout();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Successfully logged out'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final themeProvider = context.watch<ThemeProvider>();

    final isDark = theme.brightness == Brightness.dark;
    final color = theme.primaryColor;
    final email = auth.userEmail;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: const Text(
          'My Dashboard',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => _openNotifications(context, email),
            icon: const Icon(Icons.notifications_none_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 30),
            children: [
              Container(
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: theme.dividerColor.withOpacity(0.16),
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: color.withOpacity(0.10),
                      child: Icon(
                        auth.isAuthenticated
                            ? Icons.person_rounded
                            : Icons.person_outline_rounded,
                        size: 30,
                        color: color,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            auth.isAuthenticated
                                ? 'Welcome Back!'
                                : 'Welcome to Penguin Store',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            auth.isAuthenticated
                                ? (email ?? 'Signed in')
                                : 'Sign in to manage your account',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (auth.isAdmin) ...[
                            const SizedBox(height: 5),
                            Text(
                              'Administrator',
                              style: TextStyle(
                                color: color,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (!auth.isAuthenticated)
                      IconButton.filledTonal(
                        tooltip: 'Log In or Register',
                        onPressed: () => _openLogin(context),
                        icon: const Icon(Icons.login_rounded),
                      ),
                  ],
                ),
              ),
              if (!auth.isAuthenticated) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _openLogin(context),
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('LOG IN / REGISTER'),
                  ),
                ),
              ],
              const SizedBox(height: 18),

              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final spacing = 12.0;
                  final cardWidth = (width - spacing) / 2;

                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      SizedBox(
                        width: cardWidth,
                        child: _DashboardCard(
                          icon: Icons.local_shipping_outlined,
                          title: 'My Orders',
                          subtitle: 'Track & view orders',
                          color: const Color(0xFF00ACC1),
                          onTap: () => _openOrders(context, email),
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _DashboardCard(
                          icon: Icons.smart_toy_outlined,
                          title: 'CTRL-X Agent',
                          subtitle: 'AI order assistance',
                          color: const Color(0xFF8E63D9),
                          onTap: () => context.push('/ctrlx'),
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _DashboardCard(
                          icon: Icons.shopping_bag_outlined,
                          title: 'My Cart',
                          subtitle: 'Shopping basket',
                          color: const Color(0xFFEB9A21),
                          onTap: () => context.go('/cart'),
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _DashboardCard(
                          icon: Icons.notifications_none_rounded,
                          title: 'Notifications',
                          subtitle: 'Order updates',
                          color: const Color(0xFF23A56A),
                          onTap: () => _openNotifications(context, email),
                        ),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 19),

              _SectionCard(
                theme: theme,
                children: [
                  _ProfileTile(
                    icon: Icons.receipt_long_outlined,
                    title: 'Order History & Tracking',
                    subtitle: 'View orders and tracking information',
                    onTap: () => _openOrders(context, email),
                  ),
                  _ProfileTile(
                    icon: Icons.auto_awesome_outlined,
                    title: 'Ask CTRL-X About Your Order',
                    subtitle: 'Get AI assistance with order details',
                    onTap: () => context.push('/ctrlx'),
                  ),
                  _ProfileTile(
                    icon: Icons.grid_view_rounded,
                    title: 'Discover Products',
                    subtitle: 'Explore products and categories',
                    onTap: () => context.go('/discover'),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              Text(
                'Account & Support',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),

              _SectionCard(
                theme: theme,
                children: [
                  _ProfileTile(
                    icon: Icons.person_outline_rounded,
                    title: 'Account Information',
                    subtitle: auth.isAuthenticated
                        ? (email ?? 'Signed in')
                        : 'Log in to access your account',
                    onTap: () {
                      if (!auth.isAuthenticated) {
                        _openLogin(context);
                      } else {
                        showDialog<void>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Account Information'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Email Address',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SelectableText(email ?? 'Not available'),
                                const SizedBox(height: 12),
                                Text(
                                  auth.isAdmin
                                      ? 'Role: Administrator'
                                      : 'Role: Customer',
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        );
                      }
                    },
                  ),
                  _ProfileTile(
                    icon: Icons.help_outline_rounded,
                    title: 'FAQ & Support',
                    subtitle: 'Help center and frequently asked questions',
                    onTap: () => context.go('/support'),
                  ),
                  _ProfileTile(
                    icon: Icons.support_agent_rounded,
                    title: 'AI Customer Support',
                    subtitle: 'Chat with CTRL-X assistant',
                    onTap: () => context.push('/ctrlx'),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              Text(
                'Preferences',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),

              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: theme.dividerColor.withOpacity(0.16),
                  ),
                ),
                child: SwitchListTile(
                  secondary: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.09),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      isDark
                          ? Icons.dark_mode_outlined
                          : Icons.light_mode_outlined,
                      color: color,
                      size: 22,
                    ),
                  ),
                  title: const Text(
                    'Dark Mode',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: const Text(
                    'Customize app appearance',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: themeProvider.isDarkMode,
                  activeColor: color,
                  onChanged: (value) {
                    themeProvider.setTheme(
                      value ? ThemeMode.dark : ThemeMode.light,
                    );
                  },
                ),
              ),

              if (auth.isAdmin) ...[
                const SizedBox(height: 16),
                Text(
                  'Administration',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 10),
                _SectionCard(
                  theme: theme,
                  children: [
                    _ProfileTile(
                      icon: Icons.admin_panel_settings_outlined,
                      title: 'Admin Dashboard',
                      subtitle: 'Manage Penguin Store',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AdminScreen(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],

              if (auth.isAuthenticated) ...[
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: () => _logout(context),
                  icon: const Icon(Icons.logout),
                  label: const Text('Log Out'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(
                      color: theme.colorScheme.error.withOpacity(0.4),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),
              Center(
                child: Text(
                  'Penguin Store',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _DashboardCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: theme.dividerColor.withOpacity(0.16),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 43,
                height: 43,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.11),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: color, size: 23),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.3,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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
}

class _SectionCard extends StatelessWidget {
  final ThemeData theme;
  final List<Widget> children;

  const _SectionCard({
    required this.theme,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: theme.dividerColor.withOpacity(0.16),
        ),
      ),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Divider(
                height: 1,
                indent: 65,
                color: theme.dividerColor.withOpacity(0.16),
              ),
          ],
        ],
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ProfileTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 5,
      ),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: theme.primaryColor.withOpacity(0.09),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: theme.primaryColor,
          size: 22,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        size: 20,
      ),
    );
  }
}
