import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:penguin_store/config/api_config.dart';
import 'package:penguin_store/core/services/app_notifier.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';

/// Interactive Model Context Protocol (MCP 2026-07-28 & 2025-11-25) Commerce Hub & Live Inspector
class McpHubScreen extends StatefulWidget {
  const McpHubScreen({super.key});

  @override
  State<McpHubScreen> createState() => _McpHubScreenState();
}

class _McpHubScreenState extends State<McpHubScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Simulator state
  final TextEditingController _simulatorGoalController =
      TextEditingController(text: 'Find 3 top-rated winter items with verified trust');
  int _maxHops = 5;
  bool _isSimulating = false;
  Map<String, dynamic>? _simulationResult;

  // JSON-RPC Inspector state
  String _selectedMethod = 'server/discover';
  String _protocolVersion = '2026-07-28';
  final TextEditingController _rpcPayloadController = TextEditingController();
  bool _isExecutingRpc = false;
  Map<String, dynamic>? _rpcResponse;
  int? _rpcLatencyMs;
  int? _rpcStatusCode;

  // API Key Management state
  List<Map<String, dynamic>> _userApiKeys = [];
  bool _isLoadingKeys = false;
  String? _newGeneratedKey;

  // Telemetry state
  Map<String, dynamic>? _telemetryData;
  bool _isLoadingTelemetry = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _setRpcTemplateForMethod('server/discover');
    _loadUserKeys();
    _loadTelemetry();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _simulatorGoalController.dispose();
    _rpcPayloadController.dispose();
    super.dispose();
  }

  String get _baseUrl => ApiConfig.baseUrl;

  // ---------------------------------------------------------------------------
  // Tab 1: Simulator logic
  // ---------------------------------------------------------------------------
  Future<void> _runSimulation() async {
    final goal = _simulatorGoalController.text.trim();
    if (goal.isEmpty) return;

    setState(() {
      _isSimulating = true;
      _simulationResult = null;
    });

    try {
      final token = context.read<AuthProvider>().token;
      final uri = Uri.parse('$_baseUrl/api/v1/mcp/simulate-agent');
      final headers = {
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      final response = await http
          .post(
            uri,
            headers: headers,
            body: jsonEncode({
              'goal': goal,
              'max_hops': _maxHops,
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        setState(() {
          _simulationResult = jsonDecode(response.body) as Map<String, dynamic>;
        });
      } else {
        AppNotifier.showError(
          'Simulation failed (HTTP ${response.statusCode})',
          fallbackContext: context,
        );
      }
    } catch (e) {
      AppNotifier.showError('Simulation error: $e', fallbackContext: context);
    } finally {
      if (mounted) setState(() => _isSimulating = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Tab 2: RPC Inspector logic
  // ---------------------------------------------------------------------------
  void _setRpcTemplateForMethod(String method) {
    _selectedMethod = method;
    Map<String, dynamic> template = {
      'jsonrpc': '2.0',
      'id': 'inspect-${DateTime.now().millisecondsSinceEpoch}',
      'method': method,
    };

    if (method == 'initialize') {
      template['params'] = {
        'protocolVersion': '2025-11-25',
        'capabilities': {'tools': {}, 'resources': {}, 'prompts': {}},
        'clientInfo': {'name': 'PenguinInspector', 'version': '1.0.0'},
      };
    } else if (method == 'tools/call') {
      template['params'] = {
        'name': 'search_catalog',
        'arguments': {'query': 'jacket', 'limit': 3},
      };
    } else if (method == 'resources/read') {
      template['params'] = {'uri': 'penguin://store/manifest'};
    } else if (method == 'prompts/get') {
      template['params'] = {
        'name': 'budget_bundle_architect',
        'arguments': {'budget': '200', 'preferences': 'winter warm'},
      };
    }

    _rpcPayloadController.text =
        const JsonEncoder.withIndent('  ').convert(template);
    setState(() {});
  }

  Future<void> _executeRpc() async {
    setState(() {
      _isExecutingRpc = true;
      _rpcResponse = null;
      _rpcLatencyMs = null;
      _rpcStatusCode = null;
    });

    final stopwatch = Stopwatch()..start();
    try {
      final token = context.read<AuthProvider>().token;
      final uri = Uri.parse('$_baseUrl/mcp');
      final headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'MCP-Protocol-Version': _protocolVersion,
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      final response = await http
          .post(uri, headers: headers, body: _rpcPayloadController.text)
          .timeout(const Duration(seconds: 25));

      stopwatch.stop();
      _rpcLatencyMs = stopwatch.elapsedMilliseconds;
      _rpcStatusCode = response.statusCode;

      try {
        _rpcResponse = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        _rpcResponse = {'raw': response.body};
      }
    } catch (e) {
      stopwatch.stop();
      _rpcLatencyMs = stopwatch.elapsedMilliseconds;
      _rpcResponse = {'error': e.toString()};
    } finally {
      if (mounted) setState(() => _isExecutingRpc = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Tab 3: API Key management logic
  // ---------------------------------------------------------------------------
  Future<void> _loadUserKeys() async {
    final token = context.read<AuthProvider>().token;
    if (token == null || token.isEmpty) return;

    setState(() => _isLoadingKeys = true);
    try {
      final res = await http.get(
        Uri.parse('$_baseUrl/api/v1/mcp/keys'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List) {
          setState(() {
            _userApiKeys = List<Map<String, dynamic>>.from(data);
          });
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingKeys = false);
  }

  Future<void> _createNewKeyDialog() async {
    final nameCtrl = TextEditingController(text: 'External Claude Agent');
    bool scopeCatalog = true;
    bool scopeCommerce = true;
    bool scopeB2b = false;
    bool scopeAdmin = false;
    final isAdmin = context.read<AuthProvider>().isAdmin;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            title: const Text('Create Scoped MCP Key'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Key Label / Client Name',
                      hintText: 'e.g. Claude Desktop, VS Code, Cursor',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Granted Scopes:',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  CheckboxListTile(
                    title: const Text('catalog:read'),
                    subtitle: const Text('Search products, 3D models, reviews'),
                    value: scopeCatalog,
                    onChanged: (v) => setModalState(() => scopeCatalog = v ?? true),
                  ),
                  CheckboxListTile(
                    title: const Text('commerce:write'),
                    subtitle: const Text('Manage cart, quotes, favorites'),
                    value: scopeCommerce,
                    onChanged: (v) =>
                        setModalState(() => scopeCommerce = v ?? false),
                  ),
                  CheckboxListTile(
                    title: const Text('b2b:write'),
                    subtitle: const Text('Submit RFQs & wholesale requests'),
                    value: scopeB2b,
                    onChanged: (v) => setModalState(() => scopeB2b = v ?? false),
                  ),
                  if (isAdmin)
                    CheckboxListTile(
                      title: const Text('admin:read'),
                      subtitle: const Text('Telemetry & pending RFQs access'),
                      value: scopeAdmin,
                      onChanged: (v) =>
                          setModalState(() => scopeAdmin = v ?? false),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final token = context.read<AuthProvider>().token;
                  if (token == null) return;

                  final scopes = <String>[];
                  if (scopeCatalog) scopes.add('catalog:read');
                  if (scopeCommerce) scopes.add('commerce:write');
                  if (scopeB2b) scopes.add('b2b:write');
                  if (scopeAdmin && isAdmin) scopes.add('admin:read');

                  try {
                    final res = await http.post(
                      Uri.parse('$_baseUrl/api/v1/mcp/keys'),
                      headers: {
                        'Content-Type': 'application/json',
                        'Authorization': 'Bearer $token',
                      },
                      body: jsonEncode({
                        'name': nameCtrl.text.trim(),
                        'scopes': scopes,
                        'expires_in_days': 30,
                      }),
                    );
                    if (res.statusCode == 201) {
                      final data = jsonDecode(res.body);
                      setState(() {
                        _newGeneratedKey = data['api_key'];
                      });
                      _loadUserKeys();
                    } else {
                      AppNotifier.showError('Key creation failed: ${res.body}',
                          fallbackContext: context);
                    }
                  } catch (e) {
                    AppNotifier.showError('Failed: $e',
                        fallbackContext: context);
                  }
                },
                child: const Text('Generate Key'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _revokeKey(int keyId) async {
    final token = context.read<AuthProvider>().token;
    if (token == null) return;
    try {
      final res = await http.delete(
        Uri.parse('$_baseUrl/api/v1/mcp/keys/$keyId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        AppNotifier.showSuccess('Key revoked successfully.',
            fallbackContext: context);
        _loadUserKeys();
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Tab 4: Telemetry logic
  // ---------------------------------------------------------------------------
  Future<void> _loadTelemetry() async {
    setState(() => _isLoadingTelemetry = true);
    try {
      final token = context.read<AuthProvider>().token;
      final headers = {
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };
      final res = await http.get(
        Uri.parse('$_baseUrl/api/v1/mcp/telemetry'),
        headers: headers,
      );
      if (res.statusCode == 200) {
        setState(() {
          _telemetryData = jsonDecode(res.body) as Map<String, dynamic>;
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingTelemetry = false);
  }

  void _copyToClipboard(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    AppNotifier.showSuccess(message, fallbackContext: context);
  }

  // ---------------------------------------------------------------------------
  // Build UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0A0F1D) : const Color(0xFFF3F7FB),
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: colors.onSurface),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0284C7), Color(0xFF0EA5E9)],
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'MCP',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Model Context Protocol Hub',
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: colors.onSurface,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Copy MCP Server URL',
            icon: const Icon(Icons.link_rounded),
            onPressed: () => _copyToClipboard(
              '$_baseUrl/mcp',
              'MCP endpoint URL copied to clipboard!',
            ),
          ),
          IconButton(
            tooltip: 'Refresh Telemetry',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              _loadTelemetry();
              _loadUserKeys();
            },
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: const Color(0xFF0284C7),
          unselectedLabelColor: colors.onSurfaceVariant,
          indicatorColor: const Color(0xFF0284C7),
          indicatorWeight: 3,
          labelStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w800,
            fontSize: 13.5,
          ),
          tabs: const [
            Tab(
              icon: Icon(Icons.smart_toy_rounded, size: 18),
              text: 'Autonomous Agent Simulator',
            ),
            Tab(
              icon: Icon(Icons.terminal_rounded, size: 18),
              text: 'JSON-RPC 2.0 Inspector',
            ),
            Tab(
              icon: Icon(Icons.integration_instructions_rounded, size: 18),
              text: 'External Host Config & Keys',
            ),
            Tab(
              icon: Icon(Icons.bar_chart_rounded, size: 18),
              text: 'Live Telemetry & Logs',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSimulatorTab(theme, colors, isDark),
          _buildInspectorTab(theme, colors, isDark),
          _buildHostConfigTab(theme, colors, isDark),
          _buildTelemetryTab(theme, colors, isDark),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1: Simulator View
  // ---------------------------------------------------------------------------
  Widget _buildSimulatorTab(ThemeData theme, ColorScheme colors, bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hero Explainer
              _buildInfoBanner(
                icon: Icons.auto_awesome_rounded,
                title: 'Autonomous External Buyer Agent Simulator',
                subtitle:
                    'Simulates an autonomous external AI model acting strictly as a client over standard JSON-RPC 2.0. '
                    'It queries live Supabase tables, scores trust, evaluates B2B MOQ tiers, and executes actions autonomously.',
                colors: colors,
                isDark: isDark,
              ),
              const SizedBox(height: 18),

              // Preset Buttons
              const Text(
                'Quick Preset Missions:',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildPresetChip(
                    '10x Arctic Flagships Bulk Deal',
                    'Check B2B wholesale pricing and calculate deal for 10x Arctic Jacket with code PENGUIN10',
                  ),
                  _buildPresetChip(
                    '3 Top-Rated Winter Items',
                    'Find 3 top-rated winter items with verified review trust score',
                  ),
                  _buildPresetChip(
                    '3D Digital Twin Showcase',
                    'List available 3D GLB models and give me a full product profile for product 144',
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Goal input Card
              Card(
                elevation: 0,
                color: colors.surfaceContainerLowest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _simulatorGoalController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: 'Mission Goal (Natural Language)',
                          hintText: 'e.g. Find products, compare reviews, and add the best deal to cart',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text(
                            'Max Autonomous Hops: $_maxHops',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Expanded(
                            child: Slider(
                              value: _maxHops.toDouble(),
                              min: 1,
                              max: 8,
                              divisions: 7,
                              label: '$_maxHops hops',
                              activeColor: const Color(0xFF0284C7),
                              onChanged: (v) =>
                                  setState(() => _maxHops = v.toInt()),
                            ),
                          ),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF0284C7),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _isSimulating ? null : _runSimulation,
                            icon: _isSimulating
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.rocket_launch_rounded),
                            label: Text(
                              _isSimulating
                                  ? 'Agent Reasoning...'
                                  : 'Launch Buyer Agent',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Simulation Execution Trace
              if (_simulationResult != null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Autonomous Execution Timeline (${_simulationResult!['hops_taken']} Hops · ${_simulationResult!['total_duration_ms']}ms)',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _simulationResult!['status'] == 'completed'
                            ? const Color(0xFF16A34A).withValues(alpha: 0.15)
                            : const Color(0xFFEAB308).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        (_simulationResult!['status'] ?? 'COMPLETED')
                            .toString()
                            .toUpperCase(),
                        style: TextStyle(
                          color: _simulationResult!['status'] == 'completed'
                              ? const Color(0xFF16A34A)
                              : const Color(0xFFCA8A04),
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Final Answer Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: colors.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.check_circle_rounded,
                              color: colors.primary, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Synthesized Agent Solution',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _simulationResult!['final_answer'] ?? '',
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.5,
                          color: colors.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Hop List
                if (_simulationResult!['timeline'] is List)
                  ...((_simulationResult!['timeline'] as List)
                      .map((hop) => _buildHopCard(hop as Map<String, dynamic>, colors, isDark))),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPresetChip(String label, String goalText) {
    return ActionChip(
      avatar: const Icon(Icons.flash_on_rounded, size: 14),
      label: Text(label),
      onPressed: () {
        setState(() {
          _simulatorGoalController.text = goalText;
        });
      },
    );
  }

  Widget _buildHopCard(
    Map<String, dynamic> hop,
    ColorScheme colors,
    bool isDark,
  ) {
    final hopNum = hop['hop'] ?? 1;
    final tool = hop['tool'] ?? 'tools/call';
    final duration = hop['duration_ms'] ?? 0;
    final summary = hop['summary'] ?? '';
    final rpcReq = hop['rpc_request'];
    final rpcResp = hop['rpc_response'];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: const Color(0xFF0284C7).withValues(alpha: 0.15),
          child: Text(
            '$hopNum',
            style: const TextStyle(
              color: Color(0xFF0284C7),
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'MCP',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 9,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '$tool',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ),
          ],
        ),
        subtitle: Text(
          summary,
          style: TextStyle(
            fontSize: 12,
            color: colors.onSurfaceVariant,
          ),
        ),
        trailing: Text(
          '${duration}ms',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 11,
            color: Color(0xFF0284C7),
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                const Text(
                  'JSON-RPC 2.0 Request:',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
                ),
                const SizedBox(height: 4),
                _buildCodeSnippet(jsonEncode(rpcReq), isDark),
                const SizedBox(height: 10),
                const Text(
                  'JSON-RPC 2.0 Response:',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
                ),
                const SizedBox(height: 4),
                _buildCodeSnippet(jsonEncode(rpcResp), isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 2: JSON-RPC Inspector View
  // ---------------------------------------------------------------------------
  Widget _buildInspectorTab(ThemeData theme, ColorScheme colors, bool isDark) {
    final methods = [
      'server/discover',
      'initialize',
      'tools/list',
      'tools/call',
      'resources/list',
      'resources/read',
      'prompts/list',
      'prompts/get',
      'ping',
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoBanner(
                icon: Icons.code_rounded,
                title: 'Live JSON-RPC 2.0 Over-the-Wire Inspector',
                subtitle:
                    'Send arbitrary stateless JSON-RPC calls directly to POST /mcp with protocol version negotiation '
                    '(2026-07-28 & 2025-11-25). Inspect real database payloads, input schema validation, and errors.',
                colors: colors,
                isDark: isDark,
              ),
              const SizedBox(height: 18),

              // Controls row
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      value: _selectedMethod,
                      decoration: InputDecoration(
                        labelText: 'Method',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      items: methods
                          .map((m) =>
                              DropdownMenuItem(value: m, child: Text(m)))
                          .toList(),
                      onChanged: (val) {
                        if (val != null) _setRpcTemplateForMethod(val);
                      },
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _protocolVersion,
                      decoration: InputDecoration(
                        labelText: 'Protocol Version',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: '2026-07-28',
                          child: Text('2026-07-28 (Native)'),
                        ),
                        DropdownMenuItem(
                          value: '2025-11-25',
                          child: Text('2025-11-25 (Compat)'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _protocolVersion = val);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Request Payload Editor
              TextField(
                controller: _rpcPayloadController,
                maxLines: 10,
                style: GoogleFonts.firaCode(fontSize: 12),
                decoration: InputDecoration(
                  labelText: 'Request JSON-RPC 2.0 Payload',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Endpoint: POST $_baseUrl/mcp',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _isExecutingRpc ? null : _executeRpc,
                    icon: _isExecutingRpc
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send_rounded),
                    label: Text(
                      _isExecutingRpc ? 'Executing...' : 'Execute JSON-RPC',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Response View
              if (_rpcResponse != null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Response (Status ${_rpcStatusCode ?? 200} · ${_rpcLatencyMs ?? 0}ms)',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy Response',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () => _copyToClipboard(
                        const JsonEncoder.withIndent('  ')
                            .convert(_rpcResponse),
                        'Response copied!',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildCodeSnippet(
                  const JsonEncoder.withIndent('  ').convert(_rpcResponse),
                  isDark,
                  maxHeight: 380,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 3: Host Config & API Keys View
  // ---------------------------------------------------------------------------
  Widget _buildHostConfigTab(ThemeData theme, ColorScheme colors, bool isDark) {
    final claudeConfig = '''{
  "mcpServers": {
    "penguin-store": {
      "command": "python",
      "args": ["d:/Penguin_Store/backend/mcp_stdio_bridge.py"],
      "env": {
        "PENGUIN_MCP_URL": "$_baseUrl/mcp",
        "PENGUIN_MCP_KEY": "ps_mcp_your_token_here"
      }
    }
  }
}''';

    final curlSnippet =
        '''curl -X POST "$_baseUrl/mcp" \\
  -H "Content-Type: application/json" \\
  -H "MCP-Protocol-Version: 2026-07-28" \\
  -H "Authorization: Bearer ps_mcp_your_token_here" \\
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover"}' ''';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoBanner(
                icon: Icons.vpn_key_rounded,
                title: 'External Hosts Connection & Scoped API Keys',
                subtitle:
                    'Connect Claude Desktop, Cursor, VS Code, or custom Python agents to Penguin Store. '
                    'Generate SHA-256 hashed API keys with strict scopes (catalog:read, commerce:write, b2b:write).',
                colors: colors,
                isDark: isDark,
              ),
              const SizedBox(height: 18),

              // Newly Generated Plaintext Key Alert
              if (_newGeneratedKey != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16A34A).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF16A34A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.check_circle_rounded,
                              color: Color(0xFF16A34A)),
                          SizedBox(width: 8),
                          Text(
                            'New Scoped MCP Key Created!',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF16A34A),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Copy your secret key now. For security, it is stored as a SHA-256 hash in Supabase and cannot be shown again.',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              _newGeneratedKey!,
                              style: GoogleFonts.firaCode(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy_rounded),
                            onPressed: () => _copyToClipboard(
                              _newGeneratedKey!,
                              'API key copied to clipboard!',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // Manage Keys Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Your Active MCP Keys (${_userApiKeys.length})',
                    style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                    ),
                    onPressed: _createNewKeyDialog,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('New MCP Key'),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Active Keys List
              if (_isLoadingKeys)
                const Center(child: CircularProgressIndicator())
              else if (_userApiKeys.isEmpty)
                Card(
                  elevation: 0,
                  color: colors.surfaceContainerLowest,
                  child: const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'No MCP API keys created yet. Click "New MCP Key" to connect external clients.',
                      ),
                    ),
                  ),
                )
              else
                ..._userApiKeys.map((k) {
                  final keyId = k['id'] as int;
                  final name = k['name'] ?? 'Key';
                  final prefix = k['key_prefix'] ?? 'ps_mcp_';
                  final scopes = (k['scopes'] as List?)?.join(', ') ?? '';
                  final lastUsed = k['last_used_at'] ?? 'Never';

                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 10),
                    color: colors.surfaceContainerLowest,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.key_rounded,
                          color: Color(0xFF0284C7)),
                      title: Text(
                        '$name ($prefix...)',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text('Scopes: $scopes · Last Used: $lastUsed'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded,
                            color: Colors.red),
                        tooltip: 'Revoke Key',
                        onPressed: () => _revokeKey(keyId),
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 28),

              // Host Setup Cards
              Text(
                'Claude Desktop / VS Code Stdio Setup',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              _buildCodeSnippetWithCopy(claudeConfig, 'Claude Config', isDark),
              const SizedBox(height: 20),

              Text(
                'Direct Curl Command',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              _buildCodeSnippetWithCopy(curlSnippet, 'Curl Snippet', isDark),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 4: Telemetry View
  // ---------------------------------------------------------------------------
  Widget _buildTelemetryTab(ThemeData theme, ColorScheme colors, bool isDark) {
    if (_isLoadingTelemetry && _telemetryData == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final data = _telemetryData ?? {};
    final metrics = data['metrics'] as Map<String, dynamic>? ?? {};
    final totalCalls = metrics['total_invocations'] ?? 0;
    final successRate = metrics['success_rate_pct'] ?? 100.0;
    final avgLatency = metrics['avg_latency_ms'] ?? 0.0;
    final activeKeys = metrics['active_keys_count'] ?? 0;
    final recentInvocations = (data['recent_invocations'] as List?) ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoBanner(
                icon: Icons.insights_rounded,
                title: 'Live MCP Telemetry & High-Throughput Audit Stream',
                subtitle:
                    'Real-time metrics, per-tool invocation distribution, protocol latency, '
                    'and persistent audit logs recorded in Supabase mcp_audit_logs.',
                colors: colors,
                isDark: isDark,
              ),
              const SizedBox(height: 20),

              // KPI Grid
              Row(
                children: [
                  Expanded(
                    child: _buildKpiCard(
                      'Total Calls',
                      '$totalCalls',
                      Icons.hub_rounded,
                      const Color(0xFF0284C7),
                      colors,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildKpiCard(
                      'Success Rate',
                      '$successRate%',
                      Icons.check_circle_rounded,
                      const Color(0xFF16A34A),
                      colors,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildKpiCard(
                      'Avg Latency',
                      '${avgLatency}ms',
                      Icons.timer_rounded,
                      const Color(0xFF8B5CF6),
                      colors,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildKpiCard(
                      'Active Keys',
                      '$activeKeys',
                      Icons.key_rounded,
                      const Color(0xFFF59E0B),
                      colors,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              Text(
                'Recent MCP Invocation Stream (Last ${recentInvocations.length})',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),

              if (recentInvocations.isEmpty)
                Card(
                  elevation: 0,
                  color: colors.surfaceContainerLowest,
                  child: const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No MCP calls recorded yet in this session.'),
                    ),
                  ),
                )
              else
                ...recentInvocations.map((inv) {
                  final m = inv as Map<String, dynamic>;
                  final method = m['method'] ?? '';
                  final tool = m['tool_name'] ?? '';
                  final latency = m['latency_ms'] ?? 0;
                  final success = m['success'] == true;
                  final timeStr = m['created_at'] ?? '';

                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
                    color: colors.surfaceContainerLowest,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: 0.35),
                      ),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        success ? Icons.check_circle_rounded : Icons.error_rounded,
                        color: success ? const Color(0xFF16A34A) : Colors.red,
                        size: 20,
                      ),
                      title: Text(
                        tool.isNotEmpty ? '$method -> $tool' : '$method',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        'Time: $timeStr · Source: ${m['source'] ?? 'http'}',
                      ),
                      trailing: Text(
                        '${latency}ms',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: Color(0xFF0284C7),
                        ),
                      ),
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKpiCard(
    String label,
    String value,
    IconData icon,
    Color accent,
    ColorScheme colors,
  ) {
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: accent, size: 24),
            const SizedBox(height: 10),
            Text(
              value,
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w900,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Reusable Widgets
  // ---------------------------------------------------------------------------
  Widget _buildInfoBanner({
    required IconData icon,
    required String title,
    required String subtitle,
    required ColorScheme colors,
    required bool isDark,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F1E36) : const Color(0xFFE0F2FE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0284C7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: isDark ? Colors.white : const Color(0xFF0369A1),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: isDark ? Colors.white70 : const Color(0xFF0C4A6E),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeSnippet(String code, bool isDark, {double maxHeight = 160}) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF070B14) : const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          code,
          style: GoogleFonts.firaCode(
            fontSize: 11.5,
            color: const Color(0xFF38BDF8),
          ),
        ),
      ),
    );
  }

  Widget _buildCodeSnippetWithCopy(String code, String label, bool isDark) {
    return Stack(
      children: [
        _buildCodeSnippet(code, isDark, maxHeight: 220),
        Positioned(
          top: 6,
          right: 6,
          child: IconButton(
            icon: const Icon(Icons.copy_rounded, color: Colors.white70, size: 18),
            onPressed: () => _copyToClipboard(code, '$label copied!'),
          ),
        ),
      ],
    );
  }
}
