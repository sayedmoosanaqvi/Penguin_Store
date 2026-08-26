import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../../../core/theme/app_colors.dart';

class ProductCardSkeleton extends StatelessWidget {
  const ProductCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.background.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      // Shimmer.fromColors creates that sweeping light animation
      child: Shimmer.fromColors(
        baseColor: Colors.grey[700]!,
        highlightColor: Colors.grey[500]!,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. The Image Placeholder
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
                ),
              ),
            ),

            // 2. The Details Placeholder
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Category pill
                  Container(width: 60, height: 10, color: Colors.white),
                  const SizedBox(height: 10),
                  // Product Name
                  Container(width: 120, height: 14, color: Colors.white),
                  const SizedBox(height: 10),
                  // Rating Stars
                  Container(width: 80, height: 12, color: Colors.white),
                  const SizedBox(height: 12),
                  // Price
                  Container(width: 50, height: 18, color: Colors.white),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}