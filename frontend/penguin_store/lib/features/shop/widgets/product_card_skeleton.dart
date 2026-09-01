import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

class ProductCardSkeleton extends StatelessWidget {
  const ProductCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: isLight ? Colors.grey.withOpacity(0.1) : Colors.black.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Shimmer.fromColors(
        baseColor: isLight ? Colors.grey[300]! : Colors.grey[800]!,
        highlightColor: isLight ? Colors.grey[100]! : Colors.grey[600]!,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.cardTheme.color ?? theme.colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(width: 60, height: 10, color: Colors.white),
                  const SizedBox(height: 10),
                  Container(width: 120, height: 14, color: Colors.white),
                  const SizedBox(height: 10),
                  Container(width: 80, height: 12, color: Colors.white),
                  const SizedBox(height: 12),
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