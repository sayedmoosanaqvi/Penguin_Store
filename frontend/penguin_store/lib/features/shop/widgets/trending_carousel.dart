import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:go_router/go_router.dart'; // Added for navigation

class TrendingCarousel extends StatefulWidget {
  final String country;
  
  const TrendingCarousel({super.key, this.country = "Pakistan"});

  @override
  State<TrendingCarousel> createState() => _TrendingCarouselState();
}

class _TrendingCarouselState extends State<TrendingCarousel> {
  List<dynamic> _trendingProducts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchTrending();
  }

  Future<void> _fetchTrending() async {
    try {
      // Note: Use 10.0.2.2 instead of 127.0.0.1 if testing on an Android Emulator
      final url = Uri.parse('http://127.0.0.1:8000/api/trending/top-10?country=${widget.country}');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _trendingProducts = data['products'];
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching trends: $e');
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeColors = Theme.of(context).colorScheme;

    if (_isLoading) {
      return SizedBox(
        height: 250, 
        child: Center(
          child: CircularProgressIndicator(
            color: themeColors.primary, 
          ),
        ),
      );
    }

    if (_trendingProducts.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Text(
            "Top 10 in ${widget.country} Today",
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: themeColors.onSurface, 
            ),
          ),
        ),
        SizedBox(
          height: 220,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: _trendingProducts.length,
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            itemBuilder: (context, index) {
              final product = _trendingProducts[index];
              
              // --- ADDED: GestureDetector to make the cards clickable ---
              return GestureDetector(
                onTap: () {
                  // Adjust this route string to match exactly how you configured 
                  // your product details page in your GoRouter setup!
                  context.push('/product/${product['id']}');
                },
                child: Container(
                  width: 140,
                  margin: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            product['image_url'],
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => 
                              ColoredBox(color: themeColors.surfaceContainerHighest),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: LinearGradient(
                              colors: [
                                themeColors.primary.withOpacity(0.8), 
                                Colors.transparent
                              ],
                              begin: Alignment.bottomCenter,
                              end: Alignment.center,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: -5,
                        bottom: -10,
                        child: Text(
                          "${index + 1}",
                          style: TextStyle(
                            fontSize: 80,
                            fontWeight: FontWeight.w900,
                            color: themeColors.onPrimary, 
                            shadows: [
                              Shadow(
                                offset: const Offset(2, 2),
                                blurRadius: 4,
                                color: themeColors.shadow.withOpacity(0.5),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}