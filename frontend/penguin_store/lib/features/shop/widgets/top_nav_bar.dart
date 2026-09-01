import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/screens/cart_screen.dart';

class TopNavBar extends StatelessWidget implements PreferredSizeWidget {
  const TopNavBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    // Grab the global theme
    final theme = Theme.of(context); 

    return AppBar(
      backgroundColor: theme.appBarTheme.backgroundColor ?? theme.scaffoldBackgroundColor,
      elevation: theme.appBarTheme.elevation ?? 0,
      titleSpacing: 24,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: theme.primaryColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.storefront,
              color: theme.scaffoldBackgroundColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'PenguinStore',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.appBarTheme.foregroundColor,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
        ],
      ),
      actions: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 48),
          child: Consumer<CartProvider>(
            builder: (context, cart, child) {
              return Badge(
                label: Text(
                  cart.itemCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                isLabelVisible: cart.itemCount > 0,
                backgroundColor: theme.colorScheme.error,
                offset: const Offset(-5, 5),
                child: IconButton(
                  icon: Icon(
                    Icons.shopping_bag_outlined,
                    color: theme.appBarTheme.foregroundColor,
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const CartScreen()),
                    );
                  },
                ),
              );
            },
          ),
        ),
        // NEW: Orders & Tracking Button added here
        IconButton(
          icon: Icon(Icons.local_shipping_outlined, color: theme.appBarTheme.foregroundColor),
          tooltip: 'My Orders',
          onPressed: () {
            context.push('/orders');
          },
        ),
        IconButton(
          icon: Icon(Icons.menu, color: theme.appBarTheme.foregroundColor),
          onPressed: () {
            Scaffold.of(context).openEndDrawer();
          },
        ),
        const SizedBox(width: 16),
      ],
    );
  }
}