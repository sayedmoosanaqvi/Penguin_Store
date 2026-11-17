import 'package:flutter/material.dart';

import 'package:penguin_store/features/shop/models/product_model.dart';

enum ProductSort { featured, priceLow, priceHigh, rating, discount, newest }

extension ProductSortLabel on ProductSort {
  String get label {
    switch (this) {
      case ProductSort.featured:
        return 'Featured';
      case ProductSort.priceLow:
        return 'Price: Low to High';
      case ProductSort.priceHigh:
        return 'Price: High to Low';
      case ProductSort.rating:
        return 'Top Rated';
      case ProductSort.discount:
        return 'Biggest Discount';
      case ProductSort.newest:
        return 'Newest';
    }
  }
}

/// Single source of truth for storefront filtering, shared by Home and
/// Discover so both screens behave identically.
class ProductFilters {
  final String category;
  final String query;
  final ProductSort sort;
  final RangeValues? price;
  final double minRating;
  final bool only3D;
  final bool onSale;

  const ProductFilters({
    this.category = 'All',
    this.query = '',
    this.sort = ProductSort.featured,
    this.price,
    this.minRating = 0,
    this.only3D = false,
    this.onSale = false,
  });

  ProductFilters copyWith({
    String? category,
    String? query,
    ProductSort? sort,
    RangeValues? price,
    bool clearPrice = false,
    double? minRating,
    bool? only3D,
    bool? onSale,
  }) {
    return ProductFilters(
      category: category ?? this.category,
      query: query ?? this.query,
      sort: sort ?? this.sort,
      price: clearPrice ? null : (price ?? this.price),
      minRating: minRating ?? this.minRating,
      only3D: only3D ?? this.only3D,
      onSale: onSale ?? this.onSale,
    );
  }

  /// Number of advanced (sheet) filters currently applied.
  int get advancedCount =>
      (sort != ProductSort.featured ? 1 : 0) +
      (price != null ? 1 : 0) +
      (minRating > 0 ? 1 : 0) +
      (onSale ? 1 : 0);

  bool get isDefault =>
      category == 'All' &&
      query.isEmpty &&
      advancedCount == 0 &&
      !only3D;

  static String _norm(String raw) {
    var t = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    t = t.replaceFirst(RegExp(r'^mens'), 'men');
    t = t.replaceFirst(RegExp(r'^womens'), 'women');
    if (t.length > 3 && t.endsWith('s')) t = t.substring(0, t.length - 1);
    return t;
  }

  /// "Men Shoes" must match the database value "MENS-SHOES", etc.
  static bool categoryMatches(String dbCategory, String selected) {
    if (selected == 'All') return true;
    final a = _norm(dbCategory);
    final b = _norm(selected);
    if (a.isEmpty || b.isEmpty) return false;
    return a == b || (b.length > 3 && a.contains(b)) || (a.length > 3 && b.contains(a));
  }

  static int _discountOf(Product p) {
    if (p.discountPercent != null && p.discountPercent! > 0) {
      return p.discountPercent!;
    }
    if (p.originalPrice != null && p.originalPrice! > p.price) {
      return ((p.originalPrice! - p.price) / p.originalPrice! * 100).round();
    }
    return 0;
  }

  List<Product> apply(List<Product> source, Set<int> ids3D) {
    final q = query.trim().toLowerCase();

    final result = source.where((p) {
      if (!categoryMatches(p.category, category)) return false;
      if (only3D && !ids3D.contains(p.id)) return false;
      if (onSale && _discountOf(p) <= 0) return false;
      if (minRating > 0 && p.rating < minRating) return false;
      if (price != null && (p.price < price!.start || p.price > price!.end)) {
        return false;
      }
      if (q.isNotEmpty) {
        final hay =
            '${p.name} ${p.category} ${p.description}'.toLowerCase();
        // every typed word must appear: "red shoe" finds "Red Nike Shoe".
        for (final word in q.split(RegExp(r'\s+'))) {
          if (!hay.contains(word)) return false;
        }
      }
      return true;
    }).toList();

    switch (sort) {
      case ProductSort.priceLow:
        result.sort((a, b) => a.price.compareTo(b.price));
        break;
      case ProductSort.priceHigh:
        result.sort((a, b) => b.price.compareTo(a.price));
        break;
      case ProductSort.rating:
        result.sort((a, b) => b.rating.compareTo(a.rating));
        break;
      case ProductSort.discount:
        result.sort((a, b) => _discountOf(b).compareTo(_discountOf(a)));
        break;
      case ProductSort.newest:
        result.sort((a, b) => b.id.compareTo(a.id));
        break;
      case ProductSort.featured:
        result.sort((a, b) {
          final f = (b.isFeatured ? 1 : 0) - (a.isFeatured ? 1 : 0);
          return f != 0 ? f : a.id.compareTo(b.id);
        });
        break;
    }

    return result;
  }
}

/// Bottom sheet with sort / price / rating / sale / 3D controls.
Future<ProductFilters?> showProductFilterSheet(
  BuildContext context, {
  required ProductFilters current,
  required List<Product> products,
}) {
  double lo = 0, hi = 100;
  if (products.isNotEmpty) {
    lo = products.map((p) => p.price).reduce((a, b) => a < b ? a : b);
    hi = products.map((p) => p.price).reduce((a, b) => a > b ? a : b);
  }
  lo = lo.floorToDouble();
  hi = hi.ceilToDouble();
  if (hi <= lo) hi = lo + 1;

  return showModalBottomSheet<ProductFilters>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => _FilterSheet(
      initial: current,
      minPrice: lo,
      maxPrice: hi,
    ),
  );
}

class _FilterSheet extends StatefulWidget {
  final ProductFilters initial;
  final double minPrice;
  final double maxPrice;

  const _FilterSheet({
    required this.initial,
    required this.minPrice,
    required this.maxPrice,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late ProductFilters _f = widget.initial;
  late RangeValues _range = widget.initial.price ??
      RangeValues(widget.minPrice, widget.maxPrice);

  bool get _rangeTouched =>
      _range.start > widget.minPrice || _range.end < widget.maxPrice;

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Filter & Sort',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _f = ProductFilters(category: _f.category, query: _f.query);
                      _range = RangeValues(widget.minPrice, widget.maxPrice);
                    }),
                    child: const Text('Reset'),
                  ),
                ],
              ),
              _title('Sort by'),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: ProductSort.values.map((s) {
                  final selected = _f.sort == s;
                  return ChoiceChip(
                    label: Text(s.label, style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : null,
                    )),
                    selected: selected,
                    showCheckmark: false,
                    selectedColor: primary,
                    onSelected: (_) => setState(() => _f = _f.copyWith(sort: s)),
                  );
                }).toList(),
              ),
              _title(
                'Price  (\$${_range.start.round()} – \$${_range.end.round()})',
              ),
              RangeSlider(
                values: _range,
                min: widget.minPrice,
                max: widget.maxPrice,
                divisions: (widget.maxPrice - widget.minPrice).clamp(1, 100).round(),
                labels: RangeLabels(
                  '\$${_range.start.round()}',
                  '\$${_range.end.round()}',
                ),
                onChanged: (v) => setState(() => _range = v),
              ),
              _title('Minimum rating'),
              Wrap(
                spacing: 8,
                children: [0.0, 3.0, 4.0, 4.5].map((r) {
                  final selected = _f.minRating == r;
                  return ChoiceChip(
                    avatar: r == 0
                        ? null
                        : Icon(Icons.star_rounded,
                            size: 14,
                            color: selected ? Colors.white : Colors.amber),
                    label: Text(
                      r == 0 ? 'Any' : '$r+',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : null,
                      ),
                    ),
                    selected: selected,
                    showCheckmark: false,
                    selectedColor: primary,
                    onSelected: (_) =>
                        setState(() => _f = _f.copyWith(minRating: r)),
                  );
                }).toList(),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('On sale only',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                value: _f.onSale,
                onChanged: (v) => setState(() => _f = _f.copyWith(onSale: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('3D models only',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: const Text('Products you can rotate & inspect',
                    style: TextStyle(fontSize: 10)),
                value: _f.only3D,
                onChanged: (v) => setState(() => _f = _f.copyWith(only3D: v)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _f.copyWith(
                      price: _rangeTouched ? _range : null,
                      clearPrice: !_rangeTouched,
                    ),
                  ),
                  child: const Text('Show results'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
