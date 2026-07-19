import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:v2ray_dan/v2ray_dan.dart';
import '../models/v2ray_server.dart';
import '../models/proxy_mode.dart';
import 'logger_service.dart';
import 'storage_service.dart';

enum VPNConnectionStatus { disconnected, connecting, connected, disconnecting, error }

class V2RayService {
  static final V2RayService _instance = V2RayService._internal();
  factory V2RayService() => _instance;

  late final V2ray _v2rayPlugin;
  late final LoggerService _logger;
  StorageService? _storage;

  VPNConnectionStatus _status = VPNConnectionStatus.disconnected;
  V2RayServer? _currentServer;
  String? _lastError;
  String? _filesDir;
  bool _isInitialized = false;
  Timer? _logPollingTimer;
  bool _isConnectInProgress = false;
  ProxyMode _proxyMode = ProxyMode.socks; // Default to SOCKS

  // ---------------------------------------------------------------------
  // Auto-reconnect state
  // ---------------------------------------------------------------------
  // The last server + connection params the user explicitly connected to.
  // Kept around so we can silently redial it if the connection drops for
  // a reason the user didn't ask for (network switch, core crash, etc).
  V2RayServer? _lastServer;
  String? _lastCustomDns;
  bool _lastProxyOnly = false;
  bool _lastUseSystemDns = true;
  ProxyMode? _lastProxyMode;

  // True only while disconnect() is running because the USER tapped
  // disconnect (or switched servers). False for internal/defensive
  // disconnects (e.g. the "clean slate" reset at the top of connect()).
  // Auto-reconnect only fires when a drop happens with this flag false.
  bool _userInitiatedDisconnect = true;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  ConnectivityResult? _lastConnectivityResult;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _isReconnecting = false;

  // User-configurable via StorageService.saveAutoReconnectSettings().
  // Sane defaults here match StorageService's own defaults, so behavior
  // is correct even before init() has had a chance to load saved prefs.
  bool _autoReconnectEnabled = true;
  int _maxReconnectAttempts = 6;

  // Exponential backoff schedule: 1s, 2s, 4s, 8s, 8s, 8s...
  static const List<int> _backoffSeconds = [1, 2, 4, 8];

  bool get autoReconnectEnabled => _autoReconnectEnabled;
  int get maxReconnectAttempts => _maxReconnectAttempts;

  VPNConnectionStatus get status => _status;
  V2RayServer? get currentServer => _currentServer;
  String? get lastError => _lastError;
  bool get isReconnecting => _isReconnecting;

  // Stream for status changes
  final StreamController<VPNConnectionStatus> _statusController = StreamController<VPNConnectionStatus>.broadcast();
  Stream<VPNConnectionStatus> get statusStream => _statusController.stream;

  V2RayService._internal() {
    _logger = LoggerService();
    _v2rayPlugin = V2ray(
      onStatusChanged: (status) {
        final newStatus = _mapPluginStatus(status.state);
        if (_status != newStatus) {
          _logger.info('Native Status Broadcast: ${status.state} -> $newStatus');
          _handleNativeStatusChange(newStatus);
        }
      },
    );
    _logger.info('V2RayService Singleton initialized');
    _setupAndroidLogReceiver();
    _startConnectivityMonitoring();
  }

  // ---------------------------------------------------------------------
  // Safe status emission.
  //
  // This service is a singleton and is expected to live for the entire
  // app lifetime. dispose() should ONLY ever be called once, at true app
  // shutdown (e.g. from main()'s top-level teardown, or never at all in
  // a long-running app) — NEVER from a page/widget's State.dispose().
  // Tying a singleton's lifetime to a single screen is what causes the
  // "already-closed stream" crash: some in-flight async call (native
  // MethodChannel init, a delayed Future, a timer callback) finishes
  // after the screen — and therefore the service — has been disposed,
  // and then tries to emit a status.
  //
  // _safeEmit() is the defensive layer: it makes every emission a no-op
  // once the controller is closed, instead of throwing. It also updates
  // _status even if the controller is closed, so status reads via the
  // `status` getter stay correct.
  // ---------------------------------------------------------------------
  void _safeEmit(VPNConnectionStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    } else {
      _logger.warning('Attempted to emit status "$status" after V2RayService was disposed (ignored).');
    }
  }

  // Handles status broadcasts coming from the native side (outside of our
  // own connect()/disconnect() calls). This is where an unexpected drop
  // (native crash, VPN killed by OS, server closed the connection, etc.)
  // gets detected and routed into the auto-reconnect flow.
  void _handleNativeStatusChange(VPNConnectionStatus newStatus) {
    final wasConnected = _status == VPNConnectionStatus.connected;
    _safeEmit(newStatus);

    final droppedUnexpectedly =
        wasConnected &&
        (newStatus == VPNConnectionStatus.disconnected || newStatus == VPNConnectionStatus.error) &&
        !_userInitiatedDisconnect;

    if (droppedUnexpectedly) {
      _logger.warning('Connection dropped unexpectedly (native). Triggering auto-reconnect.');
      _scheduleReconnect();
    }
  }

  // Setup receiver for Android/Kotlin logs
  void _setupAndroidLogReceiver() {
    try {
      // Use the plugin's MethodChannel name
      const platform = MethodChannel('com.flaming.cherubim/logs');

      platform.setMethodCallHandler((call) async {
        if (call.method == 'log') {
          final level = call.arguments['level'] as String?;
          final message = call.arguments['message'] as String?;

          if (message != null) {
            // Forward Android logs to Flutter logger
            switch (level) {
              case 'ERROR':
                _logger.error(message);
                break;
              case 'WARN':
                _logger.warning(message);
                break;
              case 'DEBUG':
                _logger.debug(message);
                break;
              default:
                _logger.info(message);
            }
          }
        }
      });

      _logger.info('✓ Android log receiver setup complete');
    } catch (e) {
      _logger.warning('Failed to setup Android log receiver: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Connectivity monitoring (for auto-reconnect on network switch)
  //
  // Watches for Wi-Fi <-> mobile data changes (or losing connectivity
  // entirely). If we're supposed to be connected (we have a _lastServer
  // and the drop wasn't user-initiated) and the network flips, we kick
  // off a reconnect. We don't reconnect just because connectivity
  // *appeared* — only on a genuine change while we expect to be online,
  // to avoid redialing on app startup.
  // ---------------------------------------------------------------------
  void _startConnectivityMonitoring() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
      final previous = _lastConnectivityResult;
      _lastConnectivityResult = result;

      // First callback just primes _lastConnectivityResult; nothing to react to yet.
      if (previous == null) return;

      if (previous == result) return; // no real change (duplicate event)

      _logger.info('Connectivity changed: $previous -> $result');

      if (result == ConnectivityResult.none) {
        // Network gone entirely — nothing to do until it comes back;
        // the reconnect loop (if already running) will keep retrying
        // and naturally succeed once connectivity returns.
        return;
      }

      final shouldBeConnected = _lastServer != null && !_userInitiatedDisconnect;
      final currentlyHealthy = _status == VPNConnectionStatus.connected && !_isReconnecting;

      if (shouldBeConnected && !currentlyHealthy) {
        _logger.info('Network switched while VPN should be active — reconnecting...');
        _scheduleReconnect(immediate: true);
      } else if (shouldBeConnected && currentlyHealthy) {
        // Underlying interface changed (e.g. Wi-Fi -> mobile data) while
        // "connected". The V2Ray tunnel's sockets are bound to the old
        // interface and will silently die, so proactively restart it
        // instead of waiting for a timeout to prove that.
        _logger.info('Network interface changed while connected — restarting tunnel to rebind sockets.');
        _scheduleReconnect(immediate: true);
      }
    });
  }

  // Schedules a reconnect attempt using exponential backoff. Safe to call
  // repeatedly — it just resets the pending timer rather than stacking
  // multiple attempts.
  void _scheduleReconnect({bool immediate = false}) {
    if (!_autoReconnectEnabled) {
      _logger.info('Auto-reconnect skipped: feature disabled by user.');
      return;
    }
    if (_lastServer == null) {
      _logger.info('Auto-reconnect skipped: no previous server to reconnect to.');
      return;
    }
    if (_userInitiatedDisconnect) {
      _logger.info('Auto-reconnect skipped: last disconnect was user-initiated.');
      return;
    }
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _logger.error('Auto-reconnect giving up after $_reconnectAttempts attempts.');
      _isReconnecting = false;
      return;
    }

    _reconnectTimer?.cancel();
    _isReconnecting = true;

    final delaySeconds = immediate
        ? 0
        : _backoffSeconds[min(_reconnectAttempts, _backoffSeconds.length - 1)];

    _logger.info('Auto-reconnect attempt #${_reconnectAttempts + 1} in ${delaySeconds}s...');

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      // Conditions may have changed while we were waiting (user manually
      // disconnected, or manually connected elsewhere) — bail out cleanly.
      if (_userInitiatedDisconnect || _lastServer == null) {
        _isReconnecting = false;
        return;
      }
      if (_isConnectInProgress) {
        // Something else is already connecting; try again shortly.
        _scheduleReconnect();
        return;
      }

      _reconnectAttempts++;
      final server = _lastServer!;
      _logger.info('Reconnecting to ${server.name} (attempt $_reconnectAttempts/$_maxReconnectAttempts)...');

      final success = await connect(
        server,
        customDns: _lastCustomDns,
        proxyOnly: _lastProxyOnly,
        useSystemDns: _lastUseSystemDns,
        proxyMode: _lastProxyMode,
        isAutoReconnect: true,
      );

      if (success) {
        _logger.info('✓ Auto-reconnect succeeded.');
        _reconnectAttempts = 0;
        _isReconnecting = false;
      } else {
        _logger.warning('Auto-reconnect attempt failed, scheduling next try.');
        _scheduleReconnect();
      }
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _isReconnecting = false;
  }

  void _loadAutoReconnectSettings() {
    try {
      final settings = _storage?.loadAutoReconnectSettings();
      if (settings != null) {
        _autoReconnectEnabled = settings['enabled'] as bool? ?? true;
        _maxReconnectAttempts = settings['maxAttempts'] as int? ?? 6;
        _logger.info('Auto-reconnect settings loaded: enabled=$_autoReconnectEnabled, maxAttempts=$_maxReconnectAttempts');
      }
    } catch (e) {
      _logger.warning('Failed to load auto-reconnect settings, using defaults: $e');
    }
  }

  // Lets the UI (e.g. a settings screen) change auto-reconnect behavior
  // at runtime. Persists via StorageService so it survives app restarts.
  Future<void> setAutoReconnectSettings({bool? enabled, int? maxAttempts}) async {
    if (enabled != null) _autoReconnectEnabled = enabled;
    if (maxAttempts != null) _maxReconnectAttempts = maxAttempts;

    _logger.info('Auto-reconnect settings updated: enabled=$_autoReconnectEnabled, maxAttempts=$_maxReconnectAttempts');

    // If the user just turned it off, stop any pending/in-flight attempt
    // immediately instead of waiting for it to naturally give up.
    if (!_autoReconnectEnabled) {
      _cancelReconnect();
    }

    try {
      await _storage?.saveAutoReconnectSettings(
        enabled: _autoReconnectEnabled,
        maxAttempts: _maxReconnectAttempts,
      );
    } catch (e) {
      _logger.warning('Failed to persist auto-reconnect settings: $e');
    }
  }

  VPNConnectionStatus _mapPluginStatus(String state) {
    switch (state.toLowerCase()) {
      case 'connected':
        return VPNConnectionStatus.connected;
      case 'connecting':
        return VPNConnectionStatus.connecting;
      case 'disconnecting':
        return VPNConnectionStatus.disconnecting;
      case 'disconnected':
        return VPNConnectionStatus.disconnected;
      case 'error':
        return VPNConnectionStatus.error;
      default:
        return VPNConnectionStatus.disconnected;
    }
  }

  // Initialize V2Ray core
  Future<void> init() async {
    if (_isInitialized) {
      _logger.info('V2Ray core already initialized, skipping...');
      return;
    }

    try {
      _logger.info('========== Initializing V2Ray Core ==========');

      // Initialize storage so fragment settings (and future settings) are readable.
      _storage ??= await StorageService.init();
      _loadAutoReconnectSettings();

      // CRITICAL: Initialize the V2Ray plugin before first use
      // This is required by flutter_v2ray_client and sets up the native services
      _logger.info('Calling v2ray.initialize()...');
      try {
        _filesDir = await _v2rayPlugin
            .initialize(notificationIconResourceType: 'drawable', notificationIconResourceName: 'ic_stat_v2ray')
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                throw TimeoutException('V2Ray initialization timed out');
              },
            );
        _logger.info('V2Ray plugin initialized successfully');
        _logger.info('App files directory: $_filesDir');
      } catch (e, stackTrace) {
        _logger.error('FATAL: V2Ray plugin initialization failed: $e', stackTrace: stackTrace);
        throw Exception('Failed to initialize V2Ray plugin: $e');
      }

      // Verify plugin is working by getting core version
      _logger.info('Verifying V2Ray core is responsive...');
      try {
        final version = await _v2rayPlugin.getCoreVersion().timeout(const Duration(seconds: 3), onTimeout: () => '');
        if (version != null && version.isNotEmpty) {
          _logger.info('✓ V2Ray core version: $version');
        } else {
          _logger.warning('Could not retrieve core version (may not be critical)');
        }
      } catch (e) {
        _logger.warning('Core version check failed (non-fatal): $e');
      }

      _isInitialized = true;
      _logger.info('========== V2Ray initialization complete ==========');
    } catch (e, stackTrace) {
      _lastError = 'Failed to initialize V2Ray: $e';
      _logger.error(_lastError!, stackTrace: stackTrace);
      _safeEmit(VPNConnectionStatus.error);
      rethrow; // Re-throw so the app knows initialization failed
    }
  }

  // Check for VPN permission
  Future<bool> checkPermission() async {
    _logger.info('Checking VPN permission...');
    try {
      final hasPermission = await _v2rayPlugin.requestPermission().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _logger.error('VPN permission request timed out');
          return false;
        },
      );

      _logger.info('VPN permission status: ${hasPermission ? "granted" : "denied"}');
      return hasPermission;
    } catch (e, stackTrace) {
      _logger.error('VPN permission check failed: $e', stackTrace: stackTrace);
      return false;
    }
  }

  // Full System Reset
  Future<void> fullSystemReset() async {
    _logger.warning('========== INITIATING FULL SYSTEM RESET ==========');

    // A full reset is always user-initiated — make sure auto-reconnect
    // doesn't try to bring the tunnel back up right before we exit.
    _userInitiatedDisconnect = true;
    _cancelReconnect();
    _lastServer = null;

    // Force stop V2Ray
    try {
      await _v2rayPlugin.stopV2Ray();
    } catch (e) {
      _logger.error('Reset: Failed to stop V2Ray (ignoring): $e');
    }

    // Clear internal state
    _currentServer = null;
    _lastError = null;
    _safeEmit(VPNConnectionStatus.disconnected);

    _logger.warning('========== SYSTEM RESET COMPLETE ==========');

    // Force App Exit (User must manually relaunch)
    // Using exit(0) is drastic but requested.
    exit(0);
  }

  // Connect to a V2Ray server
  Future<bool> connect(
    V2RayServer server, {
    String? customDns,
    bool proxyOnly = false,
    bool useSystemDns = true,
    ProxyMode? proxyMode,
    bool isAutoReconnect = false,
  }) async {
    _logger.info('========== Starting connection process ==========');
    _logger.info('Mode: ${proxyOnly ? "Proxy Only" : "VPN (System-wide)"}');
    _logger.info('Server: ${server.name} (${server.address}:${server.port})');
    _logger.info('Protocol: ${server.protocol}');
    if (isAutoReconnect) {
      _logger.info('(this is an auto-reconnect attempt)');
    }

    // Any explicit call to connect() — including auto-reconnect redials —
    // means we're no longer in a "user wants to be disconnected" state.
    _userInitiatedDisconnect = false;

    // Set proxy mode (with default)
    _proxyMode = proxyMode ?? ProxyMode.socks;
    _logger.info('Proxy Mode: ${_proxyMode.displayName}');

    // Platform validation
    if (!Platform.isAndroid && !Platform.isMacOS) {
      _logger.error('Unsupported platform: ${Platform.operatingSystem}');
      _cleanupAfterError('Flaming Cherubim currently only supports VPN connections on Android and macOS.');
      return false;
    }

    try {
      // Use a slightly longer timeout to prevent premature "stuck" declarations
      final result = await _runConnectLogic(server, customDns, proxyOnly, useSystemDns).timeout(
        const Duration(seconds: 45), // Increased timeout to allow for macOS admin prompt interaction
        onTimeout: () {
          _logger.error('Connection logic timed out after 45 seconds');
          // Don't throw - try to clean up and return false to keep UI alive
          _cleanupAfterError('Connection timed out');
          return false;
        },
      );

      if (result) {
        // Remember exactly what "being connected" means so auto-reconnect
        // can faithfully reproduce it later.
        _lastServer = server;
        _lastCustomDns = customDns;
        _lastProxyOnly = proxyOnly;
        _lastUseSystemDns = useSystemDns;
        _lastProxyMode = proxyMode;
      }

      return result;
    } catch (e, stackTrace) {
      _logger.error('========== Connection failed ==========');
      _logger.error('Error: $e', stackTrace: stackTrace);
      _cleanupAfterError('Connection error: $e');
      return false;
    }
  }

  Future<void> _cleanupAfterError(String errorMsg) async {
    _lastError = errorMsg;
    _currentServer = null;
    _safeEmit(VPNConnectionStatus.error);

    // Try to cleanup any partial connection
    try {
      _logger.info('Attempting cleanup after failed connection...');
      await _v2rayPlugin.stopV2Ray();
    } catch (cleanupError) {
      _logger.warning('Cleanup failed (non-fatal): $cleanupError');
    }
  }

  Future<bool> _runConnectLogic(V2RayServer server, String? customDns, bool proxyOnly, bool useSystemDns) async {
    // Guard against concurrent connection attempts
    if (_isConnectInProgress) {
      throw Exception('Connection already in progress, please wait');
    }
    _isConnectInProgress = true;

    try {
      return await _runConnectLogicInternal(server, customDns, proxyOnly, useSystemDns);
    } finally {
      _isConnectInProgress = false;
    }
  }

  // ---------------------------------------------------------------------
  // Builds a fully-runnable V2Ray config: inbounds, direct/dns-out
  // outbounds, Mux, fragment, DNS servers, and the IP/domain bypass +
  // routing rules for the proxy server itself.
  //
  // This is the SINGLE source of truth for config generation. It is used
  // both by connect() (to actually start the tunnel) and by
  // getServerDelay() (to ping-test a server). Previously getServerDelay()
  // called server.toV2RayConfig() directly and skipped all of this,
  // producing a "bare" config with no routing/dns/outbound rules — which
  // meant the delay test measured something different from what the real
  // tunnel does, and could fail/timeout even when the real connection was
  // fine (or vice versa).
  // ---------------------------------------------------------------------
  Future<String> _buildRunnableConfig(V2RayServer server, {String? customDns}) async {
    final dnsList = customDns?.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final Map<String, dynamic> fullConfig = server.toV2RayConfig(customDns: dnsList);

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

    // Mux (multiplexing) on the main proxy outbound.
    // Bundles multiple logical TCP streams over a single connection to
    // the server, cutting down on handshake overhead for pages/apps
    // that open many concurrent connections. Skipped for protocols
    // where V2Ray's mux is known to misbehave (e.g. some QUIC-based
    // transports) — those advertise their own multiplexing already.
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

    // Packet Fragment (TLS handshake fragmentation to evade DPI).
    // Read the user's saved settings and, if enabled, inject them into
    // the "direct" freedom outbound's settings.
    try {
      final fragment = _storage?.loadFragmentSettings();
      if (fragment != null && fragment['enabled'] == true) {
        final directOutbound = outboundsList.firstWhere((o) => o['tag'] == 'direct');
        directOutbound['settings'] = {
          ...(directOutbound['settings'] as Map? ?? {}),
          'fragment': {
            'packets': '${fragment['packetsMin']}-${fragment['packetsMax']}',
            'length': '${fragment['lengthMin']}-${fragment['lengthMax']}',
            'interval': '${fragment['intervalMin']}-${fragment['intervalMax']}',
          },
        };
        _logger.info(
          'Fragment enabled: packets=${fragment['packetsMin']}-${fragment['packetsMax']}, '
          'length=${fragment['lengthMin']}-${fragment['lengthMax']}, '
          'interval=${fragment['intervalMin']}-${fragment['intervalMax']}',
        );
      }
    } catch (e) {
      _logger.warning('Failed to apply fragment settings (continuing without): $e');
    }

    // DNS Configuration - Fetch system DNS dynamically
    List<String> systemDnsServers = [];
    try {
      systemDnsServers = await _v2rayPlugin.getSystemDns();
      _logger.info('Device DNS servers: $systemDnsServers');
    } catch (e) {
      _logger.warning('Failed to fetch system DNS, will use fallback: $e');
    }

    // Resolve Server IP for bypass rule and outbound
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
    // Covers both connection shapes used by V2Ray outbounds:
    //   - vmess/vless: settings.vnext[0].address
    //   - trojan/shadowsocks: settings.servers[0].address
    if (fullConfig['outbounds'] != null && fullConfig['outbounds'].isNotEmpty) {
      for (var outbound in fullConfig['outbounds']) {
        if (outbound['tag'] == 'proxy' && outbound['settings'] != null) {
          final settings = outbound['settings'];
          if (settings['vnext'] != null && (settings['vnext'] as List).isNotEmpty) {
            settings['vnext'][0]['address'] = resolvedIp;
            _logger.info('Updated outbound address to resolved IP: $resolvedIp');
          } else if (settings['servers'] != null && (settings['servers'] as List).isNotEmpty) {
            settings['servers'][0]['address'] = resolvedIp;
            _logger.info('Updated outbound address to resolved IP: $resolvedIp');
          }
        }
      }
    }

    // Prioritize Custom DNS if available
    final List<String> effectiveDns = [];
    if (customDns != null && customDns.isNotEmpty) {
      effectiveDns.addAll(customDns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty));
      _logger.info('Using Custom DNS: $effectiveDns');
    }

    // If no custom DNS, or if we want to append system DNS as fallback (optional strategy)
    // For privacy/leak protection, usually we prefer Custom DNS ONLY if specified.
    if (effectiveDns.isEmpty) {
      if (systemDnsServers.isNotEmpty) {
        effectiveDns.addAll(systemDnsServers);
      } else {
        effectiveDns.addAll(["8.8.8.8", "1.1.1.1"]);
      }
      _logger.info('Using System/Default DNS: $effectiveDns');
    }

    fullConfig['dns'] = {
      "servers": [...effectiveDns, "localhost"], // localhost is needed for internal routing sometimes
      "queryStrategy": "UseIP",
    };

    // Routing Strategy - Robust rules
    fullConfig['routing'] = {
      "domainStrategy": "IPIfNonMatch",
      "rules": [
        // Rule 1: Hijack all DNS traffic to dns-out (CRITICAL)
        {"type": "field", "port": 53, "outboundTag": "dns-out"},
        // Rule 2: Bypass server address to prevent absolute deadlock
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

    return json.encode(fullConfig);
  }

  Future<bool> _runConnectLogicInternal(V2RayServer server, String? customDns, bool proxyOnly, bool useSystemDns) async {
    // Step 1: Force reset existing connections
    _logger.info('Ensuring previous connections are closed...');
    try {
      // Unconditionally disconnect to ensure clean state. This is an
      // internal/defensive disconnect, not a user action, so it must NOT
      // be treated as "the user wants to stay disconnected" — otherwise
      // every connect() call would immediately disarm auto-reconnect for
      // the connection it's about to establish.
      await disconnect(userInitiated: false);
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      _logger.warning('Reset warning (non-fatal): $e');
      // Continue anyway as we want to try connecting
    }

    // Step 2: Update status to connecting
    _logger.info('Step 1/7: Updating status to CONNECTING');
    _currentServer = server;
    _lastError = null;
    _safeEmit(VPNConnectionStatus.connecting);

    // Step 3: Check VPN permission for VPN mode
    if (!proxyOnly) {
      _logger.info('Step 2/7: Checking VPN permission...');
      try {
        final hasPermission = await _v2rayPlugin.requestPermission();
        _logger.info('VPN Permission granted: $hasPermission');

        if (!hasPermission) {
          throw Exception('VPN permission denied by user. Cannot establish VPN connection.');
        }
      } catch (e, stackTrace) {
        _logger.error('VPN permission check failed: $e', stackTrace: stackTrace);
        throw Exception('VPN permission error: $e');
      }
    } else {
      _logger.info('Step 2/7: Skipping VPN permission (proxy-only mode)');
    }

    // Step 4: Generate V2Ray configuration (shared with getServerDelay(), so
    // both the real tunnel and the ping test always see the exact same
    // inbounds/outbounds/routing/Mux/DNS setup).
    _logger.info('Step 3/7: Generating V2Ray configuration...');

    String configJson;
    try {
      configJson = await _buildRunnableConfig(server, customDns: customDns);
      _logger.info('Config refined successfully - Length: ${configJson.length} bytes');
      _logger.logObject('V2Ray Final Config', json.decode(configJson));
    } catch (e, stackTrace) {
      _logger.error('Failed to generate config: $e', stackTrace: stackTrace);
      throw Exception('Config generation failed: $e');
    }

    _logger.info('Step 5/7: Starting V2Ray core...');
    final startTime = DateTime.now();

    try {
      await _v2rayPlugin
          .startV2Ray(
            remark: server.name,
            config: configJson,
            proxyOnly: proxyOnly,
            useSystemDns: useSystemDns,
            bypassSubnets: [],
            blockedApps: null,
          )
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              _logger.error('V2Ray startup timed out after 20 seconds');
              throw TimeoutException('V2Ray startup timeout - server may be unreachable');
            },
          );

      final startDuration = DateTime.now().difference(startTime);
      _logger.info('V2Ray core started successfully in ${startDuration.inMilliseconds}ms');
    } catch (e, stackTrace) {
      _logger.error('Failed to start V2Ray core: $e', stackTrace: stackTrace);
      throw Exception('V2Ray startup failed: $e');
    }

    // Step 7: Wait for core initialization and verify connection
    _logger.info('Step 6/7: Waiting for core initialization...');
    await Future.delayed(const Duration(milliseconds: 2000));

    // Verify connection status
    _logger.info('Step 7/7: Verifying V2Ray core is responsive...');

    // Verify core version (confirms V2Ray is responsive)
    try {
      final coreVersion = await _v2rayPlugin.getCoreVersion().timeout(const Duration(seconds: 3), onTimeout: () => '');

      if (coreVersion != null && coreVersion.isNotEmpty) {
        _logger.info('✓ V2Ray core is responsive. Version: $coreVersion');
      } else {
        _logger.warning('Could not verify core version, but continuing...');
      }
    } catch (e) {
      _logger.warning('Core verification failed (non-fatal): $e');
    }

    _logger.info('Connection verification complete');
    _logger.info('Note: Monitor app logs and test actual traffic to confirm routing.');

    // Update status to connected
    if (_status != VPNConnectionStatus.connected) {
      _logger.info('Updating status to CONNECTED');
      _safeEmit(VPNConnectionStatus.connected);
    }

    // A successful (re)connection means the auto-reconnect loop, if it
    // was running, has done its job.
    _cancelReconnect();

    _logger.info('========== Connection successful ==========');
    _logger.info('Server: ${server.name}');
    _logger.info('Mode: ${proxyOnly ? "Proxy (use localhost:10808)" : "VPN (system-wide)"}');

    if (proxyOnly) {
      _logger.info('Configure your apps to use:');
      _logger.info('  - SOCKS5: 127.0.0.1:10808');
      _logger.info('  - HTTP: 127.0.0.1:10809');
    }

    // On macOS, automatically enable system proxy based on selected mode
    if (Platform.isMacOS) {
      _logger.info('Enabling macOS system proxy (${_proxyMode.displayName} mode)...');
      await setSystemProxy(_proxyMode);
    }

    // POST-CONNECTION DIAGNOSTICS
    _logger.info('========== Post-Connection Diagnostics ==========');
    await _runPostConnectionDiagnostics();

    // Start polling for "per request" logs from the native log files
    _startLogPolling();

    return true;
  }

  // Disconnect from V2Ray server.
  //
  // [userInitiated] distinguishes a deliberate disconnect (user tapped
  // the button, switched servers from the UI, signed out, etc.) from an
  // internal/defensive one (the "clean slate" reset at the top of
  // connect(), or a reconnect cycle tearing down before redialing).
  // Only a user-initiated disconnect disarms auto-reconnect and clears
  // the "last server" the app will otherwise try to restore.
  Future<void> disconnect({bool userInitiated = true}) async {
    _logger.info('========== Starting disconnection process ==========');
    _logger.info('Disconnecting from: ${_currentServer?.name ?? "VPN"} (userInitiated: $userInitiated)');

    if (userInitiated) {
      _userInitiatedDisconnect = true;
      _cancelReconnect();
      _lastServer = null;
    }

    try {
      _safeEmit(VPNConnectionStatus.disconnecting);

      // Stop log polling
      _stopLogPolling();

      _logger.info('Stopping V2Ray core...');
      final stopTime = DateTime.now();

      try {
        await _v2rayPlugin.stopV2Ray().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            _logger.warning('Stop V2Ray timed out after 10 seconds');
            throw TimeoutException('Disconnect timeout');
          },
        );

        final stopDuration = DateTime.now().difference(stopTime);
        _logger.info('V2Ray core stopped in ${stopDuration.inMilliseconds}ms');
      } catch (e, stackTrace) {
        _logger.error('Failed to stop V2Ray cleanly: $e', stackTrace: stackTrace);
        // Continue to cleanup state even if stop failed
      }

      // On macOS, clear system proxy
      if (Platform.isMacOS) {
        await clearSystemProxy();
      }

      // Increased delay to allow network stack to fully reset
      await Future.delayed(const Duration(milliseconds: 800));

      _currentServer = null;
      _lastError = null;
      _safeEmit(VPNConnectionStatus.disconnected);

      _logger.info('========== Disconnection complete ==========');
    } catch (e, stackTrace) {
      _logger.error('========== Disconnection failed ==========');
      _logger.error('Error: $e', stackTrace: stackTrace);

      _lastError = 'Disconnect error: $e';
      _safeEmit(VPNConnectionStatus.error);

      // Force cleanup state anyway
      _currentServer = null;
    }
  }

  // Get connection status
  Future<bool> isConnected() async {
    // New package might not have getConnectedServerDelay, or it might be different
    // We rely on internal status for now
    return _status == VPNConnectionStatus.connected;
  }

  // Get server delay (ping).
  //
  // Uses the exact same config generation as connect() (inbounds, direct/
  // dns-out outbounds, routing rules, Mux, fragment) via
  // _buildRunnableConfig(), instead of the previous bare
  // server.toV2RayConfig() call. A bare config has no routing/outbound
  // rules for DNS or the bypass IP, so the native ping test could fail or
  // hang even when the real tunnel (built by connect()) works fine, and
  // vice versa — the two were effectively testing different things.
  Future<int?> getServerDelay(V2RayServer server, {String? customDns}) async {
    try {
      final configJson = await _buildRunnableConfig(server, customDns: customDns);

      return await _v2rayPlugin
          .getServerDelay(config: configJson, url: 'https://www.google.com/generate_204')
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              _logger.warning('getServerDelay timed out for ${server.name}');
              return -1;
            },
          );
    } catch (e) {
      _logger.warning('getServerDelay failed for ${server.name}: $e');
      return null;
    }
  }

  // macOS System Proxy Control
  Future<bool> setSystemProxy(ProxyMode mode) async {
    if (!Platform.isMacOS) {
      _logger.warning('System proxy control is only available on macOS');
      return false;
    }

    try {
      _logger.info('Enabling macOS system proxy (${mode.displayName} mode)...');

      // Call native method with proxy mode argument
      const platform = MethodChannel('v2ray_dan');
      final result = await platform.invokeMethod('setSystemProxy', {
        'proxyMode': mode.name,
      });

      if (result == true) {
        _logger.info('✓ System proxy enabled successfully');
      } else {
        _logger.warning('Failed to enable system proxy (may need admin permissions)');
      }
      return result == true;
    } catch (e) {
      _logger.error('Error enabling system proxy: $e');
      return false;
    }
  }

  Future<bool> clearSystemProxy() async {
    if (!Platform.isMacOS) {
      return false;
    }

    try {
      _logger.info('Disabling macOS system proxy...');
      final result = await _v2rayPlugin.clearSystemProxy();
      if (result) {
        _logger.info('✓ System proxy disabled successfully');
      } else {
        _logger.warning('Failed to disable system proxy');
      }
      return result;
    } catch (e) {
      _logger.error('Error disabling system proxy: $e');
      return false;
    }
  }

  // Parse vmess:// or vless:// link
  Future<V2RayServer?> parseVmessLink(String link) async {
    try {
      return V2RayServer.fromAnyLink(link);
    } catch (e) {
      _lastError = 'Failed to parse link: $e';
      return null;
    }
  }

  // Run post-connection diagnostics
  Future<void> _runPostConnectionDiagnostics() async {
    try {
      _logger.info('Running post-connection diagnostics...');

      // Wait a bit for V2Ray to stabilize
      await Future.delayed(const Duration(seconds: 2));

      // Diagnostic 1: Check V2Ray core logs
      _logger.info('Diagnostic 1/3: Fetching V2Ray core logs...');
      try {
        final coreLogs = await _v2rayPlugin.getLogs().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _logger.warning('getLogs() timed out during diagnostics');
            return <String>[];
          },
        );
        if (coreLogs != null && coreLogs.isNotEmpty) {
          _logger.info('V2Ray Core Logs (last ${coreLogs.length} entries):');
          // Log last 10 entries or all if less
          final logsToShow = coreLogs.length > 10 ? coreLogs.sublist(coreLogs.length - 10) : coreLogs;
          for (final log in logsToShow) {
            _logger.info('  [V2Ray Core] $log');
          }
        } else {
          _logger.warning('No V2Ray core logs available');
        }
      } catch (e) {
        _logger.warning('Failed to fetch V2Ray core logs: $e');
      }

      // Diagnostic 2: Verify core is responsive
      _logger.info('Diagnostic 2/3: Checking if V2Ray core is responsive...');
      try {
        final version = await _v2rayPlugin.getCoreVersion().timeout(const Duration(seconds: 3), onTimeout: () => '');
        if (version.isNotEmpty) {
          _logger.info('✓ V2Ray core is responsive - Version: $version');
        } else {
          _logger.warning('V2Ray core version check returned empty');
        }
      } catch (e) {
        _logger.error('V2Ray core responsiveness check failed: $e');
      }

      // Diagnostic 3: Log current connection state
      _logger.info('Diagnostic 3/3: Current connection state');
      _logger.info('  Status: $_status');
      _logger.info('  Server: ${_currentServer?.name}');
      _logger.info('  Address: ${_currentServer?.address}:${_currentServer?.port}');
      _logger.info('  Protocol: ${_currentServer?.protocol}');

      _logger.info('========== Diagnostics Complete ==========');
      _logger.info('');
      _logger.info('NEXT STEPS TO VERIFY CONNECTION:');
      _logger.info('1. Check the logs above for any [V2Ray Core] errors');
      _logger.info('2. Test actual traffic:');
      _logger.info('   - Open browser and visit https://ifconfig.me');
      _logger.info('   - Your IP should show VPN server location');
      _logger.info('3. If traffic still not routing, check:');
      _logger.info('   - Server configuration is correct');
      _logger.info('   - Server is actually reachable and working');
      _logger.info('   - No firewall blocking V2Ray');
    } catch (e, stackTrace) {
      _logger.error('Post-connection diagnostics failed: $e', stackTrace: stackTrace);
    }
  }

  // State management
  void _startLogPolling() {
    _logPollingTimer?.cancel();
    _logPollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_status != VPNConnectionStatus.connected) {
        timer.cancel();
        return;
      }

      try {
        final logs = await _v2rayPlugin.getLogs().timeout(
          const Duration(seconds: 3),
          onTimeout: () => <String>[],
        );
        if (logs.isNotEmpty) {
          for (var logMsg in logs) {
            // Only add if it looks like an actual V2Ray log and not one of our headers
            if (logMsg.contains('access:') || logMsg.contains('error:')) {
              _logger.info('[V2Ray Core] $logMsg');
            }
          }
        }
      } catch (e) {
        // Silent error for polling
      }
    });
  }

  void _stopLogPolling() {
    _logPollingTimer?.cancel();
    _logPollingTimer = null;
  }

  // Dispose resources.
  //
  // WARNING: This service is a singleton. Do NOT call dispose() from a
  // page/widget's State.dispose() — that ties the singleton's lifetime
  // to one screen and will cause "Bad state: Cannot add new events after
  // calling close()" the next time the service is reused (e.g. in a
  // second widget test, or if the user navigates back to a screen that
  // re-touches the service). Only call this at true app shutdown, if at
  // all. Safe to call more than once — subsequent calls are no-ops.
  bool _isDisposed = false;
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _stopLogPolling();
    _cancelReconnect();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }
}
