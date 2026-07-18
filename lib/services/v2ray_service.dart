// Step 4: Generate V2Ray configuration manually
    _logger.info('Step 3/7: Generating V2Ray configuration manually...');
    String configJson;
    try {
      final config = server.toV2RayConfig(
        customDns: customDns?.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      );
      config['inbounds'] = [
        {
          'tag': 'socks',
          'port': 10808,
          'listen': '127.0.0.1',
          'protocol': 'socks',
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls'],
          },
          'settings': {'auth': 'noauth', 'udp': true},
        },
        {
          'tag': 'http',
          'port': 10809,
          'listen': '127.0.0.1',
          'protocol': 'http',
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls'],
          },
        },
      ];
      config['routing'] = {
        'domainStrategy': 'IPOnDemand',
        'rules': [
          {'type': 'field', 'outboundTag': 'proxy', 'network': 'tcp,udp'},
        ],
      };
      config['log'] = {'loglevel': 'info', 'access': 'none', 'error': 'none'};
      configJson = json.encode(config);

      // Inject core settings that might be missing from the stub generator
      final Map<String, dynamic> fullConfig = json.decode(configJson);

      // Ensure log level is correct and enable file logs in private storage
      fullConfig['log'] = {
        'loglevel': 'info',
        'access': _filesDir != null ? '$_filesDir/access.log' : 'none',
        'error': _filesDir != null ? '$_filesDir/error.log' : 'none',
      };

      // Ensure inbounds are correct for VPN mode
      // Tags avoid conflict with the 'proxy' outbound tag
      fullConfig['inbounds'] = [
        {
          "tag": "socks-in",
          "port": 10808,
          "listen": "127.0.0.1",
          "protocol": "socks",
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"],
          },
          "settings": {"auth": "noauth", "udp": true},
        },
        {
          "tag": "http-in",
          "port": 10809,
          "listen": "127.0.0.1",
          "protocol": "http",
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"],
          },
        },
      ];

      // Ensure we have direct and dns outbounds
      if (fullConfig['outbounds'] == null) fullConfig['outbounds'] = [];
      List<dynamic> outboundsList = fullConfig['outbounds'];

      if (!outboundsList.any((o) => o['tag'] == 'direct')) {
        outboundsList.add({'tag': 'direct', 'protocol': 'freedom', 'settings': {}});
      }
      if (!outboundsList.any((o) => o['tag'] == 'dns-out')) {
        outboundsList.add({'tag': 'dns-out', 'protocol': 'dns', 'settings': {}});
      }

      // ============================
      // 🔥 FIX: ADD MUX SETTINGS HERE
      // ============================
      // NOTE: "mux" is NOT a valid top-level V2Ray config field — V2Ray core
      // silently ignores it there (no error, but no effect either). It must
      // live INSIDE the specific outbound object you want multiplexed (the
      // "proxy" outbound), which is what actually enables it. Skipped for
      // transports where V2Ray's mux is known to misbehave (e.g. QUIC,
      // which already multiplexes on its own).
      try {
        final proxyOutbound = outboundsList.firstWhere(
          (o) => o['tag'] == 'proxy',
          orElse: () => null,
        );
        if (proxyOutbound != null) {
          final network = (proxyOutbound['streamSettings']?['network'] as String?)?.toLowerCase();
          final muxIncompatible = network == 'quic';

          if (!muxIncompatible) {
            proxyOutbound['mux'] = {
              'enabled': true,
              'concurrency': 8,
            };
            _logger.info('Mux enabled on proxy outbound (concurrency: 8)');
          } else {
            _logger.info('Mux skipped: incompatible with $network transport');
          }
        } else {
          _logger.warning('No "proxy" outbound found — skipping Mux setup');
        }
      } catch (e) {
        _logger.warning('Failed to apply Mux settings (continuing without): $e');
      }
      // ============================
      // END OF MUX FIX
      // ============================

      // DNS Configuration - Fetch system DNS dynamically
      _logger.info('Step 4/7: Fetching system DNS...');
      List<String> systemDnsServers = [];
      try {
        systemDnsServers = await _v2rayPlugin.getSystemDns();
        _logger.info('Device DNS servers: $systemDnsServers');
      } catch (e) {
        _logger.warning('Failed to fetch system DNS, will use fallback: $e');
      }

      // Resolve Server IP for bypass rule and outbound
      _logger.info('Step 5/7: Resolving server IP...');
      String resolvedIp = server.address;
      bool isIp = RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(server.address);

      if (!isIp) {
        try {
          final addresses = await InternetAddress.lookup(server.address);
          if (addresses.isNotEmpty) {
            resolvedIp = addresses.first.address;
            _logger.info('Cloud domain ${server.address} resolved to $resolvedIp');
          }
        } catch (e) {
          _logger.warning('DNS lookup failed for ${server.address}: $e');
        }
      }

      // IMPORTANT: Use the resolved IP in the outbound settings to avoid redundant lookups
      // and potential circular routing issues within the tunnel.
      if (fullConfig['outbounds'] != null && fullConfig['outbounds'].isNotEmpty) {
        for (var outbound in fullConfig['outbounds']) {
          if (outbound['tag'] == 'proxy' && outbound['settings'] != null && outbound['settings']['vnext'] != null) {
            outbound['settings']['vnext'][0]['address'] = resolvedIp;
            _logger.info('Updated outbound address to resolved IP: $resolvedIp');
          }
        }
      }

      // Prioritize Custom DNS if available
      final List<String> effectiveDns = [];
      if (customDns != null && customDns.isNotEmpty) {
        effectiveDns.addAll(customDns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty));
        _logger.info('Using Custom DNS: $effectiveDns');
      }

      // If no custom DNS, fall back to system DNS, then to a hardcoded default
      if (effectiveDns.isEmpty) {
        if (systemDnsServers.isNotEmpty) {
          effectiveDns.addAll(systemDnsServers);
        } else {
          effectiveDns.addAll(["8.8.8.8", "1.1.1.1"]);
        }
        _logger.info('Using System/Default DNS: $effectiveDns');
      }

      fullConfig['dns'] = {
        "servers": [...effectiveDns, "localhost"], // localhost needed for internal routing sometimes
        "queryStrategy": "UseIP",
      };

      // Routing Strategy - Robust rules
      fullConfig['routing'] = {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
          // Rule 1: Hijack all DNS traffic to dns-out (CRITICAL — prevents DNS
          // queries from being routed through the not-yet-ready proxy outbound)
          {"type": "field", "port": 53, "outboundTag": "dns-out"},
          // Rule 2: Bypass the server's own IP to prevent routing deadlock/loop
          {
            "type": "field",
            "ip": [resolvedIp],
            "outboundTag": "direct",
          },
          // If it was a domain, also bypass the domain itself
          if (!isIp)
            {
              "type": "field",
              "domain": [server.address],
              "outboundTag": "direct",
            },
          // Rule 3: Bypass local network traffic
          {
            "type": "field",
            "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "::1/128", "fc00::/7", "fe80::/10"],
            "outboundTag": "direct",
          },
          // Rule 4: Bypass DNS servers to prevent resolution deadlock
          {
            "type": "field",
            "ip": systemDnsServers.isNotEmpty ? systemDnsServers : ["8.8.8.8", "1.1.1.1", "1.0.0.1", "8.8.4.4"],
            "outboundTag": "direct",
          },
          // Rule 5: Hijack inbound traffic to proxy
          {
            "type": "field",
            "inboundTag": ["socks-in", "http-in"],
            "outboundTag": "proxy",
          },
          // Rule 6: Final catch-all for anything else from local/TUN
          {"type": "field", "network": "tcp,udp", "outboundTag": "proxy"},
        ],
      };

      // Re-encode
      configJson = json.encode(fullConfig);

      _logger.info('Config refined successfully - Length: ${configJson.length} bytes');
      _logger.logObject('V2Ray Final Config', fullConfig);
    } catch (e, stackTrace) {
      _logger.error('Failed to generate config: $e', stackTrace: stackTrace);
      throw Exception('Config generation failed: $e');
    }
