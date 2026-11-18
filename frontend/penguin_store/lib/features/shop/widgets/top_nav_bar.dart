
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/shop_state_provider.dart';

class TopNavBar extends StatelessWidget implements PreferredSizeWidget {
  const TopNavBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final unreadNotifs = context.watch<ShopStateProvider>().unreadNotifications;
    final primaryColor = theme.primaryColor;

    return AppBar(
      backgroundColor: primaryColor,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      automaticallyImplyLeading: false,
      titleSpacing: 8,
      leadingWidth: 48,
      leading: Builder(
        builder: (context) => IconButton(
          icon: const Icon(Icons.menu_rounded, size: 25),
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
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PenguinBrandLogo(size: 33),
          const SizedBox(width: 9),
          const Flexible(
            child: Text(
              'PenguinStore',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(
            Icons.local_shipping_outlined,
            size: 21,
          ),
          tooltip: 'My Orders',
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
          icon: Badge(
            isLabelVisible: unreadNotifs > 0,
            label: Text(
              unreadNotifs > 9 ? '9+' : '$unreadNotifs',
              style: const TextStyle(fontSize: 9.5),
            ),
            backgroundColor: theme.colorScheme.error,
            child: const Icon(
              Icons.notifications_none_rounded,
              size: 22,
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
}
