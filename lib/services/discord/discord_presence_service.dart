import 'dart:async';

import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/discord/discord_presence_artwork.dart';
import 'package:javp/services/discord/discord_presence_copy.dart';
import 'package:javp/services/discord/discord_presence_mapper.dart';
import 'package:javp/services/ui/persist_after_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'discord_presence_io.dart' if (dart.library.html) 'discord_presence_web.dart'
    as platform;

/// Desktop Discord Rich Presence via local IPC.
///
/// No-op on mobile / web / when Discord is not running. Preference is
/// machine-local (not profile-synced). Status lines follow the user's UI
/// language via [bindLocale].
class DiscordPresenceService {
  DiscordPresenceService._();

  static final DiscordPresenceService instance = DiscordPresenceService._();

  /// Discord Application ID (Developer Portal → General Information).
  /// Override with `--dart-define=DISCORD_CLIENT_ID=…`.
  static const clientId = String.fromEnvironment(
    'DISCORD_CLIENT_ID',
    defaultValue: '1536396307826999326',
  );

  static const prefsKey = 'discord_rich_presence_enabled';
  static const hideTitlePrefsKey = 'discord_rich_presence_hide_title';

  static const _websiteUrl = 'https://javp.app';
  static const _discordInviteUrl = 'https://discord.gg/deEVVzzaE4';
  static const _assetKey = DiscordPresenceArtwork.portalAssetKey;

  static const _heartbeat = Duration(seconds: 15);
  static const _reconnectBase = Duration(seconds: 5);
  static const _reconnectMax = Duration(minutes: 2);

  /// Discord throttles SET_ACTIVITY (~5 per 20s); coalesce bursts from rapid
  /// play/pause or scrubbing into a single trailing update.
  static const _minPushInterval = Duration(seconds: 4);

  platform.DiscordRPCHandle? _rpc;
  bool _started = false;
  bool _disposed = false;
  bool _enabled = true;
  bool _hideTitle = false;
  bool _connecting = false;
  bool _loggedMissingClient = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _pendingPushTimer;
  DateTime? _lastPushAt;
  DiscordPresenceSnapshot? _pendingSnapshot;
  DiscordPresenceSnapshot? _lastSent;
  PlaybackProvider? _playback;
  String? _sessionKey;
  DateTime? _sessionStartedAt;
  LocaleController? _locale;
  DiscordPresenceCopy _copy = DiscordPresenceCopy.english;
  String? _copyLanguageCode;

  bool get enabled => _enabled;

  /// Privacy toggle: keep showing JAVP activity, hide what is playing.
  bool get hideTitle => _hideTitle;

  bool get isSupported =>
      isDesktopPlatform && platform.isDiscordAvailable && clientId.isNotEmpty;

  /// Follow [locale] so presence status lines match the app UI language.
  void bindLocale(LocaleController locale) {
    if (identical(_locale, locale)) return;
    _locale?.removeListener(_onLocaleChanged);
    _locale = locale;
    locale.addListener(_onLocaleChanged);
    _refreshCopy(forcePush: false);
  }

  void _onLocaleChanged() => _refreshCopy(forcePush: true);

  void _refreshCopy({required bool forcePush}) {
    final code = _locale?.effectiveLanguageCode ?? 'en';
    if (!forcePush && code == _copyLanguageCode) return;
    _copyLanguageCode = code;
    _copy = DiscordPresenceCopy.forLanguageCode(code);
    if (!forcePush || _disposed || !_started || !_enabled) return;
    final playback = _playback;
    if (playback != null) {
      unawaited(_push(_snapshot(playback), force: true));
    } else {
      unawaited(_push(DiscordPresenceSnapshot.browsing(_copy), force: true));
    }
  }

  /// Load prefs, connect when possible, and push an initial presence.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    if (!isDesktopPlatform || !platform.isDiscordAvailable) {
      return;
    }
    if (clientId.isEmpty) {
      if (!_loggedMissingClient) {
        _loggedMissingClient = true;
        JavpLog.i(
          'discord',
          'Rich Presence idle — set DISCORD_CLIENT_ID dart-define',
        );
      }
      return;
    }

    await _restoreEnabled();
    _refreshCopy(forcePush: false);
    if (_disposed || !_enabled) return;
    await _ensureConnected();
    if (_playback != null) {
      sync(_playback!);
    } else {
      await _push(DiscordPresenceSnapshot.browsing(_copy), force: true);
    }
  }

  /// Mirror [playback] into Discord.
  ///
  /// Position ticks from [PlaybackProvider] fire constantly, so only
  /// meaningful changes reach IPC: title / play-pause, and seeks (which move
  /// the derived timestamp anchor beyond the tolerance).
  void sync(PlaybackProvider playback) {
    _playback = playback;
    if (_disposed || !_started || !_enabled || !isSupported) return;

    _trackSession(playback);
    _requestPush(_snapshot(playback));
    _armHeartbeat();
  }

  /// Anchor the live elapsed timer to when this session opened.
  void _trackSession(PlaybackProvider playback) {
    final key = playback.hasSession ? (playback.item?.id ?? '?') : null;
    if (key == _sessionKey) return;
    _sessionKey = key;
    _sessionStartedAt = key == null ? null : DateTime.now();
  }

  DiscordPresenceSnapshot _snapshot(PlaybackProvider playback) {
    return DiscordPresenceMapper.fromPlayback(
      hasSession: playback.hasSession,
      item: playback.item,
      playing: playback.playing,
      position: playback.position,
      duration: playback.duration,
      sessionStartedAt: _sessionStartedAt,
      hideTitle: _hideTitle,
      copy: _copy,
    );
  }

  /// Drop no-op refreshes, then rate-limit what is left.
  void _requestPush(DiscordPresenceSnapshot snap) {
    if (snap.matchesWithinTolerance(_lastSent)) return;

    final last = _lastPushAt;
    final elapsed = last == null
        ? _minPushInterval
        : DateTime.now().difference(last);
    if (elapsed >= _minPushInterval) {
      _pendingSnapshot = null;
      _pendingPushTimer?.cancel();
      _pendingPushTimer = null;
      unawaited(_push(snap));
      return;
    }

    _pendingSnapshot = snap;
    _pendingPushTimer ??= Timer(_minPushInterval - elapsed, () {
      _pendingPushTimer = null;
      final pending = _pendingSnapshot;
      _pendingSnapshot = null;
      if (pending == null || _disposed || !_enabled) return;
      // Re-derive so the trailing update carries a current position.
      final pb = _playback;
      final snap = pb == null ? pending : _snapshot(pb);
      if (snap.matchesWithinTolerance(_lastSent)) return;
      unawaited(_push(snap));
    });
  }

  void _cancelPendingPush() {
    _pendingPushTimer?.cancel();
    _pendingPushTimer = null;
    _pendingSnapshot = null;
  }

  void _armHeartbeat() {
    final playback = _playback;
    // Paused sessions omit timestamps; no need to pulse Discord until play.
    if (playback == null || !playback.hasSession || !playback.playing) {
      _cancelHeartbeat();
      return;
    }
    _heartbeatTimer ??= Timer.periodic(_heartbeat, (_) {
      if (_disposed || !_enabled) return;
      final pb = _playback;
      if (pb == null || !pb.hasSession || !pb.playing) {
        _cancelHeartbeat();
        return;
      }
      _requestPush(_snapshot(pb));
    });
  }

  void _cancelHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Persist and apply the Settings toggle.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    // Let the Settings Switch paint before prefs I/O / Discord IPC.
    await persistAfterFrame(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(prefsKey, value);
      } catch (e) {
        JavpLog.w(
          'discord',
          'Failed to persist Rich Presence toggle',
          error: e,
        );
      }

      if (!value) {
        _cancelReconnect();
        _cancelHeartbeat();
        _cancelPendingPush();
        await _clearQuietly();
        return;
      }

      if (!_started || _disposed) return;
      await _ensureConnected();
      if (_playback != null) {
        sync(_playback!);
      } else {
        await _push(DiscordPresenceSnapshot.browsing(_copy), force: true);
      }
    });
  }

  /// Persist and apply the privacy toggle (hide what is playing).
  Future<void> setHideTitle(bool value) async {
    if (_hideTitle == value) return;
    _hideTitle = value;
    await persistAfterFrame(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(hideTitlePrefsKey, value);
      } catch (e) {
        JavpLog.w(
          'discord',
          'Failed to persist Rich Presence privacy',
          error: e,
        );
      }

      if (!_started || _disposed || !_enabled) return;
      final playback = _playback;
      if (playback != null) {
        await _push(_snapshot(playback), force: true);
      }
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _locale?.removeListener(_onLocaleChanged);
    _locale = null;
    _cancelReconnect();
    _cancelHeartbeat();
    _cancelPendingPush();
    _playback = null;
    await _clearQuietly();
    final rpc = _rpc;
    _rpc = null;
    if (rpc != null) {
      try {
        await platform.disposeRpc(rpc);
      } catch (_) {}
    }
  }

  Future<void> _restoreEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(prefsKey) ?? true;
      _hideTitle = prefs.getBool(hideTitlePrefsKey) ?? false;
    } catch (_) {
      _enabled = true;
      _hideTitle = false;
    }
  }

  Future<void> _ensureConnected() async {
    if (_disposed || !_enabled || !isSupported) return;
    if (_rpc != null && platform.isRpcConnected(_rpc!)) return;
    if (_connecting) return;
    _connecting = true;
    try {
      await _connectOnce();
      _reconnectAttempt = 0;
    } on platform.DiscordNotRunningException {
      _scheduleReconnect();
    } catch (e) {
      JavpLog.w('discord', 'Rich Presence connect failed', error: e);
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _connectOnce() async {
    final existing = _rpc;
    if (existing != null) {
      try {
        await platform.disposeRpc(existing);
      } catch (_) {}
      _rpc = null;
    }

    final rpc = await platform.createAndInitializeRpc(clientId);
    if (_disposed) {
      await platform.disposeRpc(rpc);
      return;
    }
    _rpc = rpc;
    JavpLog.i('discord', 'Rich Presence connected');
  }

  void _scheduleReconnect() {
    if (_disposed || !_enabled || !isSupported) return;
    _reconnectTimer?.cancel();
    final shift = _reconnectAttempt.clamp(0, 5);
    final delay = Duration(
      milliseconds: (_reconnectBase.inMilliseconds * (1 << shift)).clamp(
        0,
        _reconnectMax.inMilliseconds,
      ),
    );
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || !_enabled) return;
      unawaited(
        _ensureConnected().then((_) {
          if (_playback != null) sync(_playback!);
        }),
      );
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
  }

  Future<void> _push(DiscordPresenceSnapshot snap, {bool force = false}) async {
    if (_disposed || !_enabled || !isSupported) return;
    if (!force && snap == _lastSent) return;

    if (_rpc == null || !platform.isRpcConnected(_rpc!)) {
      await _ensureConnected();
      if (_rpc == null || !platform.isRpcConnected(_rpc!)) return;
    }

    final rpc = _rpc;
    if (rpc == null) return;

    final watch = Stopwatch()..start();
    try {
      await platform.setPresence(rpc, _toDiscord(snap));
      _lastSent = snap;
      _lastPushAt = DateTime.now();
      JavpLog.slow(
        'discord',
        'setPresence in ${watch.elapsedMilliseconds}ms',
        watch.elapsedMilliseconds,
      );
    } on platform.DiscordNotRunningException {
      _lastSent = null;
      _scheduleReconnect();
    } on platform.DiscordConnectionException {
      _lastSent = null;
      _scheduleReconnect();
    } catch (e) {
      JavpLog.w('discord', 'setPresence failed', error: e);
      _lastSent = null;
      _scheduleReconnect();
    }
  }

  Future<void> _clearQuietly() async {
    final rpc = _rpc;
    _lastSent = null;
    if (rpc == null || !platform.isRpcConnected(rpc)) return;
    try {
      await platform.clearPresence(rpc);
    } catch (_) {}
  }

  platform.DiscordPresenceData _toDiscord(DiscordPresenceSnapshot snap) {
    final art = snap.art;
    final largeUrl = art.largeImageUrl;

    return platform.DiscordPresenceData(
      activity: snap.activity,
      details: snap.details,
      state: snap.state,
      startUnixSec: snap.startUnixSec,
      endUnixSec: snap.endUnixSec,
      largeAssetKey: largeUrl != null && largeUrl.isNotEmpty ? largeUrl : _assetKey,
      largeAssetText: largeUrl != null && largeUrl.isNotEmpty ? snap.details : 'JAVP',
      smallAssetKey: art.showSmallLogo ? _assetKey : null,
      smallAssetText: art.showSmallLogo ? 'JAVP' : null,
      websiteUrl: _websiteUrl,
      discordInviteUrl: _discordInviteUrl,
      isExternalUrl: largeUrl != null && largeUrl.isNotEmpty,
    );
  }
}
