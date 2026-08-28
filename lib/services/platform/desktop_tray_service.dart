import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/update/update_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_tray_io.dart' if (dart.library.html) 'desktop_tray_web.dart'
    as platform;

/// Windows system-tray icon with Open / Pause·Resume / Settings / Quit.
///
/// No-op on Android and non-Windows desktops. Preference for "close → tray"
/// is machine-local (not profile-synced).
class DesktopTrayService {
  DesktopTrayService._();

  static final DesktopTrayService instance = DesktopTrayService._();

  static const closeToTrayPrefsKey = 'desktop_close_to_tray';

  /// Default off — closing the window quits unless the user opts into tray.
  static const _defaultCloseToTray = false;

  static const _iconAssetStable = 'assets/branding/javp_tray.ico';
  static const _iconAssetDev = 'assets/branding/javp_tray_dev.ico';

  /// Tray icon matching the baked update channel (Dev vs Stable branding).
  static String get trayIconAsset =>
      UpdateChannel.current.isDev ? _iconAssetDev : _iconAssetStable;

  bool _started = false;
  bool _disposed = false;
  bool _closeToTray = _defaultCloseToTray;
  bool _quitting = false;

  PlaybackProvider? _playback;
  VoidCallback? _onOpenSettings;
  Future<void> Function()? _onBeforeQuit;

  String _labelOpen = 'Open';
  String _labelPause = 'Pause';
  String _labelResume = 'Resume';
  String _labelSettings = 'Settings';
  String _labelQuit = 'Quit';

  /// Last applied Pause·Resume / disabled state — skip redundant rebuilds.
  bool? _menuHasSession;
  bool? _menuPlaying;
  String? _menuLabelsKey;

  /// Bumps on each rebuild request so stale async [setContextMenu] calls drop.
  int _menuRebuildGen = 0;

  bool get isSupported => isWindowsDesktop;

  bool get closeToTray => _closeToTray;

  /// True while [quitApp] is tearing down — lets [dispose] skip duplicate work.
  bool get isQuitting => _quitting;

  /// Load prefs, show the tray icon, and intercept the window close button.
  Future<void> start({
    required VoidCallback onOpenSettings,
    Future<void> Function()? onBeforeQuit,
  }) async {
    if (_started || _disposed || !isSupported) return;
    _started = true;
    _onOpenSettings = onOpenSettings;
    _onBeforeQuit = onBeforeQuit;

    await _restoreCloseToTray();
    try {
      await platform.initTray(
        iconAsset: trayIconAsset,
        tooltip: UpdateChannel.current.isDev ? 'JAVP Dev' : 'JAVP',
        onWindowClose: _handleWindowClose,
        onTrayIconClick: showApp,
        onTrayIconRightClick: () => platform.popUpContextMenu(),
        onMenuItemClick: _onMenuItemClick,
      );
      await _rebuildMenu(force: true);
    } catch (e, st) {
      JavpLog.e('tray', 'Failed to start system tray: $e', stack: st);
    }
  }

  void bindPlayback(PlaybackProvider? playback) {
    if (identical(_playback, playback)) return;
    _playback?.removeListener(_onPlaybackChanged);
    _playback = playback;
    playback?.addListener(_onPlaybackChanged);
    unawaited(_rebuildMenu(force: true));
  }

  /// Refresh menu labels after a locale change (or first frame with l10n).
  Future<void> setLabels({
    required String open,
    required String pause,
    required String resume,
    required String settings,
    required String quit,
  }) async {
    _labelOpen = open;
    _labelPause = pause;
    _labelResume = resume;
    _labelSettings = settings;
    _labelQuit = quit;
    await _rebuildMenu(force: true);
  }

  Future<void> setCloseToTray(bool enabled) async {
    _closeToTray = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(closeToTrayPrefsKey, enabled);
    // Always prevent the default close so we can honor Quit from the tray
    // and optionally hide instead.
    if (isSupported && _started) {
      try {
        await platform.setPreventClose(true);
      } catch (_) {}
    }
  }

  Future<void> showApp() async {
    if (!isSupported) return;
    try {
      JavpLog.noteDesktopEvent('tray-show');
      await platform.showWindow();
    } catch (e) {
      debugPrint('Tray show failed: $e');
    }
  }

  Future<void> quitApp() async {
    if (_quitting) return;
    _quitting = true;
    JavpLog.noteDesktopEvent('quit');
    // Stop media_kit before exit. PR #49 added this, but calling
    // windowManager.destroy() afterward still ran Flutter dispose(), which
    // raced a second engine/tray teardown and native-crashed on Windows.
    try {
      await _playback?.stop();
    } catch (_) {}
    try {
      await _onBeforeQuit?.call();
    } catch (_) {}
    _playback?.removeListener(_onPlaybackChanged);
    _playback = null;
    if (_started && isSupported) {
      try {
        platform.removeTrayListeners();
      } catch (_) {}
      try {
        await platform.destroyTray();
      } catch (_) {}
      try {
        await platform.setPreventClose(false);
      } catch (_) {}
    }
    try {
      await JavpLog.instance.flush();
    } catch (_) {}
    platform.exitApp(0);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playback?.removeListener(_onPlaybackChanged);
    _playback = null;
    _onOpenSettings = null;
    _onBeforeQuit = null;
    // quitApp already removed listeners and destroyed the tray icon.
    if (_quitting || !_started || !isSupported) return;
    platform.removeTrayListeners();
    try {
      await platform.destroyTray();
    } catch (_) {}
  }

  Future<void> _restoreCloseToTray() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _closeToTray = prefs.getBool(closeToTrayPrefsKey) ?? _defaultCloseToTray;
    } catch (_) {
      _closeToTray = _defaultCloseToTray;
    }
  }

  void _onPlaybackChanged() {
    final playback = _playback;
    final hasSession = playback?.hasSession ?? false;
    final playing = playback?.playing ?? false;
    // PlaybackProvider notifies on position / tracks / size / etc. Only the
    // Pause·Resume row cares — rebuilding the Windows menu on every tick
    // races concurrent setContextMenu calls and flickers Pause ↔ Resume.
    if (hasSession == _menuHasSession && playing == _menuPlaying) return;
    unawaited(_rebuildMenu());
  }

  String _labelsKey() =>
      '$_labelOpen\u0001$_labelPause\u0001$_labelResume\u0001$_labelSettings\u0001$_labelQuit';

  Future<void> _rebuildMenu({bool force = false}) async {
    if (!_started || _disposed || _quitting || !isSupported) return;
    final playback = _playback;
    final hasSession = playback?.hasSession ?? false;
    final playing = playback?.playing ?? false;
    final labelsKey = _labelsKey();
    if (!force &&
        hasSession == _menuHasSession &&
        playing == _menuPlaying &&
        labelsKey == _menuLabelsKey) {
      return;
    }

    final gen = ++_menuRebuildGen;
    final pauseResumeLabel = playing ? _labelPause : _labelResume;

    try {
      await platform.setTrayMenu([
        platform.TrayMenuItem(key: 'open', label: _labelOpen),
        platform.TrayMenuItem(
          key: 'pause_resume',
          label: pauseResumeLabel,
          disabled: !hasSession,
        ),
        platform.TrayMenuItem(key: 'settings', label: _labelSettings),
        platform.TrayMenuItem.separator(),
        platform.TrayMenuItem(key: 'quit', label: _labelQuit),
      ]);
    } catch (e) {
      debugPrint('Tray menu rebuild failed: $e');
      return;
    }
    // A newer rebuild started while we awaited — do not stamp stale state.
    if (gen != _menuRebuildGen || _disposed || _quitting) return;
    _menuHasSession = hasSession;
    _menuPlaying = playing;
    _menuLabelsKey = labelsKey;
  }

  Future<void> _togglePauseResume() async {
    final playback = _playback;
    if (playback == null || !playback.hasSession) return;
    await playback.togglePlayPause();
    // Menu refresh comes from [_onPlaybackChanged] when playing flips.
  }

  Future<void> _openSettings() async {
    await showApp();
    _onOpenSettings?.call();
  }

  void _onMenuItemClick(String key) {
    switch (key) {
      case 'open':
        unawaited(showApp());
        return;
      case 'pause_resume':
        unawaited(_togglePauseResume());
        return;
      case 'settings':
        unawaited(_openSettings());
        return;
      case 'quit':
        unawaited(quitApp());
        return;
    }
  }

  Future<void> _handleWindowClose() async {
    if (_quitting || _disposed) return;
    // Native close / Alt+F4 on the PiP bubble restores the main window
    // (Chrome PiP "back to tab"), it does not quit or hide to tray.
    final playback = _playback;
    if (playback != null &&
        playback.isInPip &&
        playback.pip.usesDesktopMiniWindow) {
      await playback.expand();
      return;
    }
    if (_closeToTray) {
      try {
        JavpLog.noteDesktopEvent('tray-hide');
        await platform.hideWindow();
      } catch (e) {
        debugPrint('Tray hide failed: $e');
      }
      return;
    }
    await quitApp();
  }
}
