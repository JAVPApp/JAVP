import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _StartC = Int32 Function(Pointer<Utf8> savePath, Pointer<Utf8> socks);
typedef _StartDart = int Function(Pointer<Utf8> savePath, Pointer<Utf8> socks);
typedef _SocksC = Int32 Function(Pointer<Utf8> socks);
typedef _SocksDart = int Function(Pointer<Utf8> socks);
typedef _VoidC = Void Function();
typedef _VoidDart = void Function();
typedef _IntC = Int32 Function();
typedef _IntDart = int Function();
typedef _ErrC = Pointer<Utf8> Function();
typedef _ErrDart = Pointer<Utf8> Function();

/// Thin FFI around `librqbit_engine`.
class RqbitNative {
  RqbitNative(DynamicLibrary lib)
      : _lib = lib,
        _start = lib.lookupFunction<_StartC, _StartDart>('rqbit_engine_start'),
        _stop = lib.lookupFunction<_VoidC, _VoidDart>('rqbit_engine_stop'),
        _port = lib.lookupFunction<_IntC, _IntDart>('rqbit_engine_port'),
        _setSocks = lib.lookupFunction<_SocksC, _SocksDart>(
          'rqbit_engine_set_socks_proxy',
        ),
        _lastError = lib.lookupFunction<_ErrC, _ErrDart>(
          'rqbit_engine_last_error',
        );

  // Retained so the process keeps the cdylib mapped.
  // ignore: unused_field
  final DynamicLibrary _lib;
  final _StartDart _start;
  final _VoidDart _stop;
  final _IntDart _port;
  final _SocksDart _setSocks;
  final _ErrDart _lastError;

  static RqbitNative load([String? libraryPath]) {
    return RqbitNative(
      libraryPath == null ? open() : DynamicLibrary.open(libraryPath),
    );
  }

  static DynamicLibrary open() {
    if (Platform.isWindows) {
      return DynamicLibrary.open('rqbit_engine.dll');
    }
    if (Platform.isMacOS) {
      return DynamicLibrary.open('librqbit_engine.dylib');
    }
    // Android + Linux
    return DynamicLibrary.open('librqbit_engine.so');
  }

  int start({required String savePath, String? socksUrl}) {
    final path = savePath.toNativeUtf8();
    final socks = socksUrl == null || socksUrl.isEmpty
        ? nullptr
        : socksUrl.toNativeUtf8();
    try {
      return _start(path, socks);
    } finally {
      malloc.free(path);
      if (socks != nullptr) malloc.free(socks);
    }
  }

  int setSocksProxy(String? socksUrl) {
    final socks = socksUrl == null || socksUrl.isEmpty
        ? nullptr
        : socksUrl.toNativeUtf8();
    try {
      return _setSocks(socks);
    } finally {
      if (socks != nullptr) malloc.free(socks);
    }
  }

  int port() => _port();

  void stop() => _stop();

  String? lastError() {
    final ptr = _lastError();
    if (ptr == nullptr) return null;
    return ptr.toDartString();
  }
}
