
import 'package:flutter/material.dart';

class PremiumSubscriptionScreen extends StatelessWidget {
  const PremiumSubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Penguin Premium',
          style: TextStyle(
            fontWeight: FontWeight.w800,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 760,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(30),
                    decoration: BoxDecoration(
                      borderRadius:
                          BorderRadius.circular(24),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF1976D2),
                          Color(0xFF3949AB),
                          Color(0xFF00ACC1),
                        ],
                      ),
                    ),
                    child: const Column(
                      children: [
                        Icon(
                          Icons.workspace_premium_rounded,
                          size: 65,
                          color: Colors.white,
                        ),
                        SizedBox(height: 18),
                        Text(
                          'PENGUIN PREMIUM 3D',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 25,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Explore products beyond photos.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(23),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.verified_outlined,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Free 3D Showcase Available',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight:
                                        FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 14),

                          const Text(
                            'Penguin Store is demonstrating '
                            'its future Premium 3D experience. '
                            'Everyone can currently try '
                            'interactive models without a '
                            'subscription or payment.',
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.6,
                            ),
                          ),

                          const SizedBox(height: 22),

                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () {
                                Navigator.of(context)
                                    .maybePop();
                              },
                              icon: const Icon(
                                Icons.view_in_ar_rounded,
                              ),
                              label: const Text(
                                'EXPLORE 3D PRODUCTS',
                              ),
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(
                                  vertical: 17,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(23),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Premium Features',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),

                          const SizedBox(height: 20),

                          _feature(
                            Icons.threed_rotation_rounded,
                            'Rotate supported 3D products',
                            colors,
                          ),

                          _feature(
                            Icons.zoom_in_rounded,
                            'Zoom in and examine details',
                            colors,
                          ),

                          _feature(
                            Icons.view_in_ar_rounded,
                            'Explore T-shirts and future '
                            '3D product collections',
                            colors,
                          ),

                          _feature(
                            Icons.shopping_bag_outlined,
                            'Continue shopping normally',
                            colors,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(
                        alpha: 0.07,
                      ),
                      borderRadius:
                          BorderRadius.circular(17),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.schedule_rounded,
                          color: colors.primary,
                          size: 30,
                        ),

                        const SizedBox(height: 12),

                        const Text(
                          'Premium Subscriptions Coming Soon',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),

                        const SizedBox(height: 10),

                        Text(
                          'Subscription billing is not '
                          'enabled during this demonstration. '
                          'Enjoy the available 3D previews '
                          'for free. No card is required.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            height: 1.6,
                            fontSize: 13,
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
      ),
    );
  }

  Widget _feature(
    IconData icon,
    String title,
    ColorScheme colors,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Icon(
            icon,
            color: colors.primary,
            size: 23,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
