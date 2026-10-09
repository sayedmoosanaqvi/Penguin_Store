
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';

class TopNavBar extends StatelessWidget implements PreferredSizeWidget {
  const TopNavBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
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
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.16),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.storefront_rounded,
              color: Colors.white,
              size: 21,
            ),
          ),
          const SizedBox(width: 8),
          const Flexible(
            child: Text(
              'PenguinStore',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
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
            size: 22,
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
          icon: const Icon(
            Icons.notifications_none_rounded,
            size: 24,
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
        const SizedBox(width: 6),
      ],
    );
  }
}
