import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/diagnostics/hwnd_sync_trace.dart';
import 'package:javp/services/input/gamepad_service.dart';
import 'package:javp/services/platform/desktop_window_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:javp/compat/window_manager.dart';

/// True for Windows / Linux / macOS desktop shells.
bool get isDesktopPlatform => DesktopUi.enabled;

/// True when this build is the Windows desktop app.
bool get isWindowsDesktop {
  if (kIsWeb) return false;
  return Platform.isWindows;
}

const _minimumWindowSize = Size(960, 600);
const _defaultWindowSize = Size(1280, 720);

/// Initializes desktop-only plumbing before [runApp].
///
/// - SQLite via FFI (sqflite has no Windows/Linux plugin)
/// - [window_manager] for cinema fullscreen + desktop mini-player
/// - restores where the window was last left
Future<void> bootstrapDesktop() async {
  if (!isDesktopPlatform) return;

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  await windowManager.ensureInitialized();
  final saved = await _WindowGeometry.load();
  final options = WindowOptions(
    size: saved?.size ?? _defaultWindowSize,
    minimumSize: _minimumWindowSize,
    center: saved == null,
    backgroundColor: const Color(0xFF0B0C0F),
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
    title: 'JAVP',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    if (saved != null) {
      final position = saved.position;
      if (position != null) {
        await windowManager.setPosition(position);
      }
    }
    await windowManager.show();
    await windowManager.focus();
  });
  windowManager.addListener(_WindowGeometry.listener);
  DesktopWindowService.instance.registerWindowListener();
  // Maximize is PostMessage on Windows and races the first Flutter layout.
  // Doing it here (before runApp) left Overlay/MediaQuery at the restored
  // windowed size inside a maximized HWND — nested chrome after a force-quit.
  if (saved != null && saved.maximized) {
    _WindowGeometry.scheduleMaximizedRestore();
  }

  // Cheap when nothing is plugged in: XInput reports "not connected" and the
  // poller idles. Off Windows this is a no-op.
  GamepadService.instance.start();
}

/// Remembers window bounds between launches, the way a desktop app should.
class _WindowGeometry with WindowListener {
  _WindowGeometry._({
    required this.size,
    required this.position,
    required this.maximized,
  });

  static const _key = 'desktop_window_geometry';

  static final listener = _WindowGeometry._(
    size: _defaultWindowSize,
    position: null,
    maximized: false,
  );

  final Size size;
  final Offset? position;
  final bool maximized;

  Timer? _debounce;

  /// Apply the saved maximized flag after the first Flutter frame, then wait
  /// until Windows actually maximized so view metrics match the HWND.
  static void scheduleMaximizedRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreMaximized());
    });
  }

  static Future<void> _restoreMaximized() async {
    try {
      if (!await windowManager.isMaximized()) {
        await windowManager.maximize();
        for (var i = 0; i < 40; i++) {
          if (await windowManager.isMaximized()) break;
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }
      _nudgeViewToHwnd();
    } catch (e) {
      debugPrint('Window maximize restore failed: $e');
    }
  }

  /// Re-read embedder metrics so Overlay / MediaQuery pick up the HWND size
  /// after maximize (same class of stale-inset bug as the Android IME gap).
  static void _nudgeViewToHwnd() {
    WidgetsBinding.instance.handleMetricsChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.handleMetricsChanged();
    });
  }

  static Future<_WindowGeometry?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return null;
      final parts = raw.split(',');
      if (parts.length != 5) return null;
      final values = parts.take(4).map(double.tryParse).toList();
      if (values.any((v) => v == null || !v.isFinite)) return null;
      final width = values[2]!;
      final height = values[3]!;
      // A stored size below the minimum (or an absurd one) means the prefs are
      // stale or hand-edited; fall back to the default rather than fight it.
      if (width < _minimumWindowSize.width ||
          height < _minimumWindowSize.height ||
          width > 20000 ||
          height > 20000) {
        return null;
      }
      final x = values[0]!;
      final y = values[1]!;
      // Guard against a window restored onto a monitor that no longer exists.
      final onScreen = x > -2000 && y > -2000 && x < 20000 && y < 20000;
      return _WindowGeometry._(
        size: Size(width, height),
        position: onScreen ? Offset(x, y) : null,
        maximized: parts[4] == '1',
      );
    } catch (e) {
      debugPrint('Window geometry restore failed: $e');
      return null;
    }
  }

  @override
  void onWindowResized() {
    _scheduleSave();
    // Verbose-only + rate-limited inside JavpLog — resize storms are a common
    // desktop hitch source that never crossed the old 40ms jank line. Skip the
    // platform getSize() entirely when verbose hitch is off (Stable default).
    if (!JavpLog.instance.verboseHitch) return;
    unawaited(_logWindowSize('resize'));
  }

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowMaximize() {
    unawaited(_save());
    JavpLog.noteDesktopEvent('maximize');
    _nudgeViewToHwnd();
  }

  @override
  void onWindowUnmaximize() {
    unawaited(_save());
    JavpLog.noteDesktopEvent('unmaximize');
    _nudgeViewToHwnd();
  }

  @override
  void onWindowMinimize() => JavpLog.noteDesktopEvent('minimize');

  @override
  void onWindowRestore() {
    unawaited(_save());
    JavpLog.noteDesktopEvent('restore');
    // Minimize→restore hits the same stale-metrics race as maximize: the
    // Overlay/MediaQuery keep the minimized size inside a restored HWND, so
    // the window restores to a canvas that then ignores maximize. Re-read
    // embedder metrics on restore so the view tracks the HWND again.
    _nudgeViewToHwnd();
  }

  @override
  void onWindowFocus() {
    JavpLog.noteDesktopEvent('focus');
    HwndSyncTrace.noteDesktop('focus');
  }

  @override
  void onWindowBlur() {
    JavpLog.noteDesktopEvent('blur');
    HwndSyncTrace.noteDesktop('blur');
  }

  Future<void> _logWindowSize(String event) async {
    try {
      final size = await windowManager.getSize();
      JavpLog.noteDesktopEvent(
        event,
        detail: '${size.width.round()}x${size.height.round()}',
      );
    } catch (_) {
      JavpLog.noteDesktopEvent(event);
    }
  }

  /// Drags fire these callbacks continuously; only the resting place matters.
  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
      final maximized = await windowManager.isMaximized();
      // Maximized bounds would be restored as a full-screen "windowed" size,
      // so keep the last floating bounds and the flag separately.
      if (maximized) {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_key);
        final previous = raw?.split(',') ?? const <String>[];
        if (previous.length == 5) {
          await prefs.setString(_key, [...previous.take(4), '1'].join(','));
          return;
        }
      }
      final bounds = await windowManager.getBounds();
      // Mini-player / PiP sizes are below the normal minimum — don't persist
      // them as the next-launch geometry.
      if (bounds.width + 0.5 < _minimumWindowSize.width ||
          bounds.height + 0.5 < _minimumWindowSize.height) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        [
          bounds.left,
          bounds.top,
          bounds.width,
          bounds.height,
          maximized ? '1' : '0',
        ].join(','),
      );
    } catch (e) {
      debugPrint('Window geometry save failed: $e');
    }
  }
}
