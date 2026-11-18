import 'package:flutter/material.dart';

class LegalDocumentScreen extends StatelessWidget {
  final bool isPrivacyPolicy;

  const LegalDocumentScreen({super.key, this.isPrivacyPolicy = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = isPrivacyPolicy ? _privacySections : _termsSections;

    return Scaffold(
      appBar: AppBar(
        title: Text(isPrivacyPolicy ? 'Privacy Policy' : 'Terms of Service'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 36),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: theme.primaryColor.withValues(alpha: 0.18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPrivacyPolicy
                          ? 'Penguin Store Privacy & Data Safety'
                          : 'Penguin Store Terms of Service',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: theme.primaryColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Effective Date: November 2026 • Penguin Store E-Commerce Platform',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              for (final s in sections) ...[
                Text(
                  s.$1,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  s.$2,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static const List<(String, String)> _privacySections = [
    (
      '1. Information We Collect',
      'Penguin Store collects only the information necessary to operate your shopping account: your email address, encrypted password hash, optional display name, saved shipping addresses, order history, wishlisted items, and product reviews you choose to publish.',
    ),
    (
      '2. Camera & Photos (AI Visual Search)',
      'Photos selected or captured for AI Visual Search are transmitted over HTTPS exclusively to compute similarity embeddings against our catalog. Query images are discarded immediately after matching and are not permanently stored or sold.',
    ),
    (
      '3. Data Security & Storage',
      'Authentication tokens are stored using platform-encrypted secure storage. Application data and product assets are hosted on Supabase PostgreSQL with Row Level Security (RLS) and HTTPS/TLS encryption in transit.',
    ),
    (
      '4. Payments',
      'Card payments are processed by PCI-compliant payment infrastructure (Stripe). Penguin Store never stores raw credit card numbers or CVV codes on its servers.',
    ),
    (
      '5. Account & Data Deletion Rights',
      'You can permanently delete your Penguin Store account and associated personal data (saved addresses, wishlist, cart items, reviews, and session credentials) at any time directly inside Profile -> Settings -> Delete My Account.',
    ),
  ];

  static const List<(String, String)> _termsSections = [
    (
      '1. Use of Service',
      'By creating an account or placing an order on Penguin Store, you agree to provide accurate delivery details and use the storefront, CTRL-X AI Assistant, and 3D Product Showcase for lawful personal shopping purposes.',
    ),
    (
      '2. Orders, Fulfillment & Returns',
      'IN_HOUSE items are dispatched from our Sargodha fulfillment hub with a 14-day return window; DROPSHIP partner items carry a 30-day return window as detailed in the store Return & Refund Policy.',
    ),
    (
      '3. Interactive 3D Showcase Notice',
      'Interactive 3D product viewing is currently provided as a free public demonstration preview of future Premium features. Availability does not represent an active paid subscription charge.',
    ),
    (
      '4. Intellectual Property & Reviews',
      'Submitted reviews must reflect honest product experiences. Penguin Store reserves the right to moderate spam or abusive content.',
    ),
  ];
}
