import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:penguin_store/core/widgets/animated_widgets.dart';
import 'package:penguin_store/features/shop/widgets/right_drawer.dart';
import 'package:penguin_store/features/shop/widgets/top_nav_bar.dart';

class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();

  final List<Map<String, String>> _faqs = const [
    {
      'question': 'How can I track my Penguin Store order?',
      'answer':
          'Open the right drawer menu and tap "Track an Order" or "My Orders". Enter your order ID to view real-time status progression from Confirmed to Shipped and Delivered.',
    },
    {
      'question': 'How does the 3D Models Showroom work?',
      'answer':
          'Products with the pulsing 3D badge include interactive GLB assets stored in Supabase. Tap "3D Models" in the top bar or drawer to rotate, zoom, and switch studio lighting backdrops in real time.',
    },
    {
      'question': 'How does AI Fake Review Detection protect shoppers?',
      'answer':
          'Every submitted review is scored by our Trustworthy Review Engine for verified purchase evidence, aspect sentiment (Quality, Value, Delivery, Packaging), and spam/burst signals before contributing to the trust-weighted product rating.',
    },
    {
      'question': 'What is your return & exchange policy?',
      'answer':
          'We offer a 30-day Arctic Guarantee return policy. Items must be unworn, in original condition, and accompanied by your digital order receipt.',
    },
    {
      'question': 'Can CTRL-X build a multi-item bundle within my budget?',
      'answer':
          'Yes! Open CTRL-X AI Assistant and ask for an outfit or gift bundle under a specific budget (e.g., "Build a bundle under \$120"). CTRL-X will display its live reasoning trace and let you add the entire bundle to cart in one tap.',
    },
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  void _submitMessage() {
    if (_nameController.text.trim().isEmpty ||
        _emailController.text.trim().isEmpty ||
        _messageController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill out all fields before sending.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    _nameController.clear();
    _emailController.clear();
    _messageController.clear();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Message received! Our Penguin Support team will reply within 24 hours.',
        ),
        backgroundColor: Color(0xFF16A34A),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0A0F1D) : const Color(0xFFF3F7FB);
    final cardColor = isDark ? const Color(0xFF131C31) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor =
        isDark ? Colors.white60 : const Color(0xFF64748B);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: const TopNavBar(),
      endDrawer: const RightDrawer(),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildHeroBanner(),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 28,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FadeSlideIn.staggered(
                        index: 0,
                        child: _buildQuickShortcuts(
                          context: context,
                          isDark: isDark,
                          cardColor: cardColor,
                          textColor: textColor,
                        ),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        'Frequently Asked Questions',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Instant answers about orders, 3D models, CTRL-X AI, and returns.',
                        style: TextStyle(fontSize: 13.5, color: subTextColor),
                      ),
                      const SizedBox(height: 16),
                      ...List.generate(_faqs.length, (index) {
                        final faq = _faqs[index];
                        return FadeSlideIn.staggered(
                          index: index + 1,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: cardColor,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.07)
                                    : const Color(0xFFE2E8F0),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: isDark ? 0.2 : 0.04,
                                  ),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ExpansionTile(
                              iconColor: const Color(0xFF1E88E5),
                              collapsedIconColor: subTextColor,
                              shape: const Border(),
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E88E5)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.quiz_rounded,
                                  size: 18,
                                  color: Color(0xFF1E88E5),
                                ),
                              ),
                              title: Text(
                                faq['question']!,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5,
                                  color: textColor,
                                ),
                              ),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  child: Text(
                                    faq['answer']!,
                                    style: TextStyle(
                                      color: subTextColor,
                                      height: 1.55,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 36),
                      FadeSlideIn.staggered(
                        index: 6,
                        child: _buildContactCard(
                          isDark: isDark,
                          cardColor: cardColor,
                          textColor: textColor,
                          subTextColor: subTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF0A192F),
            Color(0xFF1565C0),
            Color(0xFF00ACC1),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E88E5).withValues(alpha: 0.25),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: SnowfallBackground(
          flakes: 26,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
            child: Column(
              children: [
                const PulsingOrb(
                  icon: Icons.support_agent_rounded,
                  size: 64,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Penguin Concierge & Support',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Need help with an order, 3D model view, or AI bundle recommendation? We are here 24/7.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuickShortcuts({
    required BuildContext context,
    required bool isDark,
    required Color cardColor,
    required Color textColor,
  }) {
    final shortcuts = [
      (
        icon: Icons.local_shipping_rounded,
        title: 'Track Order',
        subtitle: 'Live shipment lookup',
        color: const Color(0xFF1E88E5),
        route: '/track-order',
      ),
      (
        icon: Icons.view_in_ar_rounded,
        title: '3D Showroom',
        subtitle: 'Inspect GLB models',
        color: const Color(0xFF00ACC1),
        route: '/showcase-3d',
      ),
      (
        icon: Icons.auto_awesome_rounded,
        title: 'Ask CTRL-X AI',
        subtitle: '24/7 AI shopping guide',
        color: const Color(0xFF6366F1),
        route: '/ctrlx',
      ),
    ];

    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: shortcuts.map((s) {
        return SizedBox(
          width: 285,
          child: PressableScale(
            onTap: () => context.push(s.route),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: s.color.withValues(alpha: 0.28),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: s.color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(s.icon, color: s.color, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14.5,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? Colors.white60
                                : const Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward_ios_rounded, size: 14, color: s.color),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildContactCard({
    required bool isDark,
    required Color cardColor,
    required Color textColor,
    required Color subTextColor,
  }) {
    final inputFill =
        isDark ? const Color(0xFF0B1120) : const Color(0xFFF8FAFC);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: const Color(0xFF1E88E5).withValues(alpha: 0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E88E5).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.mark_email_unread_rounded,
                  color: Color(0xFF1E88E5),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Send a Direct Support Ticket',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: textColor,
                      ),
                    ),
                    Text(
                      'Average response time: under 2 hours during business days.',
                      style: TextStyle(fontSize: 12.5, color: subTextColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _nameController,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              labelText: 'Your Name',
              labelStyle: TextStyle(color: subTextColor),
              prefixIcon: const Icon(
                Icons.person_outline_rounded,
                color: Color(0xFF1E88E5),
              ),
              filled: true,
              fillColor: inputFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _emailController,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              labelText: 'Email Address',
              labelStyle: TextStyle(color: subTextColor),
              prefixIcon: const Icon(
                Icons.email_outlined,
                color: Color(0xFF1E88E5),
              ),
              filled: true,
              fillColor: inputFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _messageController,
            maxLines: 4,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              labelText: 'How can we help you?',
              alignLabelWithHint: true,
              labelStyle: TextStyle(color: subTextColor),
              filled: true,
              fillColor: inputFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1E88E5),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _submitMessage,
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text(
                'Send Message',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
