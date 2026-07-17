import 'dart:async';
import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'services/v2ray_service.dart';
import 'services/logger_service.dart';

// Global V2Ray service instance for cleanup on crash.
//
// IMPORTANT: This is a process-lifetime singleton. Its StreamController
// (statusStream) must stay open for as long as the app process is
// alive. NEVER call _globalV2RayService.dispose() from a widget's
// State.dispose() — widget disposal happens far more often than "the
// app is truly done" (e.g. every widget test teardown calls it), and
// once the controller is closed it can never be reopened. A closed
// controller means every subsequent connect()/disconnect() call from
// anywhere in the app (or from the next widget test in the same file)
// throws "Bad state: Cannot add new events after calling close()".
//
// disconnect() alone is safe to call as often as needed — it only
// tears down the VPN connection, it does not touch the stream.
final V2RayService _globalV2RayService = V2RayService();
final LoggerService _logger = LoggerService();

void main() {
  // Catch async errors
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Setup error handling
      FlutterError.onError = (FlutterErrorDetails details) {
        _logger.error('Flutter Error: ${details.exception}', stackTrace: details.stack);
        _disconnectOnCrash();
        FlutterError.presentError(details);
      };
      runApp(const V2RayApp());
    },
    (error, stackTrace) {
      try {
        _logger.error('Uncaught error: $error', stackTrace: stackTrace);
      } catch (e) {
        debugPrint('Uncaught error (Logger not ready): $error');
      }
      _disconnectOnCrash();
    },
  );
}

// Emergency VPN disconnect on crash
void _disconnectOnCrash() {
  try {
    _logger.warning('!!! CRASH DETECTED - Disconnecting VPN for safety !!!');
    // Use unawaited to not block crash handling
    _globalV2RayService.disconnect().whenComplete(() {
      _logger.info('VPN disconnected after crash');
    });
  } catch (e) {
    _logger.error('Failed to disconnect VPN on crash: $e');
  }
}

class V2RayApp extends StatefulWidget {
  const V2RayApp({super.key});
  @override
  State<V2RayApp> createState() => _V2RayAppState();
}

class _V2RayAppState extends State<V2RayApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Disconnect VPN when this widget tree is torn down (app closing,
    // hot restart, or a widget test's teardown).
    //
    // Deliberately NOT calling _globalV2RayService.dispose() here.
    // The service is a process-wide singleton and must remain usable
    // for the rest of the app's/isolate's life — including further
    // widget tests in the same test file, which each tear down and
    // rebuild V2RayApp. Closing its stream here would permanently
    // break every connect()/disconnect() call that happens afterwards.
    _logger.info('App disposing - disconnecting VPN');
    _globalV2RayService.disconnect();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _logger.info('App lifecycle state changed: $state');
    // Optional: Disconnect when app is detached (being closed by system)
    if (state == AppLifecycleState.detached) {
      _logger.info('App detached - disconnecting VPN');
      _globalV2RayService.disconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Flaming Cherubim', theme: AppTheme.darkTheme, debugShowCheckedModeBanner: false, home: const HomeScreen());
  }
}
