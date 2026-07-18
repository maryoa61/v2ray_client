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
  ProxyMode _proxyMode = ProxyMode.socks;

  V2RayServer? _lastServer;
  String? _lastCustomDns;
  bool _lastProxyOnly = false;
  bool _lastUseSystemDns = true;
  ProxyMode? _lastProxyMode;

  bool _userInitiatedDisconnect = true;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  ConnectivityResult? _lastConnectivityResult;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _isReconnecting = false;

  bool _autoReconnectEnabled = true;
  int _maxReconnectAttempts = 6;

  static const List<int> _backoffSeconds =;

  bool get autoReconnectEnabled => _autoReconnectEnabled;
  int get maxReconnectAttempts => _maxReconnectAttempts;

  VPNConnectionStatus get status => _status;
  V2RayServer? get currentServer => _currentServer;
  String? get lastError => _lastError;
  bool get isReconnecting => _isReconnecting;

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

  void _safeEmit(VPNConnectionStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    } else {
      _logger.warning('Attempted to emit status "$status" after V2RayService was disposed (ignored).');
    }
  }

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

  void _setupAndroidLogReceiver() {
    try {
      const platform = MethodChannel('com.flaming.cherubim/logs');
      platform.setMethodCallHandler((call) async {
        if (call.method == 'log') {
          final level = call.arguments['level'] as String?;
          final message = call.arguments['message'] as String?;

          if (message != null) {
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

  void _startConnectivityMonitoring() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
      final previous = _lastConnectivityResult;
      _lastConnectivityResult = result;

      if (previous == null) return;
      if (previous == result) return;

      _logger.info('Connectivity changed: $previous -> $result');
      if (result == ConnectivityResult.none) return;
      
      if (_status == VPNConnectionStatus.connected && !_userInitiatedDisconnect) {
         _logger.info('Network switched while connected. Reconnecting...');
         _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
     if (!_autoReconnectEnabled || _isReconnecting) return;
     _isReconnecting = true;
     _reconnectAttempts = 0;
     _reconnectLoop();
  }

  void _reconnectLoop() {
     if (_reconnectAttempts >= _maxReconnectAttempts) {
        _logger.error('Max auto-reconnect attempts reached. Stopping.');
        _isReconnecting = false;
        return;
     }
     final delay = _backoffSeconds[min(_reconnectAttempts, _backoffSeconds.length - 1)];
     _reconnectAttempts++;
     _reconnectTimer = Timer(Duration(seconds: delay), () async {
         if (_lastServer != null) {
            _logger.info('Auto-reconnect attempt #$_reconnectAttempts...');
            final success = await connect(
               _lastServer!,
               customDns: _lastCustomDns,
               proxyOnly: _lastProxyOnly,
               useSystemDns: _lastUseSystemDns,
               proxyMode: _lastProxyMode,
            );
            if (success) {
               _isReconnecting = false;
               _logger.info('✓ Auto-reconnect successful!');
            } else {
               _reconnectLoop();
            }
         }
     });
  }

  VPNConnectionStatus _mapPluginStatus(String state) {
    switch (state.toLowerCase()) {
      case 'connected': return VPNConnectionStatus.connected;
      case 'connecting': return VPNConnectionStatus.connecting;
      case 'disconnecting': return VPNConnectionStatus.disconnecting;
      case 'disconnected': return VPNConnectionStatus.disconnected;
      case 'error': return VPNConnectionStatus.error;
      default: return VPNConnectionStatus.disconnected;
    }
  }

  Future<void> init() async {
    if (_isInitialized) {
      _logger.info('V2Ray core already initialized, skipping...');
      return;
    }
    try {
      _logger.info('========== Initializing V2Ray Core ==========');
      _filesDir = await _v2rayPlugin
          .initialize(notificationIconResourceType: 'drawable', notificationIconResourceName: 'ic_stat_v2ray')
          .timeout(const Duration(seconds: 10));
      
      final version = await _v2rayPlugin.getCoreVersion().timeout(const Duration(seconds: 3), onTimeout: () => '');
      if (version != null && version.isNotEmpty) {
        _logger.info('✓ V2Ray core version: $version');
      }
      _isInitialized = true;
    } catch (e, stackTrace) {
      _lastError = 'Failed to initialize V2Ray: $e';
      _logger.error(_lastError!, stackTrace: stackTrace);
      _safeEmit(VPNConnectionStatus.error);
      rethrow;
    }
  }

  Future<bool> checkPermission() async {
    try {
      return await _v2rayPlugin.requestPermission().timeout(const Duration(seconds: 30));
    } catch (e) {
      return false;
    }
  }

  Future<void> stop() async {
    _userInitiatedDisconnect = true;
    _reconnectTimer?.cancel();
    _isReconnecting = false;
    _safeEmit(VPNConnectionStatus.disconnecting);
    await _v2rayPlugin.stopV2Ray();
    _safeEmit(VPNConnectionStatus.disconnected);
  }

  Future<bool> connect(
    V2RayServer server, {
    String? customDns,
    bool proxyOnly = false,
    bool useSystemDns = true,
    ProxyMode? proxyMode,
  }) async {
    if (_isConnectInProgress) return false;
    _isConnectInProgress = true;
    _userInitiatedDisconnect = false;

    _lastServer = server;
    _lastCustomDns = customDns;
    _lastProxyOnly = proxyOnly;
    _lastUseSystemDns = useSystemDns;
    _lastProxyMode = proxyMode;

    try {
      _safeEmit(VPNConnectionStatus.connecting);
      
      Map<String, dynamic> fullConfig = jsonDecode(server.configJson);

      if (fullConfig.containsKey('outbounds')) {
        List<dynamic> outbounds = fullConfig['outbounds'];
        
        final proxyOutbound = outbounds.firstWhere(
          (element) => element is Map && element['tag'] == 'proxy',
          orElse: () => <String, dynamic>{},
        );

        if (proxyOutbound.isNotEmpty) {
          proxyOutbound['mux'] = {
            'enabled': true,
            'concurrency': 8,
          };
          _logger.info('✓ Successfully injected Mux settings into proxy outbound.');
        }
      }

      String finalizedJsonString = jsonEncode(fullConfig);

      final isStarted = await _v2rayPlugin.startV2Ray(
        remark: server.name,
        config: finalizedJsonString,
        proxyOnly: proxyOnly,
      );

      _isConnectInProgress = false;
      if (isStarted) {
        _currentServer = server;
        _safeEmit(VPNConnectionStatus.connected);
        return true;
      } else {
        _safeEmit(VPNConnectionStatus.error);
        return false;
      }
    } catch (e, stackTrace) {
      _isConnectInProgress = false;
      _logger.error('Connect method caught an execution error: $e', stackTrace: stackTrace);
      _safeEmit(VPNConnectionStatus.error);
      return false;
    }
  }
}
