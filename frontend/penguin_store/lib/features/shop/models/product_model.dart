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
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'],
      name: json['name'],
      description: json['description'] ?? "",
      price: (json['price'] as num).toDouble(),
      originalPrice: json['original_price'] != null 
          ? (json['original_price'] as num).toDouble() 
          : null,
      imageUrl: json['image_url'],
      category: json['category'],
      rating: (json['rating'] as num).toDouble(),
      reviews: json['reviews'],
      discountPercent: json['discount_percent'],
      isFeatured: json['is_featured'] ?? false,
    );
  }
}