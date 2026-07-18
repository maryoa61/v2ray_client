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
      final Map<String, dynamic> fullConfig = json.decode(configJson);
      fullConfig['log'] = {
        'loglevel': 'info',
        'access': _filesDir != null ? '$_filesDir/access.log' : 'none',
        'error': _filesDir != null ? '$_filesDir/error.log' : 'none',
      };
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
      // silently ignores it there (no error, but also no effect). It must
      // live INSIDE the specific outbound object you want multiplexed
      // (the "proxy" outbound), which is what actually enables it.
      try {
        final proxyOutbound = outboundsList.firstWhere(
          (o) => o['tag'] == 'proxy',
          orElse: () => null,
        );
        if (proxyOutbound != null) {
          proxyOutbound['mux'] = {
            'enabled': true,
            'concurrency': 8,
          };
          _logger.info('Mux enabled on proxy outbound (concurrency: 8)');
        } else {
          _logger.warning('No "proxy" outbound found — skipping Mux setup');
        }
      } catch (e) {
        _logger.warning('Failed to apply Mux settings (continuing without): $e');
      }
      // ============================
      // END OF MUX FIX
      // ============================
      configJson = json.encode(fullConfig);
      _logger.info('Config refined successfully - Length: ${configJson.length} bytes');
      _logger.logObject('V2Ray Final Config', fullConfig);
    } catch (e, stackTrace) {
      _logger.error('Failed to generate config: $e', stackTrace: stackTrace);
      throw Exception('Config generation failed: $e');
    }
