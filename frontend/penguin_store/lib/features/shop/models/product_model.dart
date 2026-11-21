import 'package:penguin_store/config/api_config.dart';

class Product {
  final int id;
  final String name;
  final String description;
  final double price;
  final double? originalPrice;
  final String imageUrl;
  final String category;
  final double rating;
  final int reviews;
  final int? discountPercent;
  final bool isFeatured;
  final int stock;

  Product({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    this.originalPrice,
    required this.imageUrl,
    required this.category,
    required this.rating,
    required this.reviews,
    this.discountPercent,
    this.isFeatured = false,
    this.stock = 50,
  });

  /// Backend-generated assets (e.g. 3D poster images) are stored as
  /// relative paths so they keep working when the API domain changes.
  static String resolveImageUrl(String? raw) {
    final url = (raw ?? '').trim();
    if (url.startsWith('/')) {
      final base = ApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');
      return '$base$url';
    }
    return url;
  }

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: (json['id'] as num).toInt(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      originalPrice: json['original_price'] != null
          ? (json['original_price'] as num).toDouble()
          : null,
      imageUrl: resolveImageUrl(json['image_url']?.toString()),
      category: (json['category'] ?? 'CATALOG').toString(),
      rating: (json['rating'] as num?)?.toDouble() ?? 0.0,
      reviews: (json['reviews'] as num?)?.toInt() ?? 0,
      discountPercent: (json['discount_percent'] as num?)?.toInt(),
      isFeatured: json['is_featured'] == true,
      stock: (json['stock'] as num?)?.toInt() ?? 50,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'price': price,
      'original_price': originalPrice,
      'image_url': imageUrl,
      'category': category,
      'rating': rating,
      'reviews': reviews,
      'discount_percent': discountPercent,
      'is_featured': isFeatured,
      'stock': stock,
    };
  }
}
