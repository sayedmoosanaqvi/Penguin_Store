
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:penguin_store/config/api_config.dart';

class PersonalizedCarousel extends StatefulWidget {
  final String userEmail;

  const PersonalizedCarousel({
    super.key,
    required this.userEmail,
  });

  @override
  State<PersonalizedCarousel> createState() =>
      _PersonalizedCarouselState();
}

class _PersonalizedCarouselState extends State<PersonalizedCarousel> {
  List<dynamic> _recommendedProducts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchRecommendations();
  }

  @override
  void didUpdateWidget(covariant PersonalizedCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.userEmail != widget.userEmail) {
      _fetchRecommendations();
    }
  }

  Future<void> _fetchRecommendations() async {
    setState(() => _isLoading = true);

    try {
      final url = Uri.parse(
        '${ApiConfig.baseUrl}/api/recommendations/for-user',
      ).replace(
        queryParameters: {
          'email': widget.userEmail,
          'limit': '5',
        },
      );

      final response = await http.get(url);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        setState(() {
          _recommendedProducts =
              data is Map && data['products'] is List
                  ? List<dynamic>.from(data['products'])
                  : [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _recommendedProducts = [];
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching recommendations: $e');

      if (!mounted) return;

      setState(() {
        _recommendedProducts = [];
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;

    if (_isLoading || _recommendedProducts.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth >= 900
            ? 165.0
            : constraints.maxWidth >= 600
                ? 145.0
                : 122.0;

        final cardHeight = cardWidth * 1.47;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 11),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      color: theme.colorScheme.secondary,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Recommended For You',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          'Personalized AI product suggestions',
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: primary.withOpacity(0.09),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      'FOR YOU',
                      style: TextStyle(
                        color: primary,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: cardHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _recommendedProducts.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: 9),
                itemBuilder: (context, index) {
                  final raw = _recommendedProducts[index];

                  if (raw is! Map) {
                    return const SizedBox.shrink();
                  }

                  final product = raw;
                  final id = product['id'];
                  final name =
                      (product['name'] ?? 'Recommended Product').toString();
                  final imageUrl =
                      (product['image_url'] ?? '').toString();

                  final rawPrice = product['price'];
                  final parsedPrice = rawPrice is num
                      ? rawPrice.toDouble()
                      : double.tryParse(rawPrice?.toString() ?? '');

                  final priceText = parsedPrice == null
                      ? null
                      : '\$${parsedPrice.toStringAsFixed(2)}';

                  return SizedBox(
                    width: cardWidth,
                    child: Material(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(11),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(11),
                        onTap: id == null
                            ? null
                            : () => context.push('/product/$id'),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: theme.dividerColor.withOpacity(0.16),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius:
                                          const BorderRadius.vertical(
                                        top: Radius.circular(10),
                                      ),
                                      child: Image.network(
                                        imageUrl,
                                        fit: BoxFit.contain,
                                        errorBuilder:
                                            (context, error, stack) {
                                          return Container(
                                            color: primary.withOpacity(0.04),
                                            child: Icon(
                                              Icons.image_not_supported_outlined,
                                              color: theme.colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    Positioned(
                                      top: 7,
                                      left: 7,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: primary,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.auto_awesome,
                                              color: Colors.white,
                                              size: 11,
                                            ),
                                            SizedBox(width: 3),
                                            Text(
                                              'AI PICK',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 9,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  8, 8, 8, 9,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: theme.colorScheme.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    if (priceText != null)
                                      Text(
                                        priceText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: primary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      )
                                    else
                                      Text(
                                        'View Product',
                                        style: TextStyle(
                                          color: primary,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
          ],
        );
      },
    );
  }
}
