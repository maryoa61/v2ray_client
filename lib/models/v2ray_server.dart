import 'dart:convert';

class V2RayServer {
  final String id;
  final String name;
  final String address;
  final int port;
  final String uuid;
  final String protocol; // vmess, vless, trojan, shadowsocks
  final int alterId;
  final String network; // tcp, ws, etc.
  final String type; // none, http, etc.
  final String? host;
  final String? path;
  final String tls; // tls, none
  final String? security; // aes-128-gcm, chacha20-poly1305, auto, none
  final String? encryption; // For VLESS
  final String? flow; // For VLESS (xtls-rprx-vision, etc.)
  final String? sni;
  final String? alpn;
  final String? fingerprint;
  final String? publicKey; // For Reality
  final String? shortId; // For Reality
  final String? spiderX; // For Reality
  final String? password; // For Trojan and Shadowsocks
  final String? ssMethod; // For Shadowsocks (e.g. aes-256-gcm, chacha20-ietf-poly1305)

  V2RayServer({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.uuid,
    this.protocol = 'vmess',
    this.alterId = 0,
    this.network = 'tcp',
    this.type = 'none',
    this.host,
    this.path,
    this.tls = 'none',
    this.security,
    this.encryption,
    this.flow,
    this.sni,
    this.alpn,
    this.fingerprint,
    this.publicKey,
    this.shortId,
    this.spiderX,
    this.password,
    this.ssMethod,
  });

  // Parse from any supported link
  factory V2RayServer.fromAnyLink(String link) {
    final trimmed = link.trim();
    if (trimmed.startsWith('vmess://')) {
      return V2RayServer.fromVmessLink(trimmed);
    } else if (trimmed.startsWith('vless://')) {
      return V2RayServer.fromVlessLink(trimmed);
    } else if (trimmed.startsWith('trojan://')) {
      return V2RayServer.fromTrojanLink(trimmed);
    } else if (trimmed.startsWith('ss://')) {
      return V2RayServer.fromShadowsocksLink(trimmed);
    } else {
      throw Exception('Unsupported link protocol');
    }
  }

  // Parse from vmess:// share link
  factory V2RayServer.fromVmessLink(String vmessLink) {
    try {
      final trimmedLink = vmessLink.trim();
      if (!trimmedLink.startsWith('vmess://')) {
        throw Exception('Invalid vmess link format');
      }

      // Remove vmess:// prefix and handle potential whitespace
      String base64String = trimmedLink.replaceFirst('vmess://', '').replaceAll(RegExp(r'\s+'), '');

      // Fix base64 padding if necessary
      while (base64String.length % 4 != 0) {
        base64String += '=';
      }

      // Decode base64
      String jsonString;
      try {
        jsonString = utf8.decode(base64.decode(base64String));
      } catch (e) {
        // Try URL-safe base64 if standard fails
        final urlSafeBase64 = base64String.replaceAll('-', '+').replaceAll('_', '/');
        jsonString = utf8.decode(base64.decode(urlSafeBase64));
      }

      final jsonData = json.decode(jsonString) as Map<String, dynamic>;

      // Generate unique ID
      final id = DateTime.now().millisecondsSinceEpoch.toString();

      final name = jsonData['ps'] as String? ?? 'Server $id';
      final address = jsonData['add'] as String?;
      final portStr = jsonData['port']?.toString();
      final uuid = jsonData['id'] as String?;

      if (address == null || portStr == null || uuid == null) {
        throw Exception('Missing required fields in vmess JSON (add, port, or id)');
      }

      return V2RayServer(
        id: id,
        name: name,
        address: address,
        port: int.parse(portStr),
        uuid: uuid,
        protocol: 'vmess',
        alterId: int.parse(jsonData['aid']?.toString() ?? '0'),
        network: jsonData['net'] as String? ?? 'tcp',
        type: jsonData['type'] as String? ?? 'none',
        host: jsonData['host'] as String?,
        path: jsonData['path'] as String?,
        tls: jsonData['tls'] as String? ?? 'none',
        security: jsonData['scy'] as String?,
      );
    } catch (e) {
      throw Exception('Failed to parse vmess link: $e');
    }
  }

  // Parse from vless:// share link
  factory V2RayServer.fromVlessLink(String vlessLink) {
    try {
      final uri = Uri.parse(vlessLink);
      if (uri.scheme != 'vless') {
        throw Exception('Invalid vless link format');
      }

      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final uuid = uri.userInfo;
      final address = uri.host;
      final port = uri.port == 0 ? 443 : uri.port;

      String name = 'Server $id';
      if (uri.fragment.isNotEmpty) {
        name = Uri.decodeComponent(uri.fragment);
      } else if (uri.queryParameters.containsKey('remark')) {
        name = Uri.decodeComponent(uri.queryParameters['remark']!);
      }

      final queryParams = uri.queryParameters;

      return V2RayServer(
        id: id,
        name: name,
        address: address,
        port: port,
        uuid: uuid,
        protocol: 'vless',
        network: queryParams['type'] ?? 'tcp',
        tls: queryParams['security'] ?? 'none',
        host: queryParams['host'],
        path: queryParams['path'],
        encryption: queryParams['encryption'] ?? 'none',
        flow: queryParams['flow'],
        sni: queryParams['sni'],
        alpn: queryParams['alpn'],
        fingerprint: queryParams['fp'] ?? queryParams['fingerprint'],
        publicKey: queryParams['pbk'],
        shortId: queryParams['sid'],
        spiderX: queryParams['spx'],
      );
    } catch (e) {
      throw Exception('Failed to parse vless link: $e');
    }
  }

  // Parse from trojan:// share link
  // Format: trojan://password@server:port?security=tls&sni=...&type=ws&host=...&path=...#remark
  factory V2RayServer.fromTrojanLink(String trojanLink) {
    try {
      final uri = Uri.parse(trojanLink);
      if (uri.scheme != 'trojan') {
        throw Exception('Invalid trojan link format');
      }

      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final trojanPassword = Uri.decodeComponent(uri.userInfo);
      final address = uri.host;
      final port = uri.port == 0 ? 443 : uri.port;

      String name = 'Server $id';
      if (uri.fragment.isNotEmpty) {
        name = Uri.decodeComponent(uri.fragment);
      } else if (uri.queryParameters.containsKey('remark')) {
        name = Uri.decodeComponent(uri.queryParameters['remark']!);
      }

      final queryParams = uri.queryParameters;

      return V2RayServer(
        id: id,
        name: name,
        address: address,
        port: port,
        uuid: '', // Trojan doesn't use uuid
        password: trojanPassword,
        protocol: 'trojan',
        network: queryParams['type'] ?? 'tcp',
        // Trojan is TLS by default unless explicitly disabled
        tls: queryParams['security'] ?? 'tls',
        host: queryParams['host'],
        path: queryParams['path'],
        sni: queryParams['sni'],
        alpn: queryParams['alpn'],
        fingerprint: queryParams['fp'] ?? queryParams['fingerprint'],
      );
    } catch (e) {
      throw Exception('Failed to parse trojan link: $e');
    }
  }

  // Parse from ss:// share link
  // Supports SIP002: ss://BASE64(method:password)@server:port#remark
  // Also supports legacy: ss://BASE64(method:password@server:port)#remark
  factory V2RayServer.fromShadowsocksLink(String ssLink) {
    try {
      final trimmedLink = ssLink.trim();
      if (!trimmedLink.startsWith('ss://')) {
        throw Exception('Invalid shadowsocks link format');
      }

      String body = trimmedLink.substring(5);

      // Split off the fragment (remark) first
      String remark = '';
      final hashIndex = body.indexOf('#');
      if (hashIndex != -1) {
        remark = Uri.decodeComponent(body.substring(hashIndex + 1));
        body = body.substring(0, hashIndex);
      }

      // Strip any query string (plugin params) - not used here
      final queryIndex = body.indexOf('?');
      if (queryIndex != -1) {
        body = body.substring(0, queryIndex);
      }

      String method;
      String ssPassword;
      String address;
      int port;

      if (body.contains('@')) {
        // SIP002 format: BASE64(method:password)@server:port
        final atIndex = body.lastIndexOf('@');
        String userInfo = body.substring(0, atIndex);
        final hostPort = body.substring(atIndex + 1);

        // userInfo might be base64 or plain "method:password"
        String decodedUserInfo;
        try {
          String padded = userInfo;
          while (padded.length % 4 != 0) {
            padded += '=';
          }
          decodedUserInfo = utf8.decode(base64.decode(padded));
        } catch (e) {
          try {
            String urlSafe = userInfo.replaceAll('-', '+').replaceAll('_', '/');
            while (urlSafe.length % 4 != 0) {
              urlSafe += '=';
            }
            decodedUserInfo = utf8.decode(base64.decode(urlSafe));
          } catch (e2) {
            decodedUserInfo = userInfo; // assume already plain text
          }
        }

        final colonIndex = decodedUserInfo.indexOf(':');
        if (colonIndex == -1) {
          throw Exception('Invalid shadowsocks user info');
        }
        method = decodedUserInfo.substring(0, colonIndex);
        ssPassword = decodedUserInfo.substring(colonIndex + 1);

        final hostPortColonIndex = hostPort.lastIndexOf(':');
        if (hostPortColonIndex == -1) {
          throw Exception('Invalid shadowsocks host:port');
        }
        address = hostPort.substring(0, hostPortColonIndex);
        port = int.parse(hostPort.substring(hostPortColonIndex + 1));
      } else {
        // Legacy format: everything is base64 encoded
        String padded = body;
        while (padded.length % 4 != 0) {
          padded += '=';
        }
        String decoded;
        try {
          decoded = utf8.decode(base64.decode(padded));
        } catch (e) {
          final urlSafe = body.replaceAll('-', '+').replaceAll('_', '/');
          String p2 = urlSafe;
          while (p2.length % 4 != 0) {
            p2 += '=';
          }
          decoded = utf8.decode(base64.decode(p2));
        }

        // decoded format: method:password@server:port
        final atIndex = decoded.lastIndexOf('@');
        final userInfo = decoded.substring(0, atIndex);
        final hostPort = decoded.substring(atIndex + 1);

        final colonIndex = userInfo.indexOf(':');
        method = userInfo.substring(0, colonIndex);
        ssPassword = userInfo.substring(colonIndex + 1);

        final hostPortColonIndex = hostPort.lastIndexOf(':');
        address = hostPort.substring(0, hostPortColonIndex);
        port = int.parse(hostPort.substring(hostPortColonIndex + 1));
      }

      final id = DateTime.now().millisecondsSinceEpoch.toString();

      return V2RayServer(
        id: id,
        name: remark.isNotEmpty ? remark : 'Server $id',
        address: address,
        port: port,
        uuid: '', // Shadowsocks doesn't use uuid
        password: ssPassword,
        ssMethod: method,
        protocol: 'shadowsocks',
        network: 'tcp',
        tls: 'none',
      );
    } catch (e) {
      throw Exception('Failed to parse shadowsocks link: $e');
    }
  }

  // Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'address': address,
      'port': port,
      'uuid': uuid,
      'protocol': protocol,
      'alterId': alterId,
      'network': network,
      'type': type,
      'host': host,
      'path': path,
      'tls': tls,
      'security': security,
      'encryption': encryption,
      'flow': flow,
      'sni': sni,
      'alpn': alpn,
      'fingerprint': fingerprint,
      'publicKey': publicKey,
      'shortId': shortId,
      'spiderX': spiderX,
      'password': password,
      'ssMethod': ssMethod,
    };
  }

  // Create from JSON
  factory V2RayServer.fromJson(Map<String, dynamic> json) {
    return V2RayServer(
      id: json['id'] as String,
      name: json['name'] as String,
      address: json['address'] as String,
      port: json['port'] as int,
      uuid: json['uuid'] as String,
      protocol: json['protocol'] as String? ?? 'vmess',
      alterId: json['alterId'] as int? ?? 0,
      network: json['network'] as String? ?? 'tcp',
      type: json['type'] as String? ?? 'none',
      host: json['host'] as String?,
      path: json['path'] as String?,
      tls: json['tls'] as String? ?? 'none',
      security: json['security'] as String?,
      encryption: json['encryption'] as String?,
      flow: json['flow'] as String?,
      sni: json['sni'] as String?,
      alpn: json['alpn'] as String?,
      fingerprint: json['fingerprint'] as String?,
      publicKey: json['publicKey'] as String?,
      shortId: json['shortId'] as String?,
      spiderX: json['spiderX'] as String?,
      password: json['password'] as String?,
      ssMethod: json['ssMethod'] as String?,
    );
  }

  // Generate V2Ray config JSON
  Map<String, dynamic> toV2RayConfig({List<String>? customDns}) {
    final outboundSettings = _buildOutboundSettings();

    return {
      'log': {'loglevel': 'warning'},
      'dns': {
        'hosts': {'dns.google': '8.8.8.8', 'proxy.google': '8.8.4.4'},
        'servers': customDns ?? ['8.8.8.8', '8.8.4.4', '1.1.1.1', 'localhost'],
      },
      'routing': {
        'domainStrategy': 'IPOnDemand',
        'rules': [
          {'type': 'field', 'port': 53, 'outboundTag': 'dns-out'},
          {
            'type': 'field',
            'ip': ['1.1.1.1', '8.8.8.8', '8.8.4.4'],
            'outboundTag': 'proxy',
          },
          {
            'type': 'field',
            'domain': ['geosite:google', 'geosite:github'],
            'outboundTag': 'proxy',
          },
          {'type': 'field', 'outboundTag': 'proxy', 'network': 'tcp,udp'},
        ],
      },
      'outbounds': [
        {'tag': 'proxy', 'protocol': protocol, 'settings': outboundSettings, 'streamSettings': _buildStreamSettings()},
        {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
        {'tag': 'block', 'protocol': 'blackhole', 'settings': {}},
        {'tag': 'dns-out', 'protocol': 'dns', 'settings': {}},
      ],
    };
  }

  Map<String, dynamic> _buildOutboundSettings() {
    if (protocol == 'vmess') {
      return {
        'vnext': [
          {
            'address': address,
            'port': port,
            'users': [
              {'id': uuid, 'alterId': alterId, 'security': security ?? 'auto'},
            ],
          },
        ],
      };
    } else if (protocol == 'vless') {
      final userSettings = <String, dynamic>{'id': uuid, 'encryption': encryption ?? 'none'};

      if (flow != null && flow!.isNotEmpty) {
        userSettings['flow'] = flow!;
      }

      return {
        'vnext': [
          {
            'address': address,
            'port': port,
            'users': [userSettings],
          },
        ],
      };
    } else if (protocol == 'trojan') {
      return {
        'servers': [
          {
            'address': address,
            'port': port,
            'password': password ?? '',
            if (name.isNotEmpty) 'email': name,
          },
        ],
      };
    } else if (protocol == 'shadowsocks') {
      return {
        'servers': [
          {
            'address': address,
            'port': port,
            'method': ssMethod ?? 'aes-256-gcm',
            'password': password ?? '',
          },
        ],
      };
    }

    // Fallback (shouldn't happen)
    return {};
  }

  Map<String, dynamic> _buildStreamSettings() {
    // Shadowsocks generally runs raw over tcp without extra stream wrapping
    if (protocol == 'shadowsocks') {
      return {'network': 'tcp', 'security': 'none'};
    }

    final streamSettings = <String, dynamic>{
      'network': network,
      'security': tls == 'none' ? 'none' : tls, // Could be 'tls' or 'reality'
    };

    if (network == 'ws') {
      streamSettings['wsSettings'] = {
        if (host != null) 'headers': {'Host': host},
        if (path != null) 'path': path,
      };
    }

    if (network == 'tcp' && type != 'none') {
      streamSettings['tcpSettings'] = {
        'header': {
          'type': type,
          if (type == 'http')
            'request': {
              'version': '1.1',
              'method': 'GET',
              'uri': ['/'],
              'headers': {
                'Host': [host ?? address],
                'User-Agent': ['Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'],
                'Content-Type': ['application/octet-stream'],
                'Transfer-Encoding': ['chunked'],
              },
            },
        },
      };
    }

    if (tls != 'none') {
      streamSettings['tlsSettings'] = {
        'serverName': sni ?? host ?? address,
        'allowInsecure': true,
        if (alpn != null && alpn!.isNotEmpty) 'alpn': alpn!.split(','),
        if (fingerprint != null) 'fingerprint': fingerprint,
      };
    }

    if (tls == 'reality') {
      streamSettings['realitySettings'] = {
        'show': false,
        'fingerprint': fingerprint ?? 'chrome',
        'serverName': sni ?? host ?? address,
        'publicKey': publicKey ?? '',
        'shortId': shortId ?? '',
        'spiderX': spiderX ?? '',
      };
    }

    return streamSettings;
  }

  @override
  String toString() {
    return 'V2RayServer(name: $name, address: $address:$port, protocol: $protocol)';
  }

  String toShareLink() {
    switch (protocol) {
      case 'vmess':
        return _generateVmessShareLink();
      case 'trojan':
        return _generateTrojanShareLink();
      case 'shadowsocks':
        return _generateShadowsocksShareLink();
      default:
        return _generateVlessShareLink();
    }
  }

  String _generateVmessShareLink() {
    final vmessData = {
      'v': '2',
      'ps': name,
      'add': address,
      'port': port.toString(),
      'id': uuid,
      'aid': alterId.toString(),
      'net': network,
      'type': type,
      if (host != null) 'host': host,
      if (path != null) 'path': path,
      'tls': tls,
      if (security != null) 'scy': security,
    };

    final jsonString = json.encode(vmessData);
    final base64String = base64.encode(utf8.encode(jsonString));
    return 'vmess://$base64String';
  }

  String _generateVlessShareLink() {
    String userInfo = uuid;
    String authority = '$address:$port';
    String query = '';

    if (network.isNotEmpty && network != 'tcp') {
      query += 'type=$network';
    }

    if (security != null && security!.isNotEmpty && security != 'none') {
      if (query.isNotEmpty) query += '&';
      query += 'security=$security';
    }

    if (host != null && host!.isNotEmpty) {
      if (query.isNotEmpty) query += '&';
      query += 'host=${Uri.encodeComponent(host!)}';
    }

    if (path != null && path!.isNotEmpty) {
      if (query.isNotEmpty) query += '&';
      query += 'path=${Uri.encodeComponent(path!)}';
    }

    if (encryption != null && encryption!.isNotEmpty) {
      if (query.isNotEmpty) query += '&';
      query += 'encryption=$encryption';
    }

    if (flow != null && flow!.isNotEmpty) {
      if (query.isNotEmpty) query += '&';
      query += 'flow=${Uri.encodeComponent(flow!)}';
    }

    final encodedName = Uri.encodeComponent(name);
    final fragment = encodedName;

    String url = 'vless://$userInfo@$authority';
    if (query.isNotEmpty) url += '?$query';
    url += '#$fragment';

    return url;
  }

  String _generateTrojanShareLink() {
    String authority = '$address:$port';
    String query = '';

    if (tls.isNotEmpty && tls != 'none') {
      query += 'security=$tls';
    }

    if (network.isNotEmpty && network != 'tcp') {
      if (query.isNotEmpty) query += '&';
      query += 'type=$network';
    }

    if (host != null && host!.isNotEmpty) {
      if (query.isNotEmpty) query += '&';
      query += 'host=${Uri.encodeComponent(host!)}';
    }

    if (path != null && path!.isNotEmpty) {
      if (query.isNotEmpty) query += '&';
      query += 'path=${Uri.encodeComponent(path!)}';
    }

    if (sni != null && sni!.isNotEmpty) {
      if (query.isNotEmpty) query += '&';
      query += 'sni=${Uri.encodeComponent(sni!)}';
    }

    final encodedPassword = Uri.encodeComponent(password ?? '');
    final encodedName = Uri.encodeComponent(name);

    String url = 'trojan://$encodedPassword@$authority';
    if (query.isNotEmpty) url += '?$query';
    url += '#$encodedName';

    return url;
  }

  String _generateShadowsocksShareLink() {
    final method = ssMethod ?? 'aes-256-gcm';
    final userInfo = '$method:${password ?? ''}';
    final encodedUserInfo = base64.encode(utf8.encode(userInfo)).replaceAll('=', '');
    final encodedName = Uri.encodeComponent(name);

    return 'ss://$encodedUserInfo@$address:$port#$encodedName';
  }
}
