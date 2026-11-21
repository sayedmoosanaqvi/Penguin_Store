import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CurrencyOption {
  final String code;
  final String symbol;
  final String label;
  final double rateFromUsd;
  final int decimals;

  const CurrencyOption({
    required this.code,
    required this.symbol,
    required this.label,
    required this.rateFromUsd,
    required this.decimals,
  });
}

/// Live Multi-Currency Switcher (USD / PKR / EUR) for B2C & B2B commerce.
class CurrencyProvider with ChangeNotifier {
  static const String _storageKey = 'penguin_currency_v1';

  static const List<CurrencyOption> supported = [
    CurrencyOption(
      code: 'USD',
      symbol: '\$',
      label: 'USD (\$)',
      rateFromUsd: 1.0,
      decimals: 2,
    ),
    CurrencyOption(
      code: 'PKR',
      symbol: 'Rs ',
      label: 'PKR (Rs)',
      rateFromUsd: 278.50,
      decimals: 0,
    ),
    CurrencyOption(
      code: 'EUR',
      symbol: '€',
      label: 'EUR (€)',
      rateFromUsd: 0.92,
      decimals: 2,
    ),
  ];

  CurrencyOption _current = supported.first;

  CurrencyProvider() {
    _load();
  }

  CurrencyOption get current => _current;
  String get code => _current.code;
  String get symbol => _current.symbol;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_storageKey);
      if (saved != null) {
        final match = supported.where((c) => c.code == saved).firstOrNull;
        if (match != null) {
          _current = match;
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  Future<void> setCurrency(String code) async {
    final match =
        supported.where((c) => c.code == code.toUpperCase()).firstOrNull;
    if (match == null || match.code == _current.code) return;
    _current = match;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, match.code);
    } catch (_) {}
  }

  double convertFromUsd(double usdAmount) =>
      usdAmount * _current.rateFromUsd;

  /// Formats a base USD price into the active currency (e.g. `$24.99`, `Rs 6,960`, `€22.99`).
  String format(double usdAmount, {int? decimals}) {
    final converted = convertFromUsd(usdAmount);
    final dec = decimals ?? _current.decimals;
    final fixed = converted.toStringAsFixed(dec);
    final parts = fixed.split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    if (dec == 0 || parts.length == 1) {
      return '${_current.symbol}$intPart';
    }
    return '${_current.symbol}$intPart.${parts[1]}';
  }
}
