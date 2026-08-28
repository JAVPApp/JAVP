import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/compat/window_manager.dart';

/// Desktop window helpers — cinema fullscreen and a PiP-like mini window.
class DesktopWindowService with WindowListener {
  DesktopWindowService._();
  static final DesktopWindowService instance = DesktopWindowService._();

  static const _pipWidth = 400.0;
  static const _pipMargin = 24.0;
  static const _pipMinSize = Size(240, 135);
  static const _normalMinSize = Size(960, 600);

  bool _mini = false;
  bool _cinemaFullscreen = false;
  Size? _restoreSize;
  Offset? _restorePosition;
  bool _restoreMaximized = false;
  bool _restoreFullscreen = false;

  bool get isMiniPlayer => _mini;

  /// Register once from [bootstrapDesktop] so OS fullscreen toggles hide the
  /// title bar too (Windows keeps the custom chrome visible otherwise).
  void registerWindowListener() {
    windowManager.addListener(this);
  }

  @override
  void onWindowEnterFullScreen() {
    unawaited(_onNativeFullscreenChanged(true));
  }

  @override
  void onWindowLeaveFullScreen() {
    unawaited(_onNativeFullscreenChanged(false));
  }

  Future<void> _onNativeFullscreenChanged(bool entered) async {
    if (!isDesktopPlatform || _mini) return;
    try {
      if (entered) {
        await _setTitleBarVisible(false);
      } else if (!_cinemaFullscreen) {
        await _setTitleBarVisible(true);
      }
    } catch (e) {
      debugPrint('Desktop native fullscreen chrome failed: $e');
    }
  }

  Future<void> _setTitleBarVisible(bool visible) async {
    if (_mini) return;
    await windowManager.setTitleBarStyle(
      visible ? TitleBarStyle.normal : TitleBarStyle.hidden,
      windowButtonVisibility: visible,
    );
  }

  Future<void> setCinemaFullscreen(bool enabled) async {
    if (!isDesktopPlatform) return;
    try {
      if (enabled) {
        if (_mini) await exitMiniPlayer();
        _cinemaFullscreen = true;
        await _setTitleBarVisible(false);
        await windowManager.setFullScreen(true);
        JavpLog.noteDesktopEvent('fullscreen');
      } else {
        _cinemaFullscreen = false;
        if (await windowManager.isFullScreen()) {
          await windowManager.setFullScreen(false);
        }
        await _setTitleBarVisible(true);
        JavpLog.noteDesktopEvent('windowed');
      }
    } catch (e) {
      debugPrint('Desktop fullscreen failed: $e');
    }
  }

  /// Compact always-on-top video window — desktop stand-in for Chrome / Android PiP.
  Future<bool> enterMiniPlayer({
    double aspectX = 16,
    double aspectY = 9,
  }) async {
    if (!isDesktopPlatform) return false;
    try {
      _restoreFullscreen = await windowManager.isFullScreen();
      if (_restoreFullscreen) {
        await windowManager.setFullScreen(false);
      }
      _restoreMaximized = await windowManager.isMaximized();
      if (_restoreMaximized) {
        await windowManager.unmaximize();
      }
      _restoreSize = await windowManager.getSize();
      _restorePosition = await windowManager.getPosition();

      final ratio = aspectX <= 0 || aspectY <= 0 ? 16 / 9 : aspectX / aspectY;
      final width = _pipWidth;
      final height = (width / ratio).clamp(135.0, 320.0);
      await windowManager.setAlwaysOnTop(true);
      try {
        await windowManager.setHasShadow(true);
      } catch (_) {}
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(_pipMinSize);
      await windowManager.setAspectRatio(ratio);
      await windowManager.setSize(Size(width, height));
      await _parkBottomRight();
      _nudgeViewToHwnd();
      _mini = true;
      JavpLog.noteDesktopEvent('mini-player');
      return true;
    } catch (e) {
      debugPrint('Desktop mini-player failed: $e');
      return false;
    }
  }

  Future<void> exitMiniPlayer() async {
    if (!isDesktopPlatform || !_mini) return;
    try {
      await windowManager.setAspectRatio(0);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );
      await windowManager.setMinimumSize(_normalMinSize);
      if (_restoreFullscreen) {
        await windowManager.setFullScreen(true);
      } else if (_restoreMaximized) {
        await windowManager.maximize();
      } else {
        if (_restoreSize != null) {
          await windowManager.setSize(_restoreSize!);
        }
        if (_restorePosition != null) {
          await windowManager.setPosition(_restorePosition!);
        }
      }
      _nudgeViewToHwnd();
    } catch (e) {
      debugPrint('Desktop mini-player restore failed: $e');
    } finally {
      _mini = false;
      _restoreSize = null;
      _restorePosition = null;
      _restoreMaximized = false;
      _restoreFullscreen = false;
    }
  }

  Future<void> _parkBottomRight() async {
    try {
      await windowManager.setAlignment(Alignment.bottomRight);
      final pos = await windowManager.getPosition();
      await windowManager.setPosition(
        Offset(pos.dx - _pipMargin, pos.dy - _pipMargin),
      );
    } catch (e) {
      debugPrint('Desktop mini-player position failed: $e');
    }
  }

  void _nudgeViewToHwnd() {
    WidgetsBinding.instance.handleMetricsChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.handleMetricsChanged();
    });
  }
}
