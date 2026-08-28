import 'client.dart';
import 'native.dart';

/// Process-wide librqbit session (one HTTP API on loopback).
class RqbitEngine {
  RqbitEngine._(this._native, this.client);

  static RqbitEngine? _instance;
  static RqbitNative Function()? openNative;

  final RqbitNative _native;
  final RqbitClient client;

  static RqbitEngine? get instance => _instance;

  static RqbitClient? get http => _instance?.client;

  /// Load the cdylib and start the HTTP API. Reuses a live session when the
  /// save path and SOCKS URL match.
  static Future<RqbitEngine> start({
    required String savePath,
    String? socksProxyUrl,
    RqbitNative? native,
  }) async {
    final existing = _instance;
    if (existing != null) {
      final port = existing._native.start(
        savePath: savePath,
        socksUrl: socksProxyUrl,
      );
      if (port > 0) {
        existing.client.baseUrl = 'http://127.0.0.1:$port';
        return existing;
      }
      throw StateError(
        existing._native.lastError() ?? 'rqbit_engine_start failed',
      );
    }

    final n = native ?? openNative?.call() ?? RqbitNative.load();
    final port = n.start(savePath: savePath, socksUrl: socksProxyUrl);
    if (port <= 0) {
      throw StateError(n.lastError() ?? 'rqbit_engine_start failed');
    }
    final engine = RqbitEngine._(
      n,
      RqbitClient(baseUrl: 'http://127.0.0.1:$port'),
    );
    _instance = engine;
    return engine;
  }

  /// Push a new SOCKS URL (null disables). Restarts the session when needed.
  bool setSocksProxy(String? socksUrl) {
    final port = _native.setSocksProxy(socksUrl);
    if (port <= 0) return false;
    client.baseUrl = 'http://127.0.0.1:$port';
    return true;
  }

  void stop() {
    _native.stop();
    client.close();
    if (identical(_instance, this)) _instance = null;
  }

  static void resetForTest() {
    _instance?.stop();
    _instance = null;
  }
}
