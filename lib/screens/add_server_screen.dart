import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/v2ray_server.dart';
import '../theme/app_theme.dart';

class AddServerScreen extends StatefulWidget {
  final V2RayServer? server;

  const AddServerScreen({super.key, this.server});

  @override
  State<AddServerScreen> createState() => _AddServerScreenState();
}

class _AddServerScreenState extends State<AddServerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _vmessLinkController = TextEditingController();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _portController = TextEditingController();
  final _uuidController = TextEditingController();
  final _passwordController = TextEditingController();
  final _alterIdController = TextEditingController(text: '0');

  bool _showManualForm = false;
  String _protocol = 'vmess';
  String _network = 'tcp';
  String _ssMethod = 'aes-256-gcm';
  bool _tls = false;
  String? _parseError;

  static const List<String> _ssMethods = [
    'aes-256-gcm',
    'aes-128-gcm',
    'chacha20-ietf-poly1305',
    'xchacha20-ietf-poly1305',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.server != null) {
      final s = widget.server!;
      _nameController.text = s.name;
      _addressController.text = s.address;
      _portController.text = s.port.toString();
      _uuidController.text = s.uuid;
      _passwordController.text = s.password ?? '';
      _alterIdController.text = s.alterId.toString();
      _protocol = s.protocol;
      _network = s.network;
      _tls = s.tls == 'tls';
      _ssMethod = s.ssMethod ?? 'aes-256-gcm';
      _showManualForm = true;
    }
  }

  @override
  void dispose() {
    _vmessLinkController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _portController.dispose();
    _uuidController.dispose();
    _passwordController.dispose();
    _alterIdController.dispose();
    super.dispose();
  }

  bool get _usesUuid => _protocol == 'vmess' || _protocol == 'vless';
  bool get _usesPassword => _protocol == 'trojan' || _protocol == 'shadowsocks';
  bool get _usesTransportOptions => _protocol == 'vmess' || _protocol == 'vless' || _protocol == 'trojan';

  void _importFromLink() {
    setState(() {
      _parseError = null;
    });

    final link = _vmessLinkController.text.trim();
    if (link.isEmpty) {
      setState(() => _parseError = 'Please paste a link');
      return;
    }

    try {
      final server = V2RayServer.fromAnyLink(link);
      Navigator.pop(context, server);
    } catch (e) {
      setState(() {
        _parseError = e.toString().contains('Invalid') ? 'Invalid or unsupported link format' : 'Error: ${e.toString()}';
      });
    }
  }

  void _saveManualServer() {
    if (_formKey.currentState!.validate()) {
      final server = V2RayServer(
        id: widget.server?.id ?? const Uuid().v4(),
        name: _nameController.text.trim(),
        address: _addressController.text.trim(),
        port: int.parse(_portController.text.trim()),
        uuid: _usesUuid ? _uuidController.text.trim() : '',
        password: _usesPassword ? _passwordController.text.trim() : null,
        protocol: _protocol,
        alterId: int.tryParse(_alterIdController.text.trim()) ?? 0,
        network: _protocol == 'shadowsocks' ? 'tcp' : _network,
        tls: _protocol == 'shadowsocks' ? 'none' : (_tls ? 'tls' : 'none'),
        ssMethod: _protocol == 'shadowsocks' ? _ssMethod : null,
        encryption: widget.server?.encryption,
        flow: widget.server?.flow,
      );

      Navigator.pop(context, server);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.server != null ? 'EDIT CONFIG' : 'NEW CONFIG')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_showManualForm) ...[
                Text(
                  'LINK DECODER',
                  style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.w900, color: Colors.white.withValues(alpha: 0.5)),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _vmessLinkController,
                  decoration: const InputDecoration(
                    labelText: 'VMESS / VLESS / TROJAN / SHADOWSOCKS Link',
                    hintText: 'Paste configuration link here',
                  ),
                  maxLines: 4,
                ),
                if (_parseError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _parseError!,
                      style: const TextStyle(color: AppTheme.errorColor, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(onPressed: _importFromLink, child: const Text('AUTO IMPORT')),
                ),
                const SizedBox(height: 32),
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _showManualForm = true),
                    child: Text(
                      'MANUAL CONFIGURATION',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
              ] else
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CORE PARAMETERS',
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w900,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'PROTOCOL',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w800,
                          color: Colors.white.withValues(alpha: 0.3),
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: _protocol,
                        items: const [
                          DropdownMenuItem(value: 'vmess', child: Text('VMESS', style: TextStyle(fontSize: 13, letterSpacing: 1))),
                          DropdownMenuItem(value: 'vless', child: Text('VLESS', style: TextStyle(fontSize: 13, letterSpacing: 1))),
                          DropdownMenuItem(value: 'trojan', child: Text('TROJAN', style: TextStyle(fontSize: 13, letterSpacing: 1))),
                          DropdownMenuItem(
                            value: 'shadowsocks',
                            child: Text('SHADOWSOCKS', style: TextStyle(fontSize: 13, letterSpacing: 1)),
                          ),
                        ],
                        onChanged: widget.server != null
                            ? null // Don't allow changing protocol when editing an existing server
                            : (v) => setState(() => _protocol = v!),
                        decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(labelText: 'Connection Name'),
                        validator: (value) => (value == null || value.isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextFormField(
                              controller: _addressController,
                              decoration: const InputDecoration(labelText: 'Address'),
                              validator: (value) => (value == null || value.isEmpty) ? 'Required' : null,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 1,
                            child: TextFormField(
                              controller: _portController,
                              decoration: const InputDecoration(labelText: 'Port'),
                              keyboardType: TextInputType.number,
                              validator: (value) {
                                if (value == null || value.isEmpty) return '??';
                                final port = int.tryParse(value);
                                if (port == null || port < 1 || port > 65535) return '!';
                                return null;
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_usesUuid)
                        TextFormField(
                          controller: _uuidController,
                          decoration: const InputDecoration(labelText: 'Universal Unique ID'),
                          validator: (value) => (value == null || value.isEmpty) ? 'Required' : null,
                        )
                      else if (_usesPassword)
                        TextFormField(
                          controller: _passwordController,
                          decoration: const InputDecoration(labelText: 'Password'),
                          obscureText: true,
                          validator: (value) => (value == null || value.isEmpty) ? 'Required' : null,
                        ),
                      if (_protocol == 'shadowsocks') ...[
                        const SizedBox(height: 16),
                        Text(
                          'ENCRYPTION METHOD',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800,
                            color: Colors.white.withValues(alpha: 0.3),
                          ),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: _ssMethod,
                          items: _ssMethods
                              .map(
                                (e) => DropdownMenuItem(
                                  value: e,
                                  child: Text(e, style: const TextStyle(fontSize: 13, letterSpacing: 1)),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => _ssMethod = v!),
                          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                        ),
                      ],
                      if (_usesTransportOptions) ...[
                        const SizedBox(height: 32),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'TRANSPORT',
                                    style: TextStyle(
                                      fontSize: 10,
                                      letterSpacing: 1,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white.withValues(alpha: 0.3),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  DropdownButtonFormField<String>(
                                    initialValue: _network,
                                    items: ['tcp', 'ws', 'grpc']
                                        .map(
                                          (e) => DropdownMenuItem(
                                            value: e,
                                            child: Text(e.toUpperCase(), style: const TextStyle(fontSize: 13, letterSpacing: 1)),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (v) => setState(() => _network = v!),
                                    decoration: const InputDecoration(
                                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 24),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'TLS',
                                  style: TextStyle(
                                    fontSize: 10,
                                    letterSpacing: 1,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white.withValues(alpha: 0.3),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Switch(
                                  value: _tls,
                                  onChanged: (v) => setState(() => _tls = v),
                                  activeTrackColor: Colors.white12,
                                  activeThumbColor: Colors.white,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 48),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(onPressed: _saveManualServer, child: const Text('SAVE CONFIGURATION')),
                      ),
                      if (widget.server == null)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: TextButton(
                              onPressed: () => setState(() => _showManualForm = false),
                              child: Text(
                                'BACK TO DECODER',
                                style: TextStyle(fontSize: 11, letterSpacing: 1, color: Colors.white.withValues(alpha: 0.3)),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
