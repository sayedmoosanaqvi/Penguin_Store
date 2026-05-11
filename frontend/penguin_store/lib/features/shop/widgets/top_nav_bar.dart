import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import 'package:provider/provider.dart';
// FIXED: Changed 'auth' to 'shop' to match your actual folder structure
import 'package:penguin_store/features/shop/providers/cart_provider.dart';

class TopNavBar extends StatelessWidget implements PreferredSizeWidget {
  const TopNavBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.primaryBlack,
      elevation: 0,
      titleSpacing: 24,
      // FIXED: Wrap in a flexible container or ensure constraints
      title: Row(
        mainAxisSize: MainAxisSize.min, // Prevents row from taking infinite width
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.accentYellow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.storefront,
              color: AppColors.primaryBlack,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          // Using Flexible helps prevent overflow on smaller screens
          const Flexible(
            child: Text(
              'PenguinStore',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.pureWhite,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
        ],
      ),
      actions: [
        // 1. THE LIVE CART BADGE
        // Added a ConstrainedBox to stop the 99,653 pixel error!
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
                    color: AppColors.pureWhite,
                  ),
                  onPressed: () {
                    // This will work now that the Provider is found!
                    print("Cart tapped: ${cart.itemCount}");
                  },
                ),
              );
            },
          ),
        ),

        // 2. THE DRAWER MENU
        IconButton(
          icon: const Icon(Icons.menu, color: AppColors.pureWhite),
          onPressed: () {
            Scaffold.of(context).openEndDrawer();
          },
        ),
        const SizedBox(width: 16),
      ],
    );
  }
}