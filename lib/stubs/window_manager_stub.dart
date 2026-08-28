/// Web stub for window_manager — no-op implementations.
library window_manager_stub;

import 'dart:async';

import 'package:flutter/painting.dart';

final WindowManager windowManager = WindowManager._();

class WindowManager {
  WindowManager._();

  final List<WindowListener> _listeners = [];

  Future<void> ensureInitialized() async {}
  Future<void> waitUntilReadyToShow(
    WindowOptions options,
    Future<void> Function()? callback,
  ) async {
    await callback?.call();
  }

  Future<void> show() async {}
  Future<void> hide() async {}
  Future<void> focus() async {}
  Future<void> close() async {}
  Future<void> destroy() async {}
  Future<void> restore() async {}
  Future<void> maximize() async {}
  Future<void> unmaximize() async {}

  Future<bool> isMaximized() async => false;
  Future<bool> isMinimized() async => false;
  Future<bool> isVisible() async => true;
  Future<bool> isFocused() async => true;

  Future<void> setTitle(String title) async {}
  Future<void> setTitleBarStyle(
    TitleBarStyle titleBarStyle, {
    bool windowButtonVisibility = true,
  }) async {}
  Future<void> setPosition(Offset position) async {}
  Future<Offset> getPosition() async => Offset.zero;
  Future<void> setSize(Size size) async {}
  Future<Size> getSize() async => const Size(1280, 720);
  Future<Rect> getBounds() async => const Rect.fromLTWH(0, 0, 1280, 720);

  Future<void> setMinimumSize(Size size) async {}
  Future<void> setMaximumSize(Size size) async {}
  Future<void> setAspectRatio(double aspectRatio) async {}
  Future<void> setAlignment(Alignment alignment, {bool animate = false}) async {}
  Future<void> startDragging() async {}

  Future<void> setPreventClose(bool prevent) async {}
  Future<void> setSkipTaskbar(bool skip) async {}

  Future<void> setFullScreen(bool fullScreen) async {}
  Future<bool> isFullScreen() async => false;
  Future<void> setAlwaysOnTop(bool alwaysOnTop) async {}
  Future<void> setResizable(bool resizable) async {}
  Future<void> setHasShadow(bool hasShadow) async {}

  void addListener(WindowListener listener) {
    _listeners.add(listener);
  }

  void removeListener(WindowListener listener) {
    _listeners.remove(listener);
  }
}

class WindowOptions {
  const WindowOptions({
    this.size,
    this.center,
    this.minimumSize,
    this.maximumSize,
    this.alwaysOnTop,
    this.fullScreen,
    this.backgroundColor,
    this.skipTaskbar,
    this.title,
    this.titleBarStyle,
    this.windowButtonVisibility,
  });

  final Size? size;
  final bool? center;
  final Size? minimumSize;
  final Size? maximumSize;
  final bool? alwaysOnTop;
  final bool? fullScreen;
  final Color? backgroundColor;
  final bool? skipTaskbar;
  final String? title;
  final TitleBarStyle? titleBarStyle;
  final bool? windowButtonVisibility;
}

enum TitleBarStyle { normal, hidden, hiddenInset }

mixin WindowListener {
  void onWindowClose() {}
  void onWindowFocus() {}
  void onWindowBlur() {}
  void onWindowMaximize() {}
  void onWindowUnmaximize() {}
  void onWindowMinimize() {}
  void onWindowRestore() {}
  void onWindowResize() {}
  void onWindowResized() {}
  void onWindowMove() {}
  void onWindowMoved() {}
  void onWindowEnterFullScreen() {}
  void onWindowLeaveFullScreen() {}
  void onWindowEvent(String eventName) {}
}
