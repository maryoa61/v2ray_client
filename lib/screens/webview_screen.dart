import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../services/storage_service.dart';

class WebViewScreen extends StatefulWidget {
  final String initialUrl;

  const WebViewScreen({
    super.key,
    this.initialUrl = 'https://github.com/maryoa61',
  });

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = true;
  double _progress = 0;
  String _currentUrl = '';
  List<String> _history = [];

  // Fragment (TLS packet fragmentation) settings — each is a min-max range.
  // Persisted via StorageService (SharedPreferences) on SAVE.
  final TextEditingController _lengthMinCtrl = TextEditingController(text: '50');
  final TextEditingController _lengthMaxCtrl = TextEditingController(text: '100');
  final TextEditingController _intervalMinCtrl = TextEditingController(text: '10');
  final TextEditingController _intervalMaxCtrl = TextEditingController(text: '20');
  final TextEditingController _packetsMinCtrl = TextEditingController(text: '1');
  final TextEditingController _packetsMaxCtrl = TextEditingController(text: '3');
  bool _fragmentEnabled = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl;
    _urlController.text = _currentUrl;
    _loadHistory();
    _loadFragmentSettings();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    
    // setBackgroundColor is not fully supported on macOS WebView
    if (!Platform.isMacOS) {
      _controller.setBackgroundColor(Colors.black);
    }
    
    _controller
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            // Basic download handling for common file types
            final url = request.url.toLowerCase();
            if (url.endsWith('.pdf') ||
                url.endsWith('.zip') ||
                url.endsWith('.apk') ||
                url.endsWith('.dmg') ||
                url.endsWith('.iso')) {
              _launchExternal(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onProgress: (int progress) {
            setState(() {
              _progress = progress / 100;
            });
          },
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
              _currentUrl = url;
              _urlController.text = url;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
              _currentUrl = url;
            });
            _addToHistory(url);
          },
          onWebResourceError: (WebResourceError error) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text('Error: ${error.description}'),
                    backgroundColor: AppTheme.errorColor),
              );
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  void _loadUrl(String url) {
    if (url.isEmpty) return;

    String finalUrl = url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      finalUrl = 'https://$url';
    }

    _controller.loadRequest(Uri.parse(finalUrl));
  }

  Future<void> _loadHistory() async {
    final storage = await StorageService.init();
    setState(() {
      _history = storage.loadUrlHistory();
    });
  }

  Future<void> _loadFragmentSettings() async {
    final storage = await StorageService.init();
    final f = storage.loadFragmentSettings();
    if (!mounted) return;
    setState(() {
      _fragmentEnabled = f['enabled'] as bool;
      _lengthMinCtrl.text = '${f['lengthMin']}';
      _lengthMaxCtrl.text = '${f['lengthMax']}';
      _intervalMinCtrl.text = '${f['intervalMin']}';
      _intervalMaxCtrl.text = '${f['intervalMax']}';
      _packetsMinCtrl.text = '${f['packetsMin']}';
      _packetsMaxCtrl.text = '${f['packetsMax']}';
    });
  }

  Future<void> _saveFragmentSettings() async {
    final storage = await StorageService.init();
    await storage.saveFragmentSettings(
      enabled: _fragmentEnabled,
      lengthMin: int.tryParse(_lengthMinCtrl.text) ?? 50,
      lengthMax: int.tryParse(_lengthMaxCtrl.text) ?? 100,
      intervalMin: int.tryParse(_intervalMinCtrl.text) ?? 10,
      intervalMax: int.tryParse(_intervalMaxCtrl.text) ?? 20,
      packetsMin: int.tryParse(_packetsMinCtrl.text) ?? 1,
      packetsMax: int.tryParse(_packetsMaxCtrl.text) ?? 3,
    );
  }

  Future<void> _addToHistory(String url) async {
    if (url.isEmpty || url == 'about:blank') return;

    // Avoid duplicates at the top
    if (_history.isNotEmpty && _history.first == url) return;

    setState(() {
      _history.remove(url);
      _history.insert(0, url);
      if (_history.length > 20) _history.removeLast();
    });

    final storage = await StorageService.init();
    await storage.saveUrlHistory(_history);
  }

  void _showFragmentSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (context, setSheetState) => Container(
            decoration: const BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              border: Border(
                top: BorderSide(color: AppTheme.accentColor, width: 1),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.call_split, size: 16, color: AppTheme.accentColor),
                    const SizedBox(width: 8),
                    const Text(
                      'PACKET FRAGMENT',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 2, color: Colors.white),
                    ),
                    const Spacer(),
                    Switch(
                      value: _fragmentEnabled,
                      onChanged: (v) {
                        setSheetState(() => _fragmentEnabled = v);
                        setState(() => _fragmentEnabled = v);
                      },
                      activeThumbColor: AppTheme.accentColor,
                      activeTrackColor: AppTheme.accentColor.withValues(alpha: 0.2),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Splits TLS handshake packets to evade DPI. Advanced — leave defaults if unsure.',
                  style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.4), height: 1.4),
                ),
                const SizedBox(height: 20),
                _buildFragmentRangeRow('LENGTH', 'bytes', _lengthMinCtrl, _lengthMaxCtrl),
                const SizedBox(height: 14),
                _buildFragmentRangeRow('INTERVAL', 'ms', _intervalMinCtrl, _intervalMaxCtrl),
                const SizedBox(height: 14),
                _buildFragmentRangeRow('PACKETS', 'count', _packetsMinCtrl, _packetsMaxCtrl),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.successColor,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: AppTheme.successColor.withValues(alpha: 0.5)),
                      ),
                    ),
                    onPressed: () async {
                      await _saveFragmentSettings();
                      if (!context.mounted) return;
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Row(
                            children: [
                              Icon(Icons.check_circle_outline, size: 16, color: Colors.black),
                              SizedBox(width: 8),
                              Text('Fragment settings saved'),
                            ],
                          ),
                          backgroundColor: AppTheme.successColor,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.save_outlined, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'SAVE',
                          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFragmentRangeRow(
    String label,
    String unit,
    TextEditingController minCtrl,
    TextEditingController maxCtrl,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1, color: Colors.white.withValues(alpha: 0.6)),
          ),
        ),
        Expanded(child: _buildRangeField(minCtrl, 'min')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('–', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 14)),
        ),
        Expanded(child: _buildRangeField(maxCtrl, 'max')),
        SizedBox(
          width: 40,
          child: Text(
            unit,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 9, color: Colors.white.withValues(alpha: 0.3)),
          ),
        ),
      ],
    );
  }

  Widget _buildRangeField(TextEditingController controller, String hint) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      alignment: Alignment.center,
      child: TextField(
        controller: controller,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 11),
        ),
      ),
    );
  }

  Future<void> _launchExternal(String url) async {
    try {
      if (await canLaunchUrl(Uri.parse(url))) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  void _showHistory() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: const Text('Browsing History',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final url = _history[index];
                return ListTile(
                  leading: const Icon(Icons.history,
                      color: Colors.white54, size: 20),
                  title: Text(url,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onTap: () {
                    Navigator.pop(context);
                    _loadUrl(url);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        titleSpacing: 0,
        title: Container(
          height: 40,
          margin: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20)),
          child: TextField(
            controller: _urlController,
            style: const TextStyle(fontSize: 14, color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search or enter website name',
              hintStyle:
                  TextStyle(color: Colors.white.withValues(alpha: 0.3)),
              prefixIcon: Icon(Icons.lock_outline,
                  size: 16, color: Colors.white.withValues(alpha: 0.5)),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              isDense: true,
            ),
            textInputAction: TextInputAction.go,
            onSubmitted: _loadUrl,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, size: 20),
            onPressed: _showHistory,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () {
              setState(() {
                _isLoading = true;
                _progress = 0;
              });
              _controller.reload();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading)
            LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              backgroundColor: Colors.transparent,
              color: AppTheme.successColor,
              minHeight: 2,
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios, size: 18),
                  onPressed: () async {
                    if (await _controller.canGoBack()) {
                      await _controller.goBack();
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios, size: 18),
                  onPressed: () async {
                    if (await _controller.canGoForward()) {
                      await _controller.goForward();
                    }
                  },
                ),
                IconButton(
                  icon: Icon(Icons.call_split, size: 18, color: _fragmentEnabled ? AppTheme.accentColor : null),
                  tooltip: 'Packet Fragment',
                  onPressed: _showFragmentSettings,
                ),
                IconButton(
                  icon: const Icon(Icons.code, size: 18),
                  tooltip: 'GitHub',
                  onPressed: () => _launchExternal('https://github.com/maryoa61'),
                ),
                IconButton(
                  icon: const Icon(Icons.alternate_email, size: 18),
                  tooltip: 'X / Twitter',
                  onPressed: () => _launchExternal('https://x.com/ramin66m'),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.successColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                    color: AppTheme.successColor.withValues(alpha: 0.3),
                    width: 0.5),
              ),
              child: const Row(
                children: [
                  Icon(Icons.shield_outlined,
                      size: 10, color: AppTheme.successColor),
                  SizedBox(width: 4),
                  Text(
                    'PROXIED',
                    style: TextStyle(
                        color: AppTheme.successColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w900),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _lengthMinCtrl.dispose();
    _lengthMaxCtrl.dispose();
    _intervalMinCtrl.dispose();
    _intervalMaxCtrl.dispose();
    _packetsMinCtrl.dispose();
    _packetsMaxCtrl.dispose();
    super.dispose();
  }
}
