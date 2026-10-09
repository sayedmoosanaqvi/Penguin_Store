
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  final List<Map<String, dynamic>> _topics = [
    {
      'title': 'My Account',
      'icon': Icons.person_outline,
      'questions': [
        'How do I access my account?',
        'How can I log out?',
      ],
      'answers': [
        'Visit the Profile section to log in or register.',
        'Open your account menu and select Logout.',
      ],
    },
    {
      'title': 'My Orders',
      'icon': Icons.receipt_long_outlined,
      'questions': [
        'How can I track my order?',
        'Where can I check order details?',
      ],
      'answers': [
        'Open My Orders from your Profile to view available tracking information.',
        'Visit My Orders to check your order details.',
      ],
    },
    {
      'title': 'Payment & Checkout',
      'icon': Icons.credit_card_outlined,
      'questions': [
        'How do I place an order?',
        'Which payment system does Penguin Store use?',
      ],
      'answers': [
        'Add products to your cart and select Checkout to proceed.',
        'Penguin Store currently integrates Stripe for payment processing.',
      ],
    },
    {
      'title': 'Shipping & Delivery',
      'icon': Icons.local_shipping_outlined,
      'questions': [
        'How can I check my delivery status?',
      ],
      'answers': [
        'Visit My Orders to view available order and delivery tracking details.',
      ],
    },
    {
      'title': 'Products & Shopping',
      'icon': Icons.shopping_bag_outlined,
      'questions': [
        'How can I find products?',
        'Can I search using an image?',
      ],
      'answers': [
        'Visit Discover to browse products and categories.',
        'Use the visual search camera option available on the homepage.',
      ],
    },
    {
      'title': 'AI Support',
      'icon': Icons.smart_toy_outlined,
      'questions': [
        'What is CTRL-X?',
        'How can CTRL-X assist me?',
      ],
      'answers': [
        'CTRL-X is Penguin Store’s integrated AI assistant.',
        'Open CTRL-X to ask questions about products, inventory, orders, and other supported shopping-related tasks.',
      ],
    },
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final filteredTopics = _topics.where((topic) {
      final title = (topic['title'] as String).toLowerCase();
      final questions = topic['questions'] as List<String>;
      final answers = topic['answers'] as List<String>;

      return title.contains(_searchQuery) ||
          questions.any((q) => q.toLowerCase().contains(_searchQuery)) ||
          answers.any((a) => a.toLowerCase().contains(_searchQuery));
    }).toList();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: const Text(
          'Help & Support',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.primaryColor,
                  theme.colorScheme.tertiary,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      color: Colors.white,
                      size: 23,
                    ),
                    SizedBox(width: 9),
                    Text(
                      'Need Any Help?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Let CTRL-X, your AI support agent, assist you.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Get assistance with products, orders, and shopping-related questions.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => context.push('/ctrlx'),
                    icon: const Icon(
                      Icons.smart_toy_outlined,
                      size: 20,
                    ),
                    label: const Text(
                      'Chat with CTRL-X Agent',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: theme.primaryColor,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Help & Knowledge Base',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Browse frequently asked questions or search for answers.',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _searchController,
            onChanged: (value) {
              setState(() {
                _searchQuery = value.trim().toLowerCase();
              });
            },
            decoration: InputDecoration(
              hintText: 'Search questions',
              hintStyle: const TextStyle(fontSize: 13),
              prefixIcon: Icon(
                Icons.search,
                color: theme.primaryColor,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: isDark
                  ? theme.colorScheme.surface
                  : theme.primaryColor.withOpacity(0.05),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.primaryColor.withOpacity(0.2),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.primaryColor,
                  width: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (filteredTopics.isEmpty)
            const Padding(
              padding: EdgeInsets.all(30),
              child: Center(
                child: Text('No matching help topics found'),
              ),
            ),
          ...filteredTopics.map((topic) {
            final title = topic['title'] as String;
            final icon = topic['icon'] as IconData;
            final questions = topic['questions'] as List<String>;
            final answers = topic['answers'] as List<String>;

            final matchingIndices = List.generate(
              questions.length,
              (index) => index,
            ).where((index) {
              return _searchQuery.isEmpty ||
                  title.toLowerCase().contains(_searchQuery) ||
                  questions[index]
                      .toLowerCase()
                      .contains(_searchQuery) ||
                  answers[index]
                      .toLowerCase()
                      .contains(_searchQuery);
            }).toList();

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.dividerColor.withOpacity(0.2),
                ),
              ),
              child: ExpansionTile(
                key: ValueKey('$title-$_searchQuery'),
                initiallyExpanded: _searchQuery.isNotEmpty,
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 3,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                leading: Container(
                  width: 43,
                  height: 43,
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withOpacity(0.09),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    icon,
                    color: theme.primaryColor,
                    size: 22,
                  ),
                ),
                title: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  '${matchingIndices.length} frequently asked questions',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                children: matchingIndices.map((index) {
                  return ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 6),
                    childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    title: Text(
                      questions[index],
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          answers[index],
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            );
          }),
          const SizedBox(height: 18),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.support_agent_outlined,
                  color: theme.primaryColor,
                  size: 30,
                ),
                const SizedBox(height: 8),
                Text(
                  'Still need assistance?',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 5),
                TextButton.icon(
                  onPressed: () => context.push('/ctrlx'),
                  icon: const Icon(Icons.auto_awesome, size: 17),
                  label: const Text('Ask CTRL-X AI Agent'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
