import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import 'package:provider/provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:penguin_store/features/shop/screens/cart_screen.dart';

class TopNavBar extends StatelessWidget implements PreferredSizeWidget {
  const TopNavBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      titleSpacing: 24,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.storefront,
              color: AppColors.background,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          const Flexible(
            child: Text(
              'PenguinStore',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.whiteText,
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
                backgroundColor: Colors.redAccent,
                offset: const Offset(-5, 5),
                child: IconButton(
                  icon: const Icon(
                    Icons.shopping_bag_outlined,
                    color: AppColors.whiteText,
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
          icon: const Icon(Icons.local_shipping_outlined, color: AppColors.whiteText),
          tooltip: 'My Orders',
          onPressed: () {
            context.push('/orders');
          },
        ),
        IconButton(
          icon: const Icon(Icons.menu, color: AppColors.whiteText),
          onPressed: () {
            Scaffold.of(context).openEndDrawer();
          },
        ),
        const SizedBox(width: 16),
      ],
    );
  }
}