import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/caption_style.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/models/track_language_settings.dart';
import 'package:javp/models/video_aspect_mode.dart';
import 'package:javp/models/video_deinterlace_mode.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/platform/web_app_limitation.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/catalog/catalog_play_headers.dart';
import 'package:javp/services/iptv/m3u_playlist_io.dart';
import 'package:javp/services/iptv/live_zap_number.dart';
import 'package:javp/services/iptv/xtream_client.dart';
import 'package:javp/services/iptv/xtream_play_url.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/cast/cast_protocol.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/download/catchup_air_date.dart';
import 'package:javp/services/media_server/jellyfin_client.dart';
import 'package:javp/services/media_server/plex_client.dart';
import 'package:javp/services/playback/audio_stream.dart';
import 'package:javp/services/playback/drm_detect.dart';
import 'package:javp/services/playback/drm_manifest_probe.dart';
import 'package:javp/services/playback/hls_master.dart';
import 'package:javp/services/playback/track_language.dart';
import 'package:javp/services/playback/vod_end.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/services/playback/dvr_timeshift_window.dart';
import 'package:javp/services/playback/hls_native_dvr.dart';
import 'package:javp/services/playback/live_edge_rate.dart';
import 'package:javp/services/playback/live_edge_seek.dart';
import 'package:javp/services/playback/video_output_size.dart';
import 'package:javp/services/playback/video_player_engine.dart';
import 'package:javp/services/playback/player_loading_overlay.dart';
import 'package:javp/services/ads/vast_client.dart';
import 'package:javp/services/ads/vast_macros.dart';
import 'package:javp/services/ads/vast_models.dart';
import 'package:javp/services/pip/pip_service.dart';
import 'package:javp/services/platform/desktop_window_service.dart';
import 'package:javp/services/platform/external_browser.dart';
import 'package:javp/services/torrent/torrent_stream_service.dart';
import 'package:javp/compat/media_kit.dart';
import 'package:javp/compat/media_kit_video.dart';
import 'package:javp/compat/defer_notify.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:javp/services/playback/player_loading_overlay.dart'
    show playerLoadingOverlayVisible;

part 'playback/playback_engine.dart';
part 'playback/playback_vast.dart';
part 'playback/playback_dvr.dart';

/// App-wide playback session so leaving the full player can keep a mini player.
///
/// This is the **session** façade (engine, open/close, ads, DVR, tracks, cast,
/// PiP). Catalog / history / URL resolve stay on [LibraryProvider].
///
/// Map (search these names; do not add a fourth player chrome here):
/// - Dual engine — `_enginePlay`, [VideoPlayerEngine]
/// - Open / close races — `open(`, `_openEpoch`, `_miniGeneration`
/// - VAST — `_PendingAfterAds`
/// - Live DVR — `seekLiveDvr`, `jumpToLive`
/// - Tracks — `setAudioTrack`
/// - Mini / cinema / surface — `minimize`, `claimVideoSurface`
///
/// Engine / VAST / DVR methods live in `lib/providers/playback/*.dart`
/// (same-library extensions). New domain logic belongs in
/// `lib/services/playback/` with a thin forwarder. See `docs/architecture.md`.
class PlaybackProvider extends ChangeNotifier with DeferNotifyIfBuilding {
  static const _defaultHttpHeaders = {'User-Agent': 'JAVP', 'Accept': '*/*'};
  static const _editionAudioPrefix = 'javp-edition-audio:';
  static const _editionSubPrefix = 'javp-edition-sub:';
  static const _mediaKitVideoChannel = MethodChannel(
    'com.alexmercerind/media_kit_video',
  );

  PlaybackProvider({
    required this.library,
    TorrentStreamService? torrents,
    PipService? pip,
    VastClient? vast,
  }) : _torrents = torrents ?? library.torrents,
       _pip = pip ?? PipService(),
       _ownsPip = pip == null,
       _vast = vast ?? VastClient() {
    _pip.onPipAction = _onPipAction;
    _pip.addListener(_onPipServiceChanged);
    library.cast.addListener(_onCastChanged);
    _browsePanelHydrate = _hydrateBrowsePanelCollapsed();
    unawaited(_hydratePlayerDisplayPrefs());
  }

  final LibraryProvider library;

  /// Shared by the full player and the mini dock so minimize/expand moves the
  /// existing media_kit [Video] Element instead of tearing the texture down.
  final GlobalKey videoSurfaceKey = GlobalKey(debugLabel: 'playbackVideo');

  bool _disposed = false;

  @override
  bool get notifyListenersDisposed => _disposed;

  /// Same-library extensions cannot call [notifyListeners] (protected).
  void _notifySession() => notifyListeners();

  final TorrentStreamService _torrents;
  final PipService _pip;
  final bool _ownsPip;
  final VastClient _vast;
  Player? _player;
  VideoController? _controller;
  VideoPlayerEngine? _vp;
  String? _vpPlayUrl;

  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<Track>? _trackSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;

  MediaItem? _item;

  /// Original live channel while scrubbing its catchup/DVR window.
  MediaItem? _liveChannel;

  /// Absolute wall-clock start of the current timeshift clip (`null` = live edge).
  DateTime? _dvrStart;

  /// Wall-clock when the user paused at the live edge (pending timeshift resume).
  DateTime? _livePausedAt;

  /// Debounce timeshift auto-extend so a broken short clip cannot loop.
  DateTime? _lastTimeshiftExtendAt;

  /// Join the live edge once after opening a seekable live HLS window.
  ///
  /// `force-seekable` often starts at segment 0 (oldest). Clappr/hls.js start
  /// at the live sync point; we seek near duration on the first window report.
  bool _pendingNativeHlsLiveJoin = false;

  /// Bumped to cancel an in-flight [_seekNearLiveEdge] (new open, resume, etc.).
  int _nearLiveSeekGeneration = 0;

  /// Live streamIds already tried this zap (preferred feed failed → siblings).
  final Set<String> _triedLiveStreamIds = {};

  /// Family key for [_triedLiveStreamIds] — cleared when zapping to another channel.
  String? _liveQualityFallbackFamilyKey;

  /// True while auto-falling back to the next HD/SD sibling.
  bool _liveQualityFallbackInFlight = false;

  Timer? _livePauseTicker;
  Timer? _sleepTimer;
  Timer? _sleepTickTimer;
  DateTime? _sleepEndsAt;
  Duration? _sleepDuration;
  bool _sleepFiredFlag = false;
  bool _minimized = false;
  bool _expanded = false;

  /// Full-bleed immersive player. Off = watch + browse layout.
  bool _cinemaMode = false;
  VideoAspectMode _videoAspectMode = VideoAspectMode.fit;
  VideoDeinterlaceMode _deinterlaceMode = VideoDeinterlaceMode.auto;
  bool _showStreamStats = false;
  static const _videoAspectPrefKey = 'player_video_aspect';
  static const _deinterlacePrefKey = 'player_deinterlace';
  static const _streamStatsPrefKey = 'player_stream_stats';

  /// Hide the watch+browse details panel without entering cinema.
  /// Persisted so opening a channel restores the last open/collapsed choice.
  bool _browsePanelCollapsed = false;
  bool _browsePanelTouched = false;
  late final Future<void> _browsePanelHydrate;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _lastSavedSecond = -1;
  DateTime? _lastServerProgressAt;
  static const _serverProgressMinInterval = Duration(seconds: 30);
  bool _dvrBusy = false;
  bool _opening = false;

  /// Quality / HLS retune that reopens media without [_opening] chrome.
  /// Minimize must still dock (unlike a failed first open).
  int _retuneDepth = 0;

  /// True while a VOD / in-clip seek is in flight or still rebuffering.
  bool _seekBusy = false;

  /// Buffering was observed after the latest seek (wait for it to finish).
  bool _sawBufferingDuringSeek = false;
  Timer? _seekBusyTimer;

  /// Bumped on every [open] so overlapping switches drop stale work.
  int _openEpoch = 0;

  /// Bumped on [minimize]/ [open] snapshots this so close-during-load cannot
  /// re-apply expand:true after the user already left the full player.
  int _miniGeneration = 0;

  /// Full-screen `/player` or `/tv/watch` currently hosts [videoSurfaceKey].
  /// The mini dock may attach that key only when this is false — two [Video]
  /// widgets with the same GlobalKey was the black flash / 400ms hitch.
  bool _fullPlayerOwnsVideo = false;

  bool get fullPlayerOwnsVideo => _fullPlayerOwnsVideo;

  /// Last caption style pushed to libmpv (libass paints; Flutter overlay is off).
  CaptionStyleSettings _captionStyle = CaptionStyleSettings.outline;
  String? _captionStyleSignature;
  DateTime? _lastPositionUiNotify;
  bool _positionUiNotifyScheduled = false;
  bool _tvVideoSurfaceCapInFlight = false;

  /// media_kit texture size we refuse to shrink (HLS 1080→360 would
  /// otherwise UnregisterTexture and freeze the last frame).
  int? _pinnedVoW;
  int? _pinnedVoH;

  /// True while Android has us paused/hidden — skip heavy wake work.
  bool _appInBackground = false;
  bool _playingBeforeBackground = false;
  DateTime? _backgroundedAt;

  /// True when [onAppBackgrounded] ran because of a Windows long blur (not
  /// true OS AFK). Focus soft-resumes via [onDesktopShellFocused].
  /// Kept for shell/multi-view resume bookkeeping; video is no longer paused
  /// on blur (that used to fire after 45s and felt like a mystery pause).
  bool _pausedForWindowsLongBlur = false;

  /// Invoked after a Windows long-blur pause so the shell can pause multi-view.
  VoidCallback? onWindowsLongBlurPaused;

  /// See [_pausedForWindowsLongBlur].
  bool get pausedForWindowsLongBlur => _pausedForWindowsLongBlur;

  /// Optimistic play/pause until the engine's `playing` stream catches up.
  /// Lets the chrome flip immediately instead of waiting on media_kit IPC.
  bool? _playingOverride;

  /// Rolling window for "Error decoding audio" spam while playing.
  DateTime? _audioDecodeErrorWindowStart;
  int _audioDecodeErrorCount = 0;
  DateTime? _lastAudioDecodeLogAt;

  static const _audioDecodeErrorPauseAfter = 12;
  static const _audioDecodeLogMinInterval = Duration(seconds: 5);
  static const _audioDecodeErrorWindow = Duration(minutes: 2);

  /// Prefetched next episode for series playback (null = none / not ready).
  MediaItem? _nextEpisode;

  /// Prefetched previous episode for series playback.
  MediaItem? _previousEpisode;
  bool _advancingEpisode = false;

  /// Item id for which end-of-VOD handling already ran (completed or near-end).
  String? _handledVodCompletionId;

  /// Longest known runtime for the open VOD (catalog, then engine if longer).
  Duration? _vodRuntimeHint;
  DateTime? _lastFalseEofRecoverAt;
  int _falseEofRecoverCount = 0;

  /// Apply language prefs once per open until the user overrides.
  String? _langPrefsItemKey;
  bool _autoSubtitleApplied = false;

  /// True when auto-subs matched the primary preferred language (not EN fallback).
  bool _autoSubtitlePrimaryMatch = false;
  bool _autoAudioApplied = false;
  bool _userPickedSubtitle = false;
  bool _userPickedAudio = false;
  SessionTrackPick? _sessionSubtitle;
  SessionTrackPick? _sessionAudio;

  /// Desktop software volume (0–100); phones use hardware keys instead.
  double _volume = 100;

  /// Level to restore on unmute (`null` = not muted).
  double? _volumeBeforeMute;

  /// Per-title software gain (100–300). Session-only; not a global setting.
  double _volumeBoostPercent = volumeBoostMin;

  /// Movie id or series key the current boost belongs to (`null` = none).
  String? _volumeBoostScopeKey;

  /// Last gain pushed to the engine (also recorded when no player is attached).
  double? _lastPushedEngineVolume;

  /// Session-only software decode after a hwdec codec open failure.
  /// Does not rewrite [LibraryProvider.softwareVideoDecoder].
  bool _sessionSoftwareDecoder = false;

  /// Guards against stacking codec fallbacks from repeated error events.
  bool _codecFallbackInFlight = false;

  /// True from media open until the first [playing] event for this session.
  bool _awaitingInitialPlayback = false;

  /// Magnet / .torrent metadata resolve in flight (not decoder open / buffer).
  bool _resolvingTorrent = false;

  /// User dismissed the slow-load quality tip for the current open attempt.
  bool _slowLoadHintDismissed = false;

  /// Show “try lower quality” after a long initial load (media servers).
  bool _suggestLowerQuality = false;
  Timer? _slowLoadTimer;

  /// Plex Live TV transcoder session key (`/livetv/sessions/…`) for keepalive.
  String? _plexLiveSessionKey;
  Timer? _plexLiveKeepaliveTimer;
  static const _plexLiveKeepaliveInterval = Duration(seconds: 30);

  /// Parsed HLS master variants for this session (quality picker / demuxed fix).
  List<HlsVariant> _hlsVariants = const [];

  /// Original master URL when [_hlsVariants] came from a master playlist.
  String? _hlsMasterUrl;

  /// Catalog /play URL before redirects, when different from [_hlsMasterUrl].
  String? _hlsSourceUrl;

  /// True when Auto should open the master (muxed ABR) vs best media playlist.
  bool _hlsOpenMasterForAbr = false;

  /// User left Adaptive quality on Auto (default).
  bool _hlsQualityAuto = true;

  /// Locked media-playlist URL when [_hlsQualityAuto] is false.
  String? _hlsLockedVariantUrl;

  /// Last libmpv video-track snapshot with at least two HLS programs.
  List<HlsDemuxerVideo> _hlsDemuxerCache = const [];

  /// Actual URL last opened in the engine (may differ from [MediaItem.playUrl]).
  String? _activePlayUrl;

  List<VastLinearAd> _adQueue = const [];
  VastLinearAd? _currentAd;
  final Set<String> _adEventsFired = {};
  _PendingAfterAds? _pendingAfterAds;
  VastSchedule? _vastSchedule;
  final Set<int> _playedMidrollIndexes = {};
  bool _midrollInFlight = false;
  bool _postrollsPlayed = false;
  Duration _lastContentPosition = Duration.zero;
  DateTime? _adViewableSince;
  bool _adViewableResolved = false;
  final Set<String> _iconViewFired = {};

  static const _slowLoadHintDelay = Duration(seconds: 12);
  static const _hlsTrackPrefix = 'hls:';

  double get volume => _volume;
  bool get isMuted => _volume <= 0;
  bool _engineSilenced = false;

  /// Minimum / off value for [volumeBoostPercent].
  static const double volumeBoostMin = 100;

  /// libmpv `volume-max` and UI ceiling (300% as requested).
  static const double volumeBoostMax = 300;

  /// TV / remote-friendly boost steps (Off, +150%, +200%, +250%, +300%).
  static const List<double> volumeBoostPresets = <double>[
    100,
    150,
    200,
    250,
    300,
  ];

  /// Extra gain for the current title (100 = off). Not persisted.
  double get volumeBoostPercent => _volumeBoostPercent;

  bool get hasVolumeBoost => _volumeBoostPercent > volumeBoostMin;

  /// Engine volume after boost, ignoring multi-view silence.
  @visibleForTesting
  double get engineVolume =>
      (_volume * (_volumeBoostPercent / 100.0)).clamp(0.0, volumeBoostMax);

  /// Last gain pushed to the engine; tests use this without a libmpv handle.
  @visibleForTesting
  double? get lastPushedEngineVolume => _lastPushedEngineVolume;

  /// Scope key so a series binge keeps boost and a different title resets it.
  @visibleForTesting
  static String volumeBoostScopeKey(MediaItem item) {
    final seriesId = item.seriesId?.trim();
    if (item.isEpisode && seriesId != null && seriesId.isNotEmpty) {
      return 'series:${item.sourceId ?? ''}:$seriesId';
    }
    return 'item:${item.id}';
  }

  @visibleForTesting
  static double clampVolumeBoost(double percent) {
    final clamped = percent.clamp(volumeBoostMin, volumeBoostMax);
    return ((clamped / 10).round() * 10).toDouble();
  }

  void _adoptVolumeBoostScope(MediaItem item) {
    final key = volumeBoostScopeKey(item);
    if (_volumeBoostScopeKey == key) return;
    _volumeBoostScopeKey = key;
    _volumeBoostPercent = volumeBoostMin;
    // Title switches reuse the libmpv handle (`_clearEngineBeforeLoad` only
    // stops it; `_finishEngineSetup` runs once at create). Push 100% so the
    // previous gain cannot leak into the next movie / show / live channel.
    unawaited(_applyEngineVolume());
  }

  void _resetVolumeBoost() {
    _volumeBoostScopeKey = null;
    _volumeBoostPercent = volumeBoostMin;
  }

  /// Applies a software volume level and remembers it for the next engine.
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 100.0);
    if (clamped > 0) _volumeBeforeMute = null;
    final wasMuted = isMuted;
    if (_volume != clamped) {
      _volume = clamped;
      notifyListeners();
    }
    if (isPlayingAd && wasMuted != isMuted) {
      _pingAdEvent(isMuted ? 'mute' : 'unmute');
    }
    await _applyEngineVolume();
  }

  /// Session-only gain above 100% for quiet titles. Resets on [stop] or when
  /// a different movie / series starts.
  Future<void> setVolumeBoost(double percent) async {
    final clamped = clampVolumeBoost(percent);
    if (_volumeBoostPercent != clamped) {
      _volumeBoostPercent = clamped;
      notifyListeners();
    }
    await _applyEngineVolume();
  }

  Future<void> _applyEngineVolume({Player? player}) async {
    final target = _engineSilenced ? 0.0 : engineVolume;
    _lastPushedEngineVolume = target;
    final p = player ?? _player;
    if (p == null) return;
    try {
      await p.setVolume(target);
    } catch (e) {
      debugPrint('setVolume failed: $e');
    }
  }

  /// Returns the resulting level so callers can show an OSD.
  Future<double> nudgeVolume(double delta) async {
    await setVolume(_volume + delta);
    return _volume;
  }

  Future<void> toggleMute() async {
    final restore = _volumeBeforeMute;
    if (restore != null) {
      await setVolume(restore <= 0 ? 100 : restore);
      return;
    }
    if (_volume <= 0) {
      await setVolume(100);
      return;
    }
    final previous = _volume;
    await setVolume(0);
    _volumeBeforeMute = previous;
  }

  /// Silence the libmpv engine without changing the remembered volume preference.
  ///
  /// Used by multi-view so the secondary pane can own audio while primary still
  /// shows the user's volume level in chrome.
  Future<void> setEngineSilenced(bool silenced) async {
    _engineSilenced = silenced;
    final player = _player;
    if (player == null) return;
    try {
      await _applyEngineVolume(player: player);
    } catch (e) {
      debugPrint('setEngineSilenced failed: $e');
    }
  }

  String? _extraCaptionFontsDir;

  /// Push caption preset/style into libass (file styles vs app overrides).
  Future<void> applyCaptionStyle(
    CaptionStyleSettings style, {
    String? extraFontsDir,
  }) async {
    _captionStyle = style;
    _extraCaptionFontsDir = extraFontsDir;
    await _applyCaptionRenderingMode(style);
  }

  bool get _currentSubtitleIsAss {
    final player = _player;
    if (player == null) return false;
    return subtitleTrackLooksLikeAss(
      player.state.track.subtitle,
      external: _item?.subtitles ?? const [],
    );
  }

  Future<void> _applyCaptionRenderingMode(CaptionStyleSettings style) async {
    if (!AppCapabilities.usesMediaKit) return;
    final player = _player;
    if (player == null) return;
    final trackIsAss = _currentSubtitleIsAss;
    final useNative = style.shouldUseNativeFileStyle(trackIsAss: trackIsAss);
    final extraFontsDir = _extraCaptionFontsDir;
    final signature = useNative
        ? 'native:$trackIsAss'
        : 'styled:$trackIsAss:${style.toJson()}:$extraFontsDir';
    if (_captionStyleSignature == signature) return;
    try {
      final platform = player.platform;
      if (platform is! NativePlayer) return;
      if (useNative) {
        // Keep ASS/SSA (and embedded fonts) exactly as authored.
        await platform.setProperty('sub-ass-override', 'no');
      } else {
        // `force` applies sub-* looks while still rendering through libass.
        await platform.setProperty('sub-ass-override', 'force');
        if (defaultTargetPlatform == TargetPlatform.android) {
          // libass cannot discover Android system fonts without an explicit dir.
          await platform.setProperty('sub-fonts-dir', '/system/fonts');
          await platform.setProperty(
            'sub-font',
            CaptionStyleSettings.resolveMpvFontFamily(
              style.fontFamily,
              isAndroid: true,
            ),
          );
        } else if (defaultTargetPlatform == TargetPlatform.windows) {
          await platform.setProperty('sub-fonts-dir', r'C:\Windows\Fonts');
        } else if (defaultTargetPlatform == TargetPlatform.linux) {
          await platform.setProperty('sub-fonts-dir', '/usr/share/fonts');
        }
        // Imported .ttf/.otf files (additional search path for libass).
        if (extraFontsDir != null && extraFontsDir.isNotEmpty) {
          await platform.setProperty('fonts-dir', extraFontsDir);
        }
        for (final entry in style.toMpvSubProperties().entries) {
          if (defaultTargetPlatform == TargetPlatform.android &&
              entry.key == 'sub-font') {
            continue;
          }
          await platform.setProperty(entry.key, entry.value);
        }
      }
      _captionStyleSignature = signature;
    } catch (e) {
      debugPrint('Caption rendering mode failed: $e');
    }
  }

  Future<void> _finishEngineSetup(Player player) async {
    await _configureNativeAudio(player);
    await _configureSeekability(player);
    await _configureHlsDemuxer(player);
    await _configureVolumeMax(player);
    await _configureDeinterlace(player);
    await _applyEngineVolume(player: player);
    _captionStyleSignature = null;
    await _applyCaptionRenderingMode(_captionStyle);
    unawaited(_maybePinVideoOutput());
  }

  void _resetVideoOutputPin() {
    _pinnedVoW = null;
    _pinnedVoH = null;
  }

  /// Keep the Flutter texture at a stable size so HLS quality picks do not
  /// tear down [VideoOutput] (freeze, then a new 640×360 plane).
  ///
  /// On Android TV this also caps 4K to 1080p — media_kit otherwise sizes
  /// the Surface to the coded frame, which Skia cannot composite in time.
  Future<void> _maybePinVideoOutput() async {
    if (!AppCapabilities.usesMediaKit) return;
    final player = _player;
    if (player == null) return;
    var spins = 0;
    while (_tvVideoSurfaceCapInFlight && spins < 40) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      spins++;
    }
    if (!identical(_player, player)) return;
    final next = _desiredVideoOutputPin();
    if (next == null) return;
    final same = _pinnedVoW == next.width && _pinnedVoH == next.height;
    if (same && defaultTargetPlatform != TargetPlatform.android) return;
    _pinnedVoW = next.width;
    _pinnedVoH = next.height;
    _tvVideoSurfaceCapInFlight = true;
    try {
      await _applyVideoOutputPin(next.width, next.height);
      if (!same) {
        JavpLog.i('player', 'vo pin ${next.width}x${next.height}');
      }
      if (defaultTargetPlatform != TargetPlatform.android) return;
      // video-params often reset the Surface to coded size a moment later.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!identical(_player, player)) return;
      await _applyAndroidTvVideoSurfaceSize(next.width, next.height);
    } finally {
      _tvVideoSurfaceCapInFlight = false;
    }
  }

  ({int width, int height})? _desiredVideoOutputPin() {
    final player = _player;
    final ladder = largestVideoSize([
      for (final v in _hlsVariants) (width: v.width, height: v.height),
    ]);
    final srcW = player?.state.width ?? 0;
    final srcH = player?.state.height ?? 0;
    var incomingW = srcW;
    var incomingH = srcH;
    if (ladder != null) {
      final srcPx = srcW * srcH;
      if (ladder.width * ladder.height >= srcPx) {
        incomingW = ladder.width;
        incomingH = ladder.height;
      }
    }
    final capTo1080p =
        TvPlatform.isTvShell && defaultTargetPlatform == TargetPlatform.android;
    return pinVideoOutputSize(
      pinnedWidth: _pinnedVoW,
      pinnedHeight: _pinnedVoH,
      incomingWidth: incomingW,
      incomingHeight: incomingH,
      capTo1080p: capTo1080p,
    );
  }

  Future<void> _applyVideoOutputPin(int width, int height) async {
    final controller = _controller;
    if (controller != null) {
      try {
        await controller.setSize(width: width, height: height);
      } catch (_) {
        // Android [VideoController.setSize] is unimplemented.
      }
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _applyAndroidTvVideoSurfaceSize(width, height);
    }
  }

  Future<void> _applyAndroidTvVideoSurfaceSize(int width, int height) async {
    final player = _player;
    if (player == null) return;
    final handle = await player.handle;
    try {
      await _mediaKitVideoChannel
          .invokeMethod<void>('VideoOutputManager.SetSurfaceSize', {
            'handle': handle.toString(),
            'width': width.toString(),
            'height': height.toString(),
          });
    } catch (e) {
      debugPrint('TV video surface cap SetSurfaceSize failed: $e');
    }
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('android-surface-size', '${width}x$height');
    } catch (e) {
      debugPrint('TV video surface cap android-surface-size failed: $e');
    }
  }

  /// Allow libmpv software gain above 100% for [volumeBoostPercent].
  Future<void> _configureVolumeMax(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(
        'volume-max',
        volumeBoostMax.round().toString(),
      );
    } catch (e) {
      debugPrint('volume-max config failed: $e');
    }
  }

  Future<void> _configureDeinterlace(Player player) async {
    if (!AppCapabilities.usesMediaKit) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('deinterlace', _deinterlaceMode.mpvValue);
    } catch (e) {
      debugPrint('deinterlace config failed: $e');
    }
  }

  /// Prefer Android AudioTrack (YouTube/ExoPlayer-style path) over OpenSL ES.
  ///
  /// OpenSL bypasses OEM speaker processing and absolute volume, so the same
  /// file often sounds thinner/quieter than YouTube. `audiotrack,opensles`
  /// falls back if AudioTrack fails on a device.
  Future<void> _configureNativeAudio(Player player) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('ao', 'audiotrack,opensles');
      // Safe downmix for phone speakers when the stream is 5.1/7.1.
      await platform.setProperty('audio-channels', 'auto-safe');
    } catch (e) {
      debugPrint('Native audio config failed: $e');
    }
  }

  /// Many live/HLS and progressive HTTP sources report as non-seekable.
  /// Allow seeks within cache (live scrub / short rewinds) instead of failing.
  Future<void> _configureSeekability(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('force-seekable', 'yes');
    } catch (e) {
      debugPrint('Seekability config failed: $e');
    }
  }

  /// FFmpeg HLS `extension_picky` rejects valid `.aac` / odd-ext segments.
  /// Newer mpv disables it for HLS; set explicitly for older libmpv builds.
  ///
  /// media_kit already sets `demuxer-lavf-o` (`allowed_extensions=ALL`, …).
  /// Replacing that string drops those flags and can hide HLS programs.
  Future<void> _configureHlsDemuxer(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(
        'demuxer-lavf-o',
        'extension_picky=0,allowed_extensions=ALL,seg_max_retry=5,'
            'strict=experimental',
      );
      // Live masters fetch every variant playlist before track-list is
      // complete. media_kit's default 5s network-timeout aborts that walk.
      await platform.setProperty('network-timeout', '30');
    } catch (e) {
      debugPrint('HLS demuxer config failed: $e');
    }
  }

  /// mpv emits seek warnings on the error stream even when playback is fine.
  static bool isBenignPlayerMessage(String message) {
    final m = message.toLowerCase();
    return m.contains('force-seekable') ||
        m.contains('cannot seek in this stream') ||
        m.contains("can't seek in this file") ||
        m.contains('not seekable');
  }

  /// Hard fail to fetch the media itself (not a decoder / audio-device probe).
  ///
  /// libmpv often flips `playing=true` as soon as `play()` is issued, before
  /// the TCP handshake finishes. Those open failures still arrive on the error
  /// stream "while playing" and must reach the overlay.
  static bool isFatalStreamOpenFailure(String message) {
    if (isCodecOpenFailure(message)) return false;
    final m = message.toLowerCase();
    if (m.contains('could not open/initialize audio device')) return false;
    if (m.contains('failed to open')) return true;
    if (m.contains('unable to open')) return true;
    if (m.contains('connection to tcp://') && m.contains('failed')) {
      return true;
    }
    if (m.contains('connection refused') ||
        m.contains('connection timed out') ||
        m.contains('network is unreachable') ||
        m.contains('no route to host')) {
      return true;
    }
    if (RegExp(r'http error [45]\d\d').hasMatch(m)) return true;
    return false;
  }

  /// Whether a libmpv error deserves the blocking "couldn't play" overlay.
  ///
  /// Desktop libmpv probes decoders and audio devices while a file is already
  /// playing, so it reports things like a failed hwdec codec or a missing
  /// audio device mid-playback. Covering a running picture with a retry sheet
  /// is worse than logging it. Resource open failures are the exception:
  /// they mean there is no picture, even if the engine already claimed
  /// `playing`.
  static bool shouldSurfacePlayerError(
    String message, {
    required bool playing,
    bool awaitingInitialPlayback = false,
  }) {
    if (message.trim().isEmpty) return false;
    if (isBenignPlayerMessage(message)) return false;
    if (isFatalStreamOpenFailure(message)) return true;
    if (isCodecOpenFailure(message) || isAudioDecodeError(message)) {
      return !playing;
    }
    if (awaitingInitialPlayback) return true;
    return !playing;
  }

  /// libmpv / MediaCodec failed to open a decoder before frames started.
  static bool isCodecOpenFailure(String message) {
    final m = message.toLowerCase();
    return m.contains('could not open codec') ||
        m.contains('failed to open codec') ||
        m.contains('cannot open codec');
  }

  /// Mid-playback audio decode failures (often IPTV AAC) — not a hard open fail.
  static bool isAudioDecodeError(String message) {
    final m = message.toLowerCase();
    return m.contains('error decoding audio') ||
        m.contains('failed to decode audio') ||
        m.contains('decoding audio');
  }

  bool get _useSoftwareDecoder =>
      _sessionSoftwareDecoder || library.softwareVideoDecoder;

  void _schedulePositionUiNotify() {
    final now = DateTime.now();
    final last = _lastPositionUiNotify;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 200)) {
      if (_positionUiNotifyScheduled) return;
      _positionUiNotifyScheduled = true;
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        _positionUiNotifyScheduled = false;
        _lastPositionUiNotify = DateTime.now();
        notifyListeners();
      });
      return;
    }
    _lastPositionUiNotify = now;
    notifyListeners();
  }

  /// libmpv handle — media_kit path only.
  Player get _engine {
    if (!AppCapabilities.usesMediaKit) {
      throw UnsupportedError(
        'media_kit Player is only available when AppCapabilities.usesMediaKit is true',
      );
    }
    _ensureEngine();
    return _player!;
  }

  bool get _enginePlaying => AppCapabilities.usesVideoPlayerBackend
      ? (_vp?.playing ?? false)
      : (_player?.state.playing ?? false);

  bool get _engineBuffering => AppCapabilities.usesVideoPlayerBackend
      ? (_vp?.buffering ?? false)
      : (_player?.state.buffering ?? false);

  Duration get _enginePosition => AppCapabilities.usesVideoPlayerBackend
      ? (_vp?.position ?? _position)
      : (_player?.state.position ?? _position);

  Duration get _engineDuration => AppCapabilities.usesVideoPlayerBackend
      ? (_vp?.duration ?? _duration)
      : (_player?.state.duration ?? _duration);

  Duration get _engineBuffer => AppCapabilities.usesVideoPlayerBackend
      ? (_vp?.buffer ?? Duration.zero)
      : (_player?.state.buffer ?? Duration.zero);

  bool _isStaleOpen(int epoch) => epoch != _openEpoch;

  /// Invalidate any in-flight [open] (used by [stop] so close-during-load cannot
  /// recreate an expanded session after teardown).
  /// Returns true when UI should refresh (loading / slow-load hint cleared).
  bool _cancelInFlightOpen() {
    _openEpoch++;
    final cancelled =
        _opening ||
        _retuneDepth > 0 ||
        _awaitingInitialPlayback ||
        _suggestLowerQuality ||
        _resolvingTorrent;
    _opening = false;
    _retuneDepth = 0;
    _resolvingTorrent = false;
    _clearSlowLoadHint(resetAwaiting: true);
    return cancelled;
  }

  /// Apply [expand] unless the user minimized after this [open] started.
  void _applyOpenChrome({required bool expand, required int miniGeneration}) {
    if (_miniGeneration != miniGeneration) {
      _minimized = true;
      _expanded = false;
      return;
    }
    _minimized = !expand;
    _expanded = expand;
  }

  /// True when [item] is the current session (id, URL, or live stream identity).
  bool sessionMatches(MediaItem item) =>
      _samePlaybackSession(_item, item) ||
      _samePlaybackSession(_liveChannel, item);

  /// True when [item] is the same playback session as [leaving] (id, URL, or
  /// live stream identity). Used so stream reload / resolve does not treat a
  /// quality URL tweak as a brand-new title for chrome purposes.
  bool _samePlaybackSession(MediaItem? leaving, MediaItem item) {
    if (leaving == null) return false;
    if (leaving.id == item.id) return true;
    if (leaving.playUrl.isNotEmpty && leaving.playUrl == item.playUrl) {
      return true;
    }
    final streamId = leaving.streamId;
    if (streamId != null &&
        streamId.isNotEmpty &&
        streamId == item.streamId &&
        leaving.sourceId == item.sourceId) {
      return true;
    }
    return false;
  }

  /// Keep the mini-player dock across same-session reloads / recoveries.
  ///
  /// [open] defaults to `expand: true` for cold starts. Applying that while
  /// already minimized (no `/player` route) orphans media_kit audio with no
  /// chrome. PlayerScreen expands via [expand] after push instead.
  bool _resolveOpenExpand({
    required bool expand,
    required MediaItem? leaving,
    required MediaItem item,
  }) {
    if (!expand) return false;
    // Keep the local player minimized so a new title recasts instead of
    // expanding phone chrome over the Chromecast session.
    if (library.cast.isCasting) return false;
    if (_minimized && _samePlaybackSession(leaving, item)) {
      return false;
    }
    return true;
  }

  /// Public seek used by simple TV controls / UI that must not touch media_kit.
  Future<void> seekTo(Duration position) {
    if (isPlayingAd) return Future.value();
    return _seekInClip(position);
  }

  /// Completes after native mpv properties (audio path, captions) are applied.
  Future<void>? _engineSetup;

  int _engineRevision = 0;

  void _onCompleted(bool done) {
    if (!done) return;
    if (_currentAd != null) {
      unawaited(_finishCurrentAd(skipped: false));
      return;
    }
    if (_dvrStart != null && _liveChannel != null) {
      unawaited(_onTimeshiftCompleted());
      return;
    }
    final item = _item;
    if (item == null || item.isLive) return;
    final decision = _vodEndDecision(eofReached: true);
    JavpLog.i(
      'play',
      'eof item=${item.id} pos=${_position.inSeconds}s '
          'engine=${_engineDuration.inSeconds}s '
          'catalog=${_vodRuntimeHint?.inSeconds ?? item.duration?.inSeconds}s '
          'finished=${decision.finished} reason=${decision.reason}',
    );
    if (!decision.finished) {
      if (decision.reason != 'too-early') {
        unawaited(_recoverFalseVodEnd(decision.reason));
      }
      return;
    }
    unawaited(_onVodCompleted(item));
  }

  /// media_kit often skips `completed` after a resume seek (Continue watching).
  /// Mirror [VideoPlayerEngine]'s near-end heuristic so next-episode still runs.
  void _maybeCompleteVodNearEnd(Duration position, Duration duration) {
    if (_currentAd != null) return;
    final item = _item;
    if (item == null || item.isLive) return;
    if (_dvrStart != null) return;
    if (_advancingEpisode) return;
    if (_handledVodCompletionId == item.id) return;
    final decision = _vodEndDecision(
      position: position,
      engineDuration: duration,
    );
    if (!decision.finished) return;
    JavpLog.i(
      'play',
      'near-end item=${item.id} pos=${position.inSeconds}s '
          'engine=${duration.inSeconds}s reason=${decision.reason}',
    );
    unawaited(_onVodCompleted(item));
  }

  ({bool finished, String reason}) _vodEndDecision({
    Duration? position,
    Duration? engineDuration,
    bool eofReached = false,
  }) {
    final health = _torrents.activeHealth();
    return decideVodEnd(
      position: position ?? _position,
      engineDuration: engineDuration ?? _engineDuration,
      catalogDuration: _vodRuntimeHint ?? _item?.duration,
      buffering: _engineBuffering,
      // No sample yet on an active torrent: treat as incomplete so a truncated
      // HTTP window cannot look like 100% of a short demuxer duration.
      torrentIncomplete: health?.fileIncomplete ?? _torrents.hasActivePlayback,
      torrentStreamBuffering: health?.streamBuffering ?? false,
      torrentReadHead: health?.readHead ?? 0,
      torrentFileSize: health?.fileSize ?? 0,
      eofReached: eofReached,
    );
  }

  void _noteLongerVodRuntime(Duration duration) {
    if (duration.inMilliseconds <= 0) return;
    final hint = _vodRuntimeHint;
    if (hint == null || duration > hint) {
      _vodRuntimeHint = duration;
    }
  }

  Future<void> _recoverFalseVodEnd(String reason) async {
    if (_advancingEpisode || _opening || _retuneDepth > 0) return;
    final now = DateTime.now();
    final last = _lastFalseEofRecoverAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    if (last != null && now.difference(last) > const Duration(seconds: 30)) {
      _falseEofRecoverCount = 0;
    }
    _lastFalseEofRecoverAt = now;
    _falseEofRecoverCount++;
    if (_falseEofRecoverCount > 6) {
      JavpLog.w(
        'play',
        'eof recover gave up after $_falseEofRecoverCount ($reason)',
      );
      return;
    }
    JavpLog.w('play', 'eof recover seek+unpause ($reason)');
    try {
      final pos = _position;
      if (pos > Duration.zero) {
        await seekTo(pos);
      }
      // `play()` after completed restarts at 0 — only unpause.
      if (AppCapabilities.usesMediaKit) {
        await _mpvSetPaused(false);
      } else {
        await _vp?.play();
      }
    } catch (e) {
      JavpLog.w('play', 'eof recover failed', error: e);
    }
  }

  void _onPositionTick(Duration position, Duration duration) {
    _position = position;
    if (_currentAd != null) {
      if (duration > Duration.zero) _duration = duration;
      _fireAdProgress(position, duration);
      _schedulePositionUiNotify();
      return;
    }
    _maybeStartMidroll(position, duration);
    _lastContentPosition = position;
    if (_item == null) return;
    if (!_item!.isLive || _dvrStart != null) {
      if (duration.inMilliseconds > 0) {
        final progress = position.inMilliseconds / duration.inMilliseconds;
        if (progress > 0) {
          final second = position.inSeconds;
          if (second > 0 && second % 5 == 0 && second != _lastSavedSecond) {
            _lastSavedSecond = second;
            if (_dvrStart != null) {
              unawaited(_persistDvrProgress(clipProgress: progress));
            } else if (!_item!.isLive) {
              final clipDur = duration.inMilliseconds > 0 ? duration : null;
              if (clipDur != null) {
                final existing = _item!.duration;
                if (existing == null ||
                    clipDur.inMilliseconds > existing.inMilliseconds + 500) {
                  _item = _item!.copyWith(duration: clipDur);
                  _noteLongerVodRuntime(clipDur);
                }
              }
              unawaited(
                library.recordProgress(_item!, progress, duration: clipDur),
              );
              _reportServerProgress(isPaused: false);
              if (progress >= 0.05 && _item!.isEpisode) {
                unawaited(_maybeDownloadAhead(_item!));
              }
            }
          }
        }
        if (_dvrStart == null && !_item!.isLive) {
          _maybeCompleteVodNearEnd(position, duration);
        }
      }
    } else if (_nativeHlsDvrEnabled) {
      unawaited(
        _snapRateToRealtimeIfNeeded(reason: 'native hls dvr caught up'),
      );
    }
    // Position ticks are ~30–60 Hz; MiniPlayer/Player rebuilds must not be.
    _schedulePositionUiNotify();
  }

  PipService get pip => _pip;
  MediaItem? get item => _item;
  MediaItem? get liveChannel =>
      _liveChannel ?? (_item?.isLive == true ? _item : null);
  bool get hasSession => _item != null;

  /// Attach a session without opening an engine (widget tests for mini chrome).
  @visibleForTesting
  void debugAttachSession(MediaItem item, {bool minimized = true}) {
    _adoptVolumeBoostScope(item);
    _item = item;
    _minimized = minimized;
    _expanded = !minimized;
    notifyListeners();
  }

  Future<void> _maybeDownloadAhead(MediaItem item) async {
    await library.enqueueDownloadAhead(item);
  }

  /// Next episode in the series when watching an episode (prefetched).
  MediaItem? get nextEpisode => _nextEpisode;

  /// Previous episode in the series when watching an episode (prefetched).
  MediaItem? get previousEpisode => _previousEpisode;

  Future<void> _refreshAdjacentEpisodes() async {
    final item = _item;
    if (item == null || !item.isEpisode) {
      if (_nextEpisode != null || _previousEpisode != null) {
        _nextEpisode = null;
        _previousEpisode = null;
        notifyListeners();
      }
      return;
    }
    final results = await Future.wait([
      library.previousEpisodeItem(item),
      library.nextEpisodeItem(item),
    ]);
    if (_item?.id != item.id) return;
    final prev = results[0];
    final next = results[1];
    final changed =
        _previousEpisode?.id != prev?.id ||
        _nextEpisode?.id != next?.id ||
        (_previousEpisode == null) != (prev == null) ||
        (_nextEpisode == null) != (next == null);
    _previousEpisode = prev;
    _nextEpisode = next;
    if (changed) notifyListeners();
  }

  /// Play the previous episode when available. Returns false if there is none.
  Future<bool> playPreviousEpisode() async {
    final current = _item;
    var prev = _previousEpisode;
    if (prev == null && current != null && current.isEpisode) {
      prev = await library.previousEpisodeItem(current);
      _previousEpisode = prev;
    }
    if (prev == null) return false;
    await open(prev, expand: isExpanded || !isMinimized);
    return true;
  }

  /// Play the next episode when available. Returns false if there is none.
  Future<bool> playNextEpisode() async {
    final current = _item;
    var next = _nextEpisode;
    if (next == null && current != null && current.isEpisode) {
      next = await library.nextEpisodeItem(current);
      _nextEpisode = next;
    }
    if (next == null) return false;
    if (current != null) {
      await _maybeRemoveDownloadAfterAdvancing(current);
    }
    await open(next, expand: isExpanded || !isMinimized);
    return true;
  }

  /// Ordered live channel list for CH± / digit zap on Android TV.
  List<MediaItem> _liveZapList = const [];

  List<MediaItem> get liveZapList => _liveZapList;

  void setLiveZapList(List<MediaItem> channels) {
    _liveZapList = List<MediaItem>.unmodifiable(channels);
  }

  int get liveZapIndex {
    final current = liveChannel ?? _item;
    if (current == null || _liveZapList.isEmpty) return -1;
    return _liveZapList.indexWhere(
      (c) =>
          c.id == current.id ||
          (c.streamId != null &&
              c.streamId == current.streamId &&
              c.sourceId == current.sourceId),
    );
  }

  Future<bool> zapLiveRelative(int delta) async {
    if (_liveZapList.isEmpty || delta == 0) return false;
    final wrapped = liveZapRelativeIndex(
      length: _liveZapList.length,
      currentIndex: liveZapIndex,
      delta: delta,
    );
    final channel = _liveZapList[wrapped];
    // Stay in-place — TV Live overlay (and any future shell) owns the chrome.
    await open(library.resolveLiveChannel(channel), expand: false);
    return true;
  }

  Future<bool> zapLiveByIndex(int oneBasedIndex) async {
    if (oneBasedIndex < 1 || oneBasedIndex > _liveZapList.length) {
      return false;
    }
    final channel = _liveZapList[oneBasedIndex - 1];
    await open(library.resolveLiveChannel(channel), expand: false);
    return true;
  }

  /// Digit entry: prefer a channel whose [MediaItem.channelId] / [streamId]
  /// equals [number], otherwise fall back to 1-based list index.
  Future<bool> zapLiveByNumber(int number) async {
    final channel = resolveLiveZapNumber(_liveZapList, number);
    if (channel == null) return false;
    await open(library.resolveLiveChannel(channel), expand: false);
    return true;
  }

  /// Resolve digit entry against the current zap list (metadata, then index).
  MediaItem? liveZapChannelForNumber(int number) =>
      resolveLiveZapNumber(_liveZapList, number);

  double _sessionProgress(MediaItem item) {
    final durMs = _duration.inMilliseconds;
    if (durMs > 0 && _item?.id == item.id) {
      return (_position.inMilliseconds / durMs).clamp(0.0, 1.0);
    }
    return item.progress.clamp(0.0, 1.0);
  }

  /// Drop the offline copy when leaving an episode for the next one, if it was
  /// actually watched (≥80%) or finished. Skips early accidental skips.
  Future<void> _maybeRemoveDownloadAfterAdvancing(
    MediaItem item, {
    bool requireWatched = true,
  }) async {
    if (!library.downloadSettings.removeAfterWatch) return;
    final progress = _sessionProgress(item);
    if (requireWatched && progress < 0.8) return;
    await library.recordProgress(item, progress);
    await library.scheduleRemoveDownloadAfterWatch(
      item.copyWith(progress: progress),
    );
  }

  Future<void> _onVodCompleted(MediaItem item) async {
    if (_advancingEpisode) return;
    if (_handledVodCompletionId == item.id) return;
    final posts = _vastSchedule?.postrolls ?? const <VastLinearAd>[];
    if (!_postrollsPlayed && posts.isNotEmpty) {
      _postrollsPlayed = true;
      _pendingAfterAds = _PendingAfterAds(
        item: item,
        start: null,
        seekResumeProgress: null,
        epoch: _openEpoch,
        thenComplete: true,
      );
      final ok = await _beginAdPod(posts);
      if (ok) return;
      _pendingAfterAds = null;
    }
    _handledVodCompletionId = item.id;
    JavpLog.i(
      'play',
      'vod-complete item=${item.id} episode=${item.isEpisode} '
          'pos=${_position.inSeconds}s',
    );
    await library.recordProgress(item, 1.0);
    final duration = _duration > Duration.zero ? _duration : item.duration;
    unawaited(
      library.reportServerProgress(
        item,
        position: duration ?? _position,
        isPaused: false,
        duration: duration,
        stopped: true,
      ),
    );
    await _maybeRemoveDownloadAfterAdvancing(
      item.copyWith(progress: 1.0),
      requireWatched: false,
    );
    if (!item.isEpisode) return;
    final next = _nextEpisode ?? await library.nextEpisodeItem(item);
    if (next == null) {
      JavpLog.i('play', 'vod-complete no-next item=${item.id}');
      return;
    }
    JavpLog.i('play', 'advance-next from=${item.id} to=${next.id}');
    // Finished episode is progress 1.0 (dropped from Continue watching). Seed
    // the next one immediately so the show stays on Home even if auto-advance
    // is skipped or the user leaves before the next episode records ticks.
    await library.seedContinueWatchingNext(next);
    if (_item?.id != item.id) return;
    _advancingEpisode = true;
    try {
      await open(next, expand: _expanded || !_minimized);
    } finally {
      _advancingEpisode = false;
    }
  }

  bool get isMinimized => _minimized && hasSession && !isInPip;
  bool get isExpanded => _expanded && hasSession;

  /// Fullscreen cinema chrome. When false, the player uses a
  /// watch + browse layout (video + details / suggestions).
  bool get cinemaMode => _cinemaMode;

  VideoAspectMode get videoAspectMode => _videoAspectMode;

  /// Decoded frame size for [VideoAspectLayout]. Falls back to 16×9.
  int get videoFrameWidth => _pipAspect().$1;

  int get videoFrameHeight => _pipAspect().$2;

  VideoDeinterlaceMode get deinterlaceMode => _deinterlaceMode;

  bool get showStreamStats => _showStreamStats;

  /// Whether the non-cinema browse panel (channels / details) is hidden.
  bool get browsePanelCollapsed => _browsePanelCollapsed;
  bool get isCasting => library.cast.isCasting;
  bool get playing => library.cast.isCasting
      ? library.cast.remotePlaying
      : (_playingOverride ?? _enginePlaying);

  double get playbackRate =>
      isCasting ? library.cast.remotePlaybackRate : _engineRate;

  Future<void> setPlaybackRate(double rate) async {
    if (isCasting) {
      await library.cast.setPlaybackRate(rate);
      return;
    }
    await _engineSetRate(rate);
  }

  MediaSegmentBundle? _skipSegments;
  String? _skipSegmentsItemId;
  bool _autoSkippedSegment = false;

  MediaSegment? get activeSkipSegment {
    if (!isCasting) return null;
    final item = _item;
    if (item == null || item.isLive) return null;
    return _skipSegments?.activeAt(position);
  }

  Future<void> skipActiveSegment() async {
    final seg = activeSkipSegment;
    if (seg == null) return;
    final target = seg.end ?? seg.start + const Duration(seconds: 1);
    await seekTo(target);
  }

  Future<void> _ensureSkipSegments() async {
    final item = _item;
    if (item == null || item.isLive) {
      _skipSegments = null;
      _skipSegmentsItemId = null;
      return;
    }
    if (_skipSegmentsItemId == item.id && _skipSegments != null) return;
    _skipSegmentsItemId = item.id;
    _autoSkippedSegment = false;
    try {
      _skipSegments = await library.segmentsFor(item);
    } catch (_) {
      _skipSegments = const MediaSegmentBundle(key: 'unknown');
    }
  }

  Future<void> _maybeAutoSkipCastSegment() async {
    if (!isCasting) return;
    await _ensureSkipSegments();
    final active = activeSkipSegment;
    if (active == null) {
      _autoSkippedSegment = false;
      return;
    }
    final settings = library.skipSettings;
    final shouldAuto = switch (active.type) {
      MediaSegmentType.intro => settings.autoSkipIntro,
      MediaSegmentType.recap => settings.autoSkipRecap,
      MediaSegmentType.credits => settings.autoSkipCredits,
      MediaSegmentType.preview => false,
    };
    if (!shouldAuto || _autoSkippedSegment) return;
    final target = active.end;
    if (target == null) return;
    _autoSkippedSegment = true;
    await seekTo(target);
  }

  bool get isInPip => _pip.isInPip;

  /// Preset sleep durations offered in player settings (plus Off).
  static const sleepTimerPresets = <Duration>[
    Duration(minutes: 15),
    Duration(minutes: 20),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(minutes: 60),
  ];

  /// Wall-clock end of the active sleep timer, if any.
  DateTime? get sleepEndsAt => _sleepEndsAt;

  /// Originally requested sleep duration (for settings highlight).
  Duration? get sleepDuration => _sleepDuration;

  /// Remaining time until sleep fires; `null` when inactive.
  Duration? get sleepRemaining {
    final end = _sleepEndsAt;
    if (end == null) return null;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get hasSleepTimer => _sleepEndsAt != null;

  /// Latched when the sleep timer pauses playback; clear via [acknowledgeSleepFired].
  bool get sleepTimerFired => _sleepFiredFlag;

  void acknowledgeSleepFired() {
    if (!_sleepFiredFlag) return;
    _sleepFiredFlag = false;
    notifyListeners();
  }

  /// Arm a sleep timer that pauses playback when it elapses.
  ///
  /// Survives minimize / PiP (lives on the session). Pass `null` or [Duration.zero]
  /// to clear. Does not stop the session — same pause path as the play button.
  void setSleepTimer(Duration? duration) {
    _clearSleepTimer(notify: false);
    _sleepFiredFlag = false;
    if (duration == null || duration <= Duration.zero) {
      notifyListeners();
      return;
    }
    final end = DateTime.now().add(duration);
    _sleepEndsAt = end;
    _sleepDuration = duration;
    _sleepTimer = Timer(duration, _onSleepTimerFired);
    // Refresh chrome countdown without waking every second.
    _sleepTickTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_sleepEndsAt == null) return;
      notifyListeners();
    });
    notifyListeners();
  }

  void clearSleepTimer() => setSleepTimer(null);

  void _clearSleepTimer({bool notify = true}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTickTimer?.cancel();
    _sleepTickTimer = null;
    _sleepEndsAt = null;
    _sleepDuration = null;
    if (notify) notifyListeners();
  }

  void _onSleepTimerFired() {
    _sleepTimer = null;
    _sleepTickTimer?.cancel();
    _sleepTickTimer = null;
    _sleepEndsAt = null;
    _sleepDuration = null;
    _sleepFiredFlag = true;
    // Pause in place — do not tear down PiP / mini / live session.
    if (_enginePlaying) {
      unawaited(togglePlayPause());
    } else {
      notifyListeners();
    }
  }

  bool get canEnterPip =>
      AppCapabilities.pictureInPicture &&
      _pip.isSupported &&
      hasSession &&
      !isInPip;
  String? get error => _error;
  Duration get position =>
      library.cast.isCasting ? library.cast.remotePosition : _position;
  Duration get duration {
    if (library.cast.isCasting && library.cast.remoteDuration > Duration.zero) {
      return library.cast.remoteDuration;
    }
    return _duration;
  }

  bool get buffering =>
      library.cast.isCasting ? library.cast.remoteBuffering : _engineBuffering;

  /// Jellyfin / Emby / Plex open is still spinning — offer a lower preset.
  bool get suggestLowerQuality => _suggestLowerQuality;

  /// Active media-server transcoder preset for the current item.
  MediaServerStreamQuality get mediaServerStreamQuality {
    final item = _item;
    if (item == null) return library.mediaServerStreamQuality;
    final named = MediaServerStreamQuality.values.asNameMap()[item.resolution];
    return named ?? library.mediaServerStreamQuality;
  }

  /// Next lower preset when [suggestLowerQuality] / error recovery applies.
  MediaServerStreamQuality? get nextLowerMediaServerQuality =>
      mediaServerStreamQuality.lowerQuality;

  /// Show the media-server bitrate presets in the in-player settings menu.
  bool get canPickMediaServerQuality {
    final item = _item;
    if (item == null) return false;
    return _isMediaServerPlayback(item);
  }

  /// Leave should tear down the session instead of docking a mini player.
  ///
  /// A failed open or a stream that never produced a picture has nothing to
  /// keep playing in the dock — and minimize-during-open used to trap the
  /// user on a spinner they could not dismiss.
  bool get shouldAbandonSessionOnLeave =>
      _error != null ||
      _opening ||
      _awaitingInitialPlayback ||
      _resolvingTorrent;

  /// Initial open, DVR swap, seek, or mid-stream rebuffer — show the player spinner.
  ///
  /// Includes [_awaitingInitialPlayback] so torrent / slow HTTP opens keep the
  /// spinner after [_opening] clears until the engine actually starts playing
  /// (the torrent engine can hand back a URL before peers have filled the buffer).
  ///
  /// Minimize / texture reparent can miss `buffering=false`. Once the engine
  /// is playing without buffering, drop the overlay even if the awaiting flag
  /// stuck — otherwise the spinner sits on the mini dock forever.
  ///
  /// Uses [playing] (pause override included) so a pause click drops the
  /// badge before libmpv ACKs — it often reports buffering while idle.
  bool get isLoading => playerLoadingOverlayVisible(
    hasError: _error != null,
    opening: _opening,
    retuning: _retuneDepth > 0,
    resolvingTorrent: _resolvingTorrent,
    awaitingInitialPlayback: _awaitingInitialPlayback,
    dvrBusy: _dvrBusy,
    seekBusy: _seekBusy,
    engineBuffering: _engineBuffering,
    enginePlaying: playing,
  );

  /// True while [open] / decoder reload is still attaching media (not mid-stream buffer).
  bool get isOpening => _opening;

  /// Magnet / .torrent metadata still resolving (before local HTTP URL).
  bool get isResolvingTorrent => _resolvingTorrent && _error == null;

  /// Magnet / .torrent still resolving or waiting for first frames.
  bool get isPreparingTorrent {
    if (_error != null || (!_opening && !_awaitingInitialPlayback)) {
      return false;
    }
    if (_resolvingTorrent) return true;
    final item = _item;
    if (item == null) return false;
    return item.origin == MediaOrigin.torrent ||
        looksLikeTorrentPlayUrl(item.playUrl);
  }

  /// Radio / Icecast / progressive audio with no video plane.
  ///
  /// Prefers the catalog [MediaItem.isAudioOnly] tag; otherwise infers from
  /// demuxer tracks once they settle (extensionless live mounts).
  bool get isAudioOnly {
    final item = _item ?? _liveChannel;
    if (item != null) {
      if (item.isAudioOnly) return true;
      if (item.isLive && looksLikeAudioOnlyUrl(item.playUrl)) return true;
    }
    return _demuxerLooksAudioOnly;
  }

  bool get _demuxerLooksAudioOnly {
    if (!hasSession || _opening) return false;
    if (AppCapabilities.usesVideoPlayerBackend) {
      final size = _vp?.controller?.value.size;
      if (size != null && size.width > 0 && size.height > 0) return false;
      return (_item?.isLive == true) && (_enginePlaying || _engineBuffering);
    }
    final player = _player;
    if (player == null) return false;
    final w = player.state.width ?? 0;
    final h = player.state.height ?? 0;
    if (w > 0 && h > 0) return false;
    for (final t in player.state.tracks.video) {
      if (t.id == 'auto' || t.id == 'no') continue;
      if ((t.w ?? 0) > 0 && (t.h ?? 0) > 0) return false;
    }
    for (final t in player.state.tracks.audio) {
      if (t.id == 'auto' || t.id == 'no') continue;
      return true;
    }
    // Live mount finished opening with no video dimensions.
    return _item?.isLive == true && w == 0 && h == 0;
  }

  String? _programCacheKey;
  EpgProgram? _cachedCurrentProgram;
  EpgProgram? _cachedNextProgram;

  Future<void> open(
    MediaItem item, {
    bool expand = true,
    bool quiet = false,
  }) async {
    final parental = library.parentalLock;
    if (parental != null &&
        parental.isContentLocked &&
        parental.isItemHidden(item)) {
      JavpLog.i(
        'play',
        'open blocked by parental lock id=${item.id} '
            'sourceId=${item.sourceId}',
      );
      return;
    }
    final sourceId = item.sourceId;
    if (item.isLive &&
        sourceId != null &&
        sourceId.isNotEmpty &&
        sourceId != LibraryProvider.localSourceKey &&
        !library.sources.any((s) => s.id == sourceId)) {
      JavpLog.w(
        'play',
        'open skipped dropped source id=${item.id} sourceId=$sourceId '
            'origin=${item.origin.name}',
      );
      return;
    }
    final leaving = _item;
    // Resolution encodes media-server transcoder preset — treat as a switch
    // so “try lower quality” reloads even when id / playUrl stay empty.
    var switching =
        leaving?.id != item.id ||
        leaving?.playUrl != item.playUrl ||
        leaving?.resolution != item.resolution;
    final epoch = ++_openEpoch;
    // Snapshot so a minimize during awaits cannot be overwritten by expand:true.
    final miniGeneration = _miniGeneration;
    // Preserve mini dock on same-session reload (default expand:true otherwise
    // hides the bar while media_kit keeps playing with no /player route).
    final wantExpand = _resolveOpenExpand(
      expand: expand,
      leaving: leaving,
      item: item,
    );
    if (expand && !wantExpand) {
      JavpLog.i(
        'play',
        'open keep mini (same-session reload) '
            'id=${item.id} switching=$switching',
      );
    }

    // Mini-player / channel list may pass the live channel while a timeshift
    // clip for that stream is already playing. Don't rebuild from scratch —
    // jump to live when they asked for the live item, otherwise keep chrome.
    if (switching &&
        leaving != null &&
        _dvrStart != null &&
        item.isLive &&
        leaving.streamId != null &&
        leaving.streamId == item.streamId &&
        leaving.sourceId == item.sourceId) {
      _applyOpenChrome(expand: wantExpand, miniGeneration: miniGeneration);
      unawaited(
        _syncSystemChromeIfChanged(expanded: _expanded, minimized: _minimized),
      );
      unawaited(_syncPipAutoEnter());
      notifyListeners();
      // Explicit live MediaItem → live edge (channel row / On now). Expand
      // from the mini player pushes the catchup item instead, so it won't hit
      // this branch.
      await jumpToLive();
      return;
    }

    // History / Continue watching for the same channel while already in DVR —
    // seek to the saved wall-clock instead of reopening a new clip id.
    if (switching &&
        item.kind == MediaKind.catchup &&
        _dvrStart != null &&
        _liveChannel != null &&
        item.streamId != null &&
        item.streamId == _liveChannel!.streamId &&
        item.sourceId == _liveChannel!.sourceId) {
      _applyOpenChrome(expand: wantExpand, miniGeneration: miniGeneration);
      unawaited(
        _syncSystemChromeIfChanged(expanded: _expanded, minimized: _minimized),
      );
      unawaited(_syncPipAutoEnter());
      notifyListeners();
      final resumeAt = _resumeWallClockForCatchup(item);
      if (resumeAt != null) {
        await seekLiveDvrTo(resumeAt);
      }
      return;
    }

    // Same media already open — only refresh chrome / expand state. Re-parsing
    // catchup start or seeking to saved progress would jump the playhead.
    if (!switching && leaving != null) {
      _applyOpenChrome(expand: wantExpand, miniGeneration: miniGeneration);
      _error = null;
      unawaited(
        _syncSystemChromeIfChanged(expanded: _expanded, minimized: _minimized),
      );
      unawaited(_syncPipAutoEnter());
      notifyListeners();
      final shouldOpen = !_enginePlaying && _enginePosition == Duration.zero;
      if (!shouldOpen) {
        unawaited(_refreshAdjacentEpisodes());
        return;
      }
      // Engine was stopped at zero — fall through and reopen below.
      switching = true;
    }

    // One-time VPN/proxy tip before the first torrent peer session.
    if (library.offlinePlayPathFor(item) == null &&
        (item.origin == MediaOrigin.torrent ||
            looksLikeTorrentPlayUrl(item.playUrl))) {
      if (!AppCapabilities.torrents) {
        _error = kIsWeb
            ? WebAppLimitation.featureUnavailablePlaybackMessage('Torrents')
            : 'Torrents are not supported on this device.';
        _item = item;
        notifyListeners();
        return;
      }
      final proceed = await library.maybePromptTorrentVpnTip();
      if (!proceed) return;
      if (_isStaleOpen(epoch)) return;
    }

    // IPTV channel lists (.m3u) are not playable media — import as a source.
    if (M3uPlaylistIo.looksLikeChannelListUrl(item.playUrl)) {
      _error =
          'This URL is an M3U channel list, not a stream. '
          'Add it under Sources → M3U playlist '
          '(or use Add stream URL — playlists are imported automatically).';
      _item = item;
      notifyListeners();
      return;
    }

    // Spinner from here through prepare (torrent metadata / peers can take a
    // long time) — do not wait until after chrome sync / item assignment.
    // [quiet] is a quality retune: keep the last frame, skip the opening chrome.
    if (!quiet) {
      _opening = true;
      _error = null;
      notifyListeners();
    } else {
      _error = null;
    }

    // Persist the leaving title before we swap session state / stop the engine.
    if (switching && leaving != null) {
      if (_dvrStart != null) {
        await _flushProgress(item: leaving);
        if (_isStaleOpen(epoch)) return;
      } else {
        unawaited(_flushProgress(item: leaving));
      }
    }

    // Replaying cancels a pending remove-after-watch deletion.
    library.cancelScheduledRemoveDownload(item);
    // If something else opens the next episode (browse / deep link), treat it
    // like advancing so "remove after watching" still applies.
    if (switching &&
        !_advancingEpisode &&
        leaving != null &&
        leaving.isEpisode &&
        item.isEpisode &&
        library.downloadSettings.removeAfterWatch) {
      final knownNext = _nextEpisode;
      var isNext = knownNext != null && knownNext.id == item.id;
      if (!isNext && knownNext == null) {
        final resolved = await library.nextEpisodeItem(leaving);
        if (_isStaleOpen(epoch)) return;
        isNext = resolved != null && resolved.id == item.id;
      }
      if (isNext) {
        await _maybeRemoveDownloadAfterAdvancing(leaving);
        if (_isStaleOpen(epoch)) return;
      }
    }

    // Stop the previous stream before resolving URLs / opening the next one.
    if (switching && leaving != null) {
      _clearVastSession();
      await _clearEngineBeforeLoad(notify: !quiet);
      if (_isStaleOpen(epoch)) return;
    }

    _clearLivePausedAt();
    var playItem = item;
    // Apply preferred multi-URL quality (and warm the family cache for settings).
    if (item.isLive) {
      final family = library.liveFamilyKey(item);
      if (family != _liveQualityFallbackFamilyKey) {
        _triedLiveStreamIds.clear();
        _liveQualityFallbackFamilyKey = family;
      }
      playItem = await library.resolveLiveChannelAsync(item);
    } else if (!item.isLive &&
        item.kind != MediaKind.catchup &&
        item.serverItemId != null &&
        item.sourceId != null) {
      playItem = await library.mergeRemoteProgress(item);
    }
    if (_isStaleOpen(epoch)) return;
    // Continue-watching history rows are often snapshots — rebuild linkage so
    // next/previous episode prefetch and end-of-episode advance work.
    if (playItem.isEpisode) {
      playItem = await library.normalizeEpisodeForPlayback(playItem);
      if (_isStaleOpen(epoch)) return;
    }
    // Merge on-device history / download progress (common for offline episodes
    // whose download row still has progress=0).
    if (!playItem.isLive && playItem.kind != MediaKind.catchup) {
      playItem = _withLocalResume(playItem);
    }
    _item = playItem;
    library.setPlaybackActive(true);
    _adoptVolumeBoostScope(playItem);
    if (playItem.isLive) {
      _liveChannel = playItem;
      _dvrStart = null;
      _pendingNativeHlsLiveJoin = looksLikeHlsPlaylistUrl(playItem.playUrl);
    } else if (playItem.kind == MediaKind.catchup) {
      _pendingNativeHlsLiveJoin = false;
      // Offline catchup downloads play as finished recordings — no live DVR
      // session (EOF must not jump to live, minimize must stay mini).
      final offlinePath = library.offlinePlayPathFor(playItem);
      if (offlinePath != null) {
        _liveChannel = null;
        _dvrStart = null;
      } else {
        _dvrStart =
            _parseCatchupStart(playItem) ??
            (playItem.duration != null
                ? DateTime.now().subtract(playItem.duration!)
                : DateTime.now());
        // Keep the real live channel when already in-session (same stream).
        // Otherwise liveChannels may be empty under the live DB, and a bad
        // timeshift→live URL guess would make "Jump to live" restart catchup.
        final existing = _liveChannel;
        final sameStream =
            existing != null &&
            existing.isLive &&
            existing.streamId != null &&
            existing.streamId == playItem.streamId &&
            existing.sourceId == playItem.sourceId;
        if (!sameStream) {
          final matched = library.liveChannels.cast<MediaItem?>().firstWhere(
            (c) =>
                c?.streamId == playItem.streamId &&
                c?.sourceId == playItem.sourceId,
            orElse: () => null,
          );
          _liveChannel = matched ?? _asLiveChannel(playItem);
        }
      }
    } else {
      _pendingNativeHlsLiveJoin = false;
      _liveChannel = null;
      _dvrStart = null;
    }
    _applyOpenChrome(expand: wantExpand, miniGeneration: miniGeneration);
    _error = null;
    _lastSavedSecond = -1;
    if (switching) {
      _nextEpisode = null;
      _previousEpisode = null;
      _handledVodCompletionId = null;
      _vodRuntimeHint = playItem.duration;
      _lastFalseEofRecoverAt = null;
      _falseEofRecoverCount = 0;
    } else if (_vodRuntimeHint == null ||
        (playItem.duration != null && playItem.duration! > _vodRuntimeHint!)) {
      _vodRuntimeHint = playItem.duration ?? _vodRuntimeHint;
    }
    _rememberCurrentTracksForReload();
    _resetLanguagePreferenceSession(playItem);
    _beginAwaitingInitialPlayback(playItem);
    notifyListeners();

    unawaited(library.recordWatch(playItem));
    final guideChannel = _liveChannel;
    // Guide / quality family rebuild the browse panel. Skip while cinema so
    // a zap does not hitch the fullscreen texture; the panel warms on show.
    if (guideChannel != null && !_cinemaMode && !_browsePanelCollapsed) {
      unawaited(library.fetchChannelGuide(guideChannel));
      unawaited(library.qualityVariantsForAsync(guideChannel));
    }
    unawaited(
      _syncSystemChromeIfChanged(expanded: _expanded, minimized: _minimized),
    );
    unawaited(_syncPipAutoEnter());
    if (_isStaleOpen(epoch)) return;

    final resumeProgress =
        !playItem.isLive && playItem.progress > 0.02 && playItem.progress < 0.95
        ? playItem.progress
        : null;
    final knownDuration = playItem.duration;
    final start =
        resumeProgress != null &&
            knownDuration != null &&
            knownDuration.inMilliseconds > 0
        ? knownDuration * resumeProgress
        : null;
    // Online catchup opens at the resume wall clock; skip VOD progress seek.
    var seekResumeProgress = resumeProgress;
    final openWatch = Stopwatch()..start();
    var prepareMs = 0;
    var engineMs = 0;
    try {
      if (playItem.kind == MediaKind.catchup) {
        final offline = library.offlinePlayPathFor(playItem);
        if (offline != null) {
          await _torrents.stopActive(deleteFiles: false);
          if (_isStaleOpen(epoch)) return;
          final engine = Stopwatch()..start();
          await _openMedia(Media(offline, start: start), play: true);
          engineMs = engine.elapsedMilliseconds;
          if (_isStaleOpen(epoch)) return;
          await _applyCatalogTracks(playItem);
          await _maybeApplyLanguagePreferences(force: true);
        } else {
          // Open timeshift at the saved wall-clock resume point — not at
          // programme/segment start with a fragile VOD-style progress seek
          // (which often snaps back to clip start when duration is clamped).
          final channel = _liveChannel ?? playItem;
          final archive = library.resolveCatchupChannel(channel) ?? channel;
          final resumeAt = _resumeWallClockForCatchup(playItem);
          final openStart = resumeAt ?? _dvrStart ?? DateTime.now();
          final program = library.programAt(channel, at: openStart);
          final openDuration = _continuousTimeshiftDuration(start: openStart);
          JavpLog.i(
            'play',
            'catchup resume wall=${openStart.toIso8601String()} '
                'progress=${playItem.progress.toStringAsFixed(3)} '
                'programDur=${program?.duration.inSeconds ?? playItem.duration?.inSeconds}s '
                'clipDur=${openDuration.inSeconds}s',
          );
          final engine = Stopwatch()..start();
          final ok = await _openTimeshift(
            channel: archive,
            liveViewChannel: channel.isLive ? channel : _liveChannel,
            start: openStart,
            duration: openDuration,
            title: playItem.title,
            thumbnailUrl: program?.imageUrl ?? playItem.thumbnailUrl,
          );
          engineMs = engine.elapsedMilliseconds;
          if (_isStaleOpen(epoch) || !ok) return;
          // Already opened at the resume wall clock — do not VOD-seek.
          seekResumeProgress = null;
        }
      } else {
        if (await _maybeStartVast(
          playItem: playItem,
          start: start,
          seekResumeProgress: seekResumeProgress,
          epoch: epoch,
        )) {
          return;
        }
        final prepare = Stopwatch()..start();
        final prepared = await _preparePlayable(playItem);
        prepareMs = prepare.elapsedMilliseconds;
        if (_isStaleOpen(epoch)) return;
        playItem = prepared.item;
        _item = playItem;
        final engine = Stopwatch()..start();
        await _openMedia(
          Media(
            prepared.playUrl,
            start: start,
            httpHeaders: _headersForPlayUrl(
              prepared.playUrl,
              playItem.httpHeaders,
            ),
          ),
          play: true,
        );
        engineMs = engine.elapsedMilliseconds;
        if (_isStaleOpen(epoch)) return;
        _startPlexLiveKeepalive(playItem, prepared.playUrl);
        // Live IPTV: confirm demux before declaring success. Prefer/Auto can
        // pick a dead HD feed — fall back to the next sibling in the family.
        // Always await demux, including nested sibling opens; only the outer
        // walker cascades while [_liveQualityFallbackInFlight] is set.
        if (playItem.isLive) {
          final ok = await _awaitOpenOutcome(requireDemux: true);
          if (_isStaleOpen(epoch)) return;
          if (!ok) {
            if (_liveQualityFallbackInFlight) return;
            final fellBack = await _tryNextLiveQualitySibling(
              failed: playItem,
              expand: wantExpand,
            );
            if (fellBack || _isStaleOpen(epoch)) return;
          }
        }
        await _applyCatalogTracks(playItem);
        await _maybeApplyLanguagePreferences(force: true);
      }
      if (_isStaleOpen(epoch)) return;
      if (seekResumeProgress != null) {
        await _ensureResumedToProgress(seekResumeProgress, preferred: start);
      }
      final totalMs = openWatch.elapsedMilliseconds;
      final summary =
          'open in ${totalMs}ms kind=${playItem.kind.name} '
          'origin=${playItem.origin.name} prepare=$prepareMs engine=$engineMs';
      if (totalMs >= 3000) {
        JavpLog.w('play', summary);
      } else {
        JavpLog.i('play', summary);
      }
    } catch (e) {
      if (_isStaleOpen(epoch)) return;
      if (e is UnsupportedDrmException && e.playUrl != null) {
        _activePlayUrl = e.playUrl;
      }
      if (playItem.isLive) {
        if (_liveQualityFallbackInFlight) {
          // Nested sibling open — surface the error for the outer walker.
          _error = surfacePlayerError(e);
          return;
        }
        final fellBack = await _tryNextLiveQualitySibling(
          failed: playItem,
          expand: wantExpand,
        );
        if (fellBack || _isStaleOpen(epoch)) return;
      }
      _error = surfacePlayerError(e);
      _maybeSuggestLowerQualityOnFailure(playItem);
      JavpLog.w(
        'play',
        'open failed after ${openWatch.elapsedMilliseconds}ms '
            'kind=${playItem.kind.name} origin=${playItem.origin.name} '
            'prepare=$prepareMs engine=$engineMs',
        error: e,
      );
    } finally {
      if (!_isStaleOpen(epoch)) {
        if (!quiet) _opening = false;
        notifyListeners();
      }
    }
    if (!_isStaleOpen(epoch)) {
      unawaited(_refreshAdjacentEpisodes());
      if (_error == null &&
          (library.cast.isCasting || library.cast.preferredTarget != null)) {
        unawaited(_recastOpenSession());
      }
    }
  }

  /// Send the newly opened URL to the active (or preferred) Cast device.
  Future<void> _recastOpenSession() async {
    if (_item == null) return;
    await _enginePause();
    await castCurrent();
  }

  MediaItem _withLocalResume(MediaItem item) {
    final snap = library.resumeSnapshotFor(item);
    if (snap == null) return item;
    final progress = item.progress > 0.02 && item.progress < 0.95
        ? item.progress
        : snap.progress;
    final duration = item.duration ?? snap.duration;
    if (progress == item.progress && duration == item.duration) return item;
    return item.copyWith(progress: progress, duration: duration);
  }

  /// Ensure playhead lands on saved progress (Media.start can be ignored by
  /// some demuxers; duration may only be known after open).
  Future<void> _ensureResumedToProgress(
    double progress, {
    Duration? preferred,
  }) async {
    if (progress <= 0.02 || progress >= 0.95) return;

    Duration? target = preferred;
    if (target == null || target.inMilliseconds <= 0) {
      target = await _waitForResumeTarget(progress);
    }
    if (target == null) return;

    // Already close enough (Media.start worked).
    final pos = _enginePosition;
    if ((pos - target).abs() < const Duration(seconds: 3)) {
      _position = pos;
      return;
    }
    await _seekWhenReady(target);
  }

  Future<Duration?> _waitForResumeTarget(double progress) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      final dur = _engineDuration;
      if (dur.inMilliseconds > 0) {
        final item = _item;
        if (item != null &&
            (item.duration == null ||
                item.duration!.inMilliseconds != dur.inMilliseconds)) {
          _item = item.copyWith(duration: dur);
        }
        return dur * progress;
      }
      if (_enginePlaying || _engineBuffering) {
        // Still probing duration — keep waiting briefly.
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return null;
  }

  Future<void> _seekWhenReady(Duration position) async {
    final safe = position.isNegative ? Duration.zero : position;
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      final ready =
          _engineDuration.inMilliseconds > 0 ||
          _enginePlaying ||
          _engineBuffering;
      if (ready) {
        try {
          await _engineSeek(safe);
          _position = safe;
          notifyListeners();
          return;
        } catch (_) {
          // Demuxer not seekable yet — retry.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    try {
      await _seekInClip(safe);
    } catch (_) {}
  }

  void _onEngineBufferingChanged(bool buffering) {
    if (_seekBusy) {
      if (buffering) {
        _sawBufferingDuringSeek = true;
      } else if (_sawBufferingDuringSeek) {
        _clearSeekBusy();
        return;
      }
    }
    if (buffering) {
      unawaited(_snapRateToRealtimeIfNeeded(reason: 'live-edge buffering'));
    } else {
      _maybeMarkPlaybackActuallyStarted();
    }
    // Buffering edges should show/hide the spinner promptly (not position-throttled).
    notifyListeners();
  }

  /// libmpv sets `playing=true` before the first byte arrives. Treat playback
  /// as started only once frames can actually move, and never dismiss a hard
  /// open failure just because the engine claimed it was playing.
  void _maybeMarkPlaybackActuallyStarted() {
    if (!_enginePlaying || _engineBuffering) return;
    _onInitialPlaybackStarted();
    if (_error == null || isFatalStreamOpenFailure(_error!)) return;
    _error = null;
    notifyListeners();
  }

  void _beginSeekBusy() {
    _seekBusyTimer?.cancel();
    _seekBusy = true;
    _sawBufferingDuringSeek = false;
    notifyListeners();
  }

  void _finishSeekBusy() {
    _seekBusyTimer?.cancel();
    // Seek often returns before the engine flips into buffering — wait briefly.
    _seekBusyTimer = Timer(const Duration(milliseconds: 150), () {
      if (!_seekBusy) return;
      if (_engineBuffering || _sawBufferingDuringSeek) {
        if (_engineBuffering) _sawBufferingDuringSeek = true;
        // Cleared when buffering ends; safety net if the flag sticks.
        _seekBusyTimer = Timer(const Duration(seconds: 15), _clearSeekBusy);
        return;
      }
      // Cached / instant seek — drop the spinner.
      _clearSeekBusy();
    });
  }

  void _clearSeekBusy() {
    _seekBusyTimer?.cancel();
    _seekBusyTimer = null;
    if (!_seekBusy && !_sawBufferingDuringSeek) return;
    _seekBusy = false;
    _sawBufferingDuringSeek = false;
    notifyListeners();
  }

  /// Seek within the open clip and keep [_position] in sync immediately.
  Future<void> _seekInClip(Duration position) async {
    final safe = position.isNegative ? Duration.zero : position;
    if (library.cast.isCasting) {
      _position = safe;
      notifyListeners();
      await library.cast.seek(safe);
      return;
    }
    _beginSeekBusy();
    try {
      await _engineSeek(safe);
      _position = safe;
      notifyListeners();
    } finally {
      _finishSeekBusy();
    }
  }

  Tracks get tracks => _player?.state.tracks ?? const Tracks();
  Track get track => _player?.state.track ?? Track();

  /// Embedded demuxer tracks plus catalog-provided external subtitle URIs.
  ///
  /// Does not include libmpv `auto`/`no`, or other encodes of the same title —
  /// those belong in Version / Quality.
  List<SubtitleTrack> get selectableSubtitleTracks {
    if (!AppCapabilities.usesMediaKit || _player == null) return const [];
    final seen = <String>{};
    final out = <SubtitleTrack>[];
    for (final t in _player!.state.tracks.subtitle) {
      if (TrackLanguage.isMetaTrackId(t.id)) continue;
      if (seen.add(t.id)) out.add(t);
    }
    for (final s in _item?.subtitles ?? const <ExternalSubtitle>[]) {
      if (s.url.isEmpty) continue;
      final track = SubtitleTrack.uri(
        s.url,
        title: s.displayLabel,
        language: s.language,
      );
      if (seen.add(track.id)) out.add(track);
    }
    return out;
  }

  List<AudioTrack> get selectableAudioTracks {
    if (!AppCapabilities.usesMediaKit || _player == null) return const [];
    final seen = <String>{};
    final out = <AudioTrack>[];
    for (final t in _player!.state.tracks.audio) {
      if (TrackLanguage.isMetaTrackId(t.id)) continue;
      if (seen.add(t.id)) out.add(t);
    }
    for (final a in _item?.audioTracks ?? const <ExternalAudio>[]) {
      if (a.url.isEmpty) continue;
      final track = AudioTrack.uri(
        a.url,
        title: a.displayLabel,
        language: a.language,
      );
      if (seen.add(track.id)) out.add(track);
    }
    return out;
  }

  /// Quality encodes for the open title (any source; player switches).
  List<MediaItem> get editionQualitySiblings {
    final item = _item;
    if (item == null || item.isEpisode || item.isLive) return const [];
    return library
        .vodFamilyLayoutFor(item)
        .qualityChoices(preferredLangs: _contentLocaleCodes, matchLangOf: item);
  }

  Future<void> switchEditionKeepingPosition(MediaItem next) =>
      _openEditionKeepingPosition(next);

  Future<void> _openEditionKeepingPosition(MediaItem next) async {
    _rememberCurrentTracksForReload();
    final pos = _position;
    final dur = duration;
    var play = next;
    if (dur.inMilliseconds > 0 && pos.inMilliseconds > 2000) {
      final frac = (pos.inMilliseconds / dur.inMilliseconds).clamp(0.03, 0.94);
      play = next.copyWith(progress: frac);
    }
    await open(play, expand: true);
  }

  /// HLS / DASH renditions reported by the demuxer (excludes auto/no).
  List<VideoTrack> get demuxerVideoTracks {
    if (!AppCapabilities.usesMediaKit || _player == null) return const [];
    final out = <VideoTrack>[];
    for (final t in _player!.state.tracks.video) {
      if (t.id == 'auto' || t.id == 'no') continue;
      out.add(t);
    }
    out.sort((a, b) {
      final ah = a.h ?? 0;
      final bh = b.h ?? 0;
      if (ah != bh) return bh.compareTo(ah);
      final ab = a.bitrate ?? 0;
      final bb = b.bitrate ?? 0;
      return bb.compareTo(ab);
    });
    return out;
  }

  /// Quality choices for the player UI (parsed HLS variants or demuxer tracks).
  List<VideoTrack> get selectableVideoTracks {
    if (_hlsVariants.length > 1) {
      return [
        for (final v in _hlsVariants)
          VideoTrack(
            v.trackId,
            v.qualityLabel,
            null,
            w: v.width,
            h: v.height,
            bitrate: v.bandwidth,
          ),
      ];
    }
    return demuxerVideoTracks;
  }

  /// Currently selected quality row id (`auto` or a track / `hls:` id).
  String get selectedVideoTrackId {
    if (_hlsVariants.length > 1) {
      if (_hlsQualityAuto) return 'auto';
      final locked = _hlsLockedVariantUrl;
      if (locked != null) return '$_hlsTrackPrefix$locked';
      return 'auto';
    }
    return track.video.id;
  }

  bool isVideoTrackSelected(VideoTrack track) =>
      track.id == selectedVideoTrackId;

  /// True when Off / at least one real subtitle track is a meaningful choice.
  bool get hasSelectableSubtitles => selectableSubtitleTracks.isNotEmpty;

  /// True when more than one audio track can actually be picked.
  bool get hasSelectableAudio => selectableAudioTracks.length > 1;

  /// True when the stream exposes multiple adaptive video renditions.
  bool get hasSelectableVideo => selectableVideoTracks.length > 1;

  Future<void> setAudioTrack(AudioTrack track, {bool fromUser = true}) async {
    if (track.id.startsWith(_editionAudioPrefix)) {
      final lang = track.id.substring(_editionAudioPrefix.length);
      final item = _item;
      if (item != null) {
        final next = await library.switchToLanguageEdition(
          current: item,
          lang: lang,
          audio: true,
        );
        if (next != null) {
          if (fromUser) {
            _userPickedAudio = true;
            _autoAudioApplied = true;
            _sessionAudio = SessionTrackPick(language: lang);
          }
          await _openEditionKeepingPosition(next);
          return;
        }
      }
    }
    if (!AppCapabilities.usesMediaKit || _player == null) return;
    await _player!.setAudioTrack(track);
    if (fromUser) {
      _userPickedAudio = true;
      _autoAudioApplied = true;
      _sessionAudio = TrackLanguage.sessionPickFromTrack(
        id: track.id,
        language: track.language,
        title: track.title,
        uri: track.uri,
      );
      unawaited(_rememberAudioPick(track));
    }
    notifyListeners();
  }

  Future<void> setVideoTrack(VideoTrack track, {bool fromUser = true}) async {
    if (_hlsVariants.length > 1) {
      if (track.id == 'auto') {
        await _setHlsQualityAuto();
        return;
      }
      if (track.id.startsWith(_hlsTrackPrefix)) {
        final url = track.id.substring(_hlsTrackPrefix.length);
        await _setHlsQualityLocked(url);
        return;
      }
    }
    if (!AppCapabilities.usesMediaKit || _player == null) return;
    await _player!.setVideoTrack(track);
    notifyListeners();
  }

  Future<void> setSubtitleTrack(
    SubtitleTrack track, {
    bool fromUser = true,
  }) async {
    if (track.id.startsWith(_editionSubPrefix)) {
      final lang = track.id.substring(_editionSubPrefix.length);
      final item = _item;
      if (item != null) {
        final next = await library.switchToLanguageEdition(
          current: item,
          lang: lang,
          audio: false,
        );
        if (next != null) {
          if (fromUser) {
            _userPickedSubtitle = true;
            _autoSubtitleApplied = true;
            _autoSubtitlePrimaryMatch = true;
            _sessionSubtitle = SessionTrackPick(language: lang);
          }
          await _openEditionKeepingPosition(next);
          return;
        }
      }
    }
    if (!AppCapabilities.usesMediaKit || _player == null) return;
    await _player!.setSubtitleTrack(track);
    if (fromUser) {
      _userPickedSubtitle = true;
      _autoSubtitleApplied = true;
      _autoSubtitlePrimaryMatch = true;
      _sessionSubtitle = TrackLanguage.sessionPickFromTrack(
        id: track.id,
        language: track.language,
        title: track.title,
        uri: track.uri,
      );
      unawaited(_rememberSubtitlePick(track));
    }
    // Track codec/URI may change native vs preset rendering.
    _captionStyleSignature = null;
    unawaited(_applyCaptionRenderingMode(_captionStyle));
    notifyListeners();
  }

  String _languageSessionKey(MediaItem item) {
    if (item.isLive || item.kind == MediaKind.catchup) {
      return 'live:${item.sourceId}:${item.streamId ?? item.id}';
    }
    if (item.isEpisode) {
      return 'ep:${item.seriesId ?? item.id}:${item.seasonNumber}:${item.episodeNumber}';
    }
    return library.canonicalVodGroupKey(item) ?? 'vod:${item.id}';
  }

  void _resetLanguagePreferenceSession(MediaItem item) {
    final key = _languageSessionKey(item);
    if (_langPrefsItemKey == key) return;
    _langPrefsItemKey = key;
    _autoSubtitleApplied = false;
    _autoSubtitlePrimaryMatch = false;
    _autoAudioApplied = false;
    _userPickedSubtitle = false;
    _userPickedAudio = false;
    _sessionSubtitle = null;
    _sessionAudio = null;
  }

  void _rememberCurrentTracksForReload() {
    if (_userPickedSubtitle &&
        (_sessionSubtitle == null || !_sessionSubtitle!.hasIdentity)) {
      final current = track.subtitle;
      _sessionSubtitle = TrackLanguage.sessionPickFromTrack(
        id: current.id,
        language: current.language,
        title: current.title,
        uri: current.uri,
      );
    }
    if (_userPickedAudio &&
        (_sessionAudio == null || !_sessionAudio!.hasIdentity)) {
      final current = track.audio;
      _sessionAudio = TrackLanguage.sessionPickFromTrack(
        id: current.id,
        language: current.language,
        title: current.title,
        uri: current.uri,
      );
    }
  }

  void _markLanguagePrefsDirtyForReload() {
    _autoSubtitleApplied = false;
    _autoSubtitlePrimaryMatch = false;
    _autoAudioApplied = false;
  }

  Future<void> _rememberSubtitlePick(SubtitleTrack track) async {
    final settings = library.trackLanguageSettings;
    if (!settings.rememberLastSubtitlePick) return;
    if (track.id == 'no' || track == SubtitleTrack.no()) {
      if (settings.subtitleLanguage == 'off') return;
      await library.saveTrackLanguageSettings(
        settings.copyWith(subtitleLanguage: 'off'),
      );
      return;
    }
    final code =
        TrackLanguage.normalize(track.language) ??
        TrackLanguage.normalize(track.title);
    if (code == null || code == settings.subtitleLanguage) return;
    await library.saveTrackLanguageSettings(
      settings.copyWith(subtitleLanguage: code),
    );
  }

  Future<void> _rememberAudioPick(AudioTrack track) async {
    final settings = library.trackLanguageSettings;
    if (!settings.rememberLastAudioPick) return;
    final code =
        TrackLanguage.normalize(track.language) ??
        TrackLanguage.normalize(track.title);
    if (code == null) return;
    if (settings.audioMode == AudioTrackMode.preferred &&
        code == settings.audioLanguage) {
      return;
    }
    await library.saveTrackLanguageSettings(
      settings.copyWith(
        audioMode: AudioTrackMode.preferred,
        audioLanguage: code,
      ),
    );
  }

  Future<void> _maybeApplyLanguagePreferences({bool force = false}) async {
    if (_player == null || _item == null) return;
    final settings = library.trackLanguageSettings;
    var changed = false;

    // Audio first so subtitle “only when foreign audio” can inspect the track.
    if (_userPickedAudio) {
      if (await _reapplySessionAudio()) changed = true;
    } else if (force || !_autoAudioApplied) {
      if (settings.audioMode == AudioTrackMode.original) {
        // Dual-audio releases often default to EN; prefer catalog original (e.g. ja).
        final hasOriginalHint = _item?.audioLanguages.isNotEmpty == true;
        if (!hasOriginalHint) {
          _autoAudioApplied = true;
        } else {
          final applied = await _applyOriginalAudio();
          if (applied) {
            _autoAudioApplied = true;
            changed = true;
            // Re-evaluate captions after switching to original (e.g. ja) —
            // an earlier pass may have locked Off from stale/default audio.
            if (!_userPickedSubtitle) {
              _autoSubtitleApplied = false;
              _autoSubtitlePrimaryMatch = false;
            }
          } else if (selectableAudioTracks.length > 1) {
            // Demuxer settled but no tagged match — keep stream default.
            _autoAudioApplied = true;
          }
          // 0–1 tracks: wait for a later tracks event before locking.
        }
      } else {
        final applied = await _applyPreferredAudio(settings);
        if (applied) {
          _autoAudioApplied = true;
          changed = true;
          if (!_userPickedSubtitle) {
            _autoSubtitleApplied = false;
            _autoSubtitlePrimaryMatch = false;
          }
        } else if (selectableAudioTracks.length > 1) {
          _autoAudioApplied = true;
        }
      }
    }

    // Keep retrying while we only have an English (or other) fallback — late
    // demuxer tracks for the device language often appear after the first event.
    if (_userPickedSubtitle) {
      if (await _reapplySessionSubtitle()) changed = true;
    } else if (force || !_autoSubtitleApplied || !_autoSubtitlePrimaryMatch) {
      final result = await _applyPreferredSubtitle(settings);
      if (result.applied) {
        _autoSubtitleApplied = true;
        _autoSubtitlePrimaryMatch = result.primaryMatch;
        changed = true;
      } else if (settings.subtitlesOff) {
        _autoSubtitleApplied = true;
        _autoSubtitlePrimaryMatch = true;
      }
      // Do not lock when tracks exist but none matched yet — metadata/tags
      // can arrive on a later tracks event.
    }

    if (changed) notifyListeners();
  }

  Future<bool> _reapplySessionSubtitle() async {
    final pick = _sessionSubtitle;
    if (pick == null || !pick.hasIdentity) return false;
    if (!AppCapabilities.usesMediaKit || _player == null) return false;
    final current = track.subtitle;
    if (TrackLanguage.trackMatchesSession(
      pick: pick,
      id: current.id,
      language: current.language,
      title: current.title,
    )) {
      return false;
    }
    if (pick.off) {
      try {
        await _player!.setSubtitleTrack(SubtitleTrack.no());
        _captionStyleSignature = null;
        unawaited(_applyCaptionRenderingMode(_captionStyle));
        return true;
      } catch (_) {
        return false;
      }
    }
    final tracks = selectableSubtitleTracks;
    final id = TrackLanguage.bestSessionTrackId(
      pick: pick,
      tracks: [
        for (final t in tracks)
          SessionTrackCandidate(id: t.id, language: t.language, title: t.title),
      ],
    );
    SubtitleTrack? match;
    if (id == 'no') {
      match = SubtitleTrack.no();
    } else if (id != null) {
      for (final t in tracks) {
        if (t.id == id) {
          match = t;
          break;
        }
      }
    }
    match ??= () {
      final uri = pick.uri?.trim();
      if (uri == null || uri.isEmpty) return null;
      return SubtitleTrack.uri(uri, title: pick.title, language: pick.language);
    }();
    if (match == null) return false;
    try {
      await _player!.setSubtitleTrack(match);
      _captionStyleSignature = null;
      unawaited(_applyCaptionRenderingMode(_captionStyle));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _reapplySessionAudio() async {
    final pick = _sessionAudio;
    if (pick == null || !pick.hasIdentity || pick.off) return false;
    if (!AppCapabilities.usesMediaKit || _player == null) return false;
    final current = track.audio;
    if (TrackLanguage.trackMatchesSession(
      pick: pick,
      id: current.id,
      language: current.language,
      title: current.title,
    )) {
      return false;
    }
    final tracks = selectableAudioTracks;
    final id = TrackLanguage.bestSessionTrackId(
      pick: pick,
      tracks: [
        for (final t in tracks)
          SessionTrackCandidate(id: t.id, language: t.language, title: t.title),
      ],
    );
    AudioTrack? match;
    if (id != null) {
      for (final t in tracks) {
        if (t.id == id) {
          match = t;
          break;
        }
      }
    }
    match ??= () {
      final uri = pick.uri?.trim();
      if (uri == null || uri.isEmpty) return null;
      return AudioTrack.uri(uri, title: pick.title, language: pick.language);
    }();
    if (match == null) return false;
    try {
      await _player!.setAudioTrack(match);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<String> get _contentLocaleCodes {
    final fromController = library.preferredContentLocales?.call();
    if (fromController != null && fromController.isNotEmpty) {
      return List<String>.from(fromController);
    }
    return const [];
  }

  String? get _uiLocaleCode {
    final raw = library.catalogLocale?.call().trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  /// Codes to try when picking a subtitle track.
  List<String> _subtitlePreferenceCodes(TrackLanguageSettings settings) {
    return TrackLanguage.preferenceCodes(
      settings.subtitleLanguage,
      contentLocales: _contentLocaleCodes,
      uiLocale: _uiLocaleCode,
    );
  }

  /// Languages the listener understands for auto-caption gating.
  ///
  /// Always derived from subtitle / content / UI / device locale — never from
  /// preferred audio (JP audio + FR captions is the common anime case).
  List<String> _spokenLanguagePreference(TrackLanguageSettings settings) {
    if (settings.subtitlesOff) return const [];
    // Explicit subtitle language is the strongest “I understand this” signal.
    if (settings.subtitleLanguage != 'auto') {
      return TrackLanguage.spokenPreferenceCodes(settings.subtitleLanguage);
    }
    return TrackLanguage.spokenPreferenceCodes(
      'auto',
      contentLocales: _contentLocaleCodes,
      uiLocale: _uiLocaleCode,
    );
  }

  /// True when the *playing* demuxer audio is already in [preferred].
  ///
  /// Catalog `audioLanguages` is intentionally ignored here — French VOSTFR
  /// rows are often tagged `fr` while the bitstream is Japanese.
  bool _audioMatchesPreferred(List<String> preferred) {
    if (preferred.isEmpty) return false;
    final current = track.audio;
    if (TrackLanguage.demuxerAudioMatchesSpoken(
      language: current.language,
      title: current.title,
      spokenPreferred: preferred,
      trackId: current.id,
    )) {
      return true;
    }
    final audios = selectableAudioTracks
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    if (audios.isEmpty) return false;
    AudioTrack? best = current.id.isNotEmpty
        ? audios.cast<AudioTrack?>().firstWhere(
            (t) => t?.id == current.id,
            orElse: () => null,
          )
        : null;
    best ??= audios.first;
    return TrackLanguage.demuxerAudioMatchesSpoken(
      language: best.language,
      title: best.title,
      spokenPreferred: preferred,
      trackId: best.id,
    );
  }

  /// When audio mode is “original”, prefer the catalog’s primary audio language
  /// (first `audioLanguages` entry) over a dual-audio file’s English default.
  ///
  /// Returns true when the session is on the original language (switched or
  /// already there), so callers can stop retrying.
  Future<bool> _applyOriginalAudio() async {
    final item = _item;
    if (item == null || item.audioLanguages.isEmpty) return false;
    final preferred = <String>[];
    for (final raw in item.audioLanguages) {
      final n = TrackLanguage.normalize(raw);
      if (n != null && !preferred.contains(n)) preferred.add(n);
    }
    if (preferred.isEmpty) return false;

    // Only the primary catalog language is “original”; later entries are dubs.
    final original = [preferred.first];

    final current = track.audio;
    if (TrackLanguage.score(
          language: current.language,
          title: current.title,
          preferred: original,
        ) >=
        10) {
      return true;
    }

    final tracks = selectableAudioTracks;
    if (tracks.length <= 1) return false;

    AudioTrack? best;
    var bestScore = 0;
    for (final t in tracks) {
      final score = TrackLanguage.score(
        language: t.language,
        title: t.title,
        preferred: original,
      );
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }
    if (best == null || bestScore < 10) return false;
    try {
      await _player!.setAudioTrack(best);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<({bool applied, bool primaryMatch})> _applyPreferredSubtitle(
    TrackLanguageSettings settings,
  ) async {
    const failed = (applied: false, primaryMatch: false);
    if (settings.subtitlesOff) {
      try {
        await _player?.setSubtitleTrack(SubtitleTrack.no());
        return (applied: true, primaryMatch: true);
      } catch (_) {
        return failed;
      }
    }

    final preferred = _subtitlePreferenceCodes(settings);
    if (preferred.isEmpty) return failed;
    final primary = preferred.first;

    // Skip auto-captions only when demuxer audio is already in a language the
    // listener understands — never because preferred *audio* is JP/etc.
    final spoken = _spokenLanguagePreference(settings);
    if (_audioMatchesPreferred(spoken)) {
      try {
        await _player?.setSubtitleTrack(SubtitleTrack.no());
      } catch (_) {}
      return (applied: true, primaryMatch: true);
    }

    // Widen match list with catalog subtitle language hints (still after
    // preferred/content locales so FR stays ahead of incidental EN tags).
    final pickPreferred = <String>[...preferred];
    final item = _item;
    if (item != null) {
      for (final raw in item.subtitleLanguages) {
        final n = TrackLanguage.normalize(raw);
        if (n != null && !pickPreferred.contains(n)) pickPreferred.add(n);
      }
    }

    // Catalog external tracks first.
    if (item != null && item.hasExternalSubtitles) {
      ExternalSubtitle? best;
      var bestScore = 0;
      for (final s in item.subtitles) {
        if (s.url.isEmpty) continue;
        final score = TrackLanguage.score(
          language: s.language,
          title: s.label ?? s.displayLabel,
          preferred: pickPreferred,
          isDefault: s.isDefault,
        );
        if (score > bestScore) {
          bestScore = score;
          best = s;
        }
      }
      if (best != null && bestScore >= 10) {
        try {
          await _player!.setSubtitleTrack(
            SubtitleTrack.uri(
              best.url,
              title: best.displayLabel,
              language: best.language,
            ),
          );
          final primaryMatch = TrackLanguage.matches(
            best.language,
            best.label ?? best.displayLabel,
            primary,
          );
          return (applied: true, primaryMatch: primaryMatch);
        } catch (_) {}
      }
    }

    final tracks = selectableSubtitleTracks
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    if (tracks.isEmpty) return failed;
    SubtitleTrack? best;
    var bestScore = 0;
    for (final t in tracks) {
      final score = TrackLanguage.score(
        language: t.language,
        title: t.title,
        preferred: pickPreferred,
      );
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }
    // Anime softsubs are often untagged — if dialogue is foreign and only one
    // real subtitle track exists, enable it rather than leaving captions off.
    if (best == null || bestScore < 10) {
      if (tracks.length != 1) return failed;
      best = tracks.first;
      try {
        await _player!.setSubtitleTrack(best);
        return (applied: true, primaryMatch: false);
      } catch (_) {
        return failed;
      }
    }
    try {
      await _player!.setSubtitleTrack(best);
      final primaryMatch = TrackLanguage.matches(
        best.language,
        best.title,
        primary,
      );
      return (applied: true, primaryMatch: primaryMatch);
    } catch (_) {
      return failed;
    }
  }

  Future<bool> _applyPreferredAudio(TrackLanguageSettings settings) async {
    final preferred = TrackLanguage.preferenceCodes(settings.audioLanguage);
    if (preferred.isEmpty) return false;

    final item = _item;
    if (item != null && item.hasExternalAudio) {
      ExternalAudio? best;
      var bestScore = 0;
      for (final a in item.audioTracks) {
        if (a.url.isEmpty) continue;
        final score = TrackLanguage.score(
          language: a.language,
          title: a.label ?? a.displayLabel,
          preferred: preferred,
          isDefault: a.isDefault,
        );
        if (score > bestScore) {
          bestScore = score;
          best = a;
        }
      }
      if (best != null && bestScore >= 10) {
        try {
          await _player!.setAudioTrack(
            AudioTrack.uri(
              best.url,
              title: best.displayLabel,
              language: best.language,
            ),
          );
          return true;
        } catch (_) {}
      }
    }

    final tracks = selectableAudioTracks;
    if (tracks.length <= 1) return false;
    AudioTrack? best;
    var bestScore = 0;
    for (final t in tracks) {
      final score = TrackLanguage.score(
        language: t.language,
        title: t.title,
        preferred: preferred,
      );
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }
    if (best == null || bestScore < 10) return false;
    try {
      await _player!.setAudioTrack(best);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _applyCatalogTracks(MediaItem item) async {
    // Defer to language prefs — never force the catalog's first/default sub
    // (that skipped the “captions only when audio differs” rule).
    await _maybeApplyLanguagePreferences(force: true);
  }

  Future<void> minimize() async {
    // Bump even when [open] has not set `_item` yet so the in-flight open
    // cannot re-expand after the user closed the full player.
    _miniGeneration++;
    if (!hasSession) return;
    // Flip chrome state first so the chevron feels instant; persist in the
    // background. Awaiting flush here made minimize feel like a no-op until
    // disk I/O finished (and invited repeat taps).
    final alreadyMini = _minimized && !_expanded;
    if (isPlayingAd) {
      _pingAdEvent('playerCollapse');
      _resolveViewable(leftEarly: true);
    }
    _minimized = true;
    _expanded = false;
    _cinemaMode = false;
    _fullPlayerOwnsVideo = false;
    // Surface reparent can miss buffering=false; drop a stuck awaiting flag
    // if the engine is already moving so the overlay does not follow the dock.
    _maybeMarkPlaybackActuallyStarted();
    JavpLog.i('player', 'minimize rev=$engineRevision dock=true');
    if (!alreadyMini) notifyListeners();
    // Disk / Home rematerialize (live recents, history flush) on this turn
    // hitch the pop + mini-bar texture attach. Let those frames paint first.
    unawaited(_afterMinimizeChromeSettles());
  }

  Future<void> _afterMinimizeChromeSettles() async {
    await pumpUi();
    if (_disposed || !hasSession || !_minimized) return;
    unawaited(_flushProgress());
    unawaited(_syncSystemChrome());
    unawaited(_syncPipAutoEnter());
  }

  /// Flip to expanded chrome without notifying.
  ///
  /// Used when `/player` is already mounting this frame so the first paint is
  /// watch+browse instead of the minimized full-bleed handoff scaffold.
  /// [expand] still runs after that frame to sync system chrome / PiP.
  void applyIncomingPlayerChrome() {
    if (!hasSession || isCasting) return;
    _minimized = false;
    _expanded = true;
  }

  Future<void> expand() async {
    if (!hasSession) return;
    if (_pip.usesDesktopMiniWindow && _pip.isInPip) {
      await _pip.exitDesktopMini();
    }
    // Match [minimize]: flip chrome first so expand feels instant; sync after.
    final alreadyExpanded = _expanded && !_minimized;
    if (isPlayingAd) {
      _pingAdEvent('playerExpand');
    }
    _minimized = false;
    _expanded = true;
    JavpLog.i(
      'player',
      'expand rev=$engineRevision surface=${_fullPlayerOwnsVideo ? 'full' : 'dock'}',
    );
    if (!alreadyExpanded) notifyListeners();
    unawaited(_syncSystemChrome());
    unawaited(_syncPipAutoEnter());
  }

  /// Full-screen `/player` or `/tv/watch` is attaching [videoSurfaceKey].
  /// The mini dock must drop that key in the same frame.
  void claimVideoSurface() {
    if (_fullPlayerOwnsVideo) return;
    _fullPlayerOwnsVideo = true;
    JavpLog.i('player', 'surface=full rev=$engineRevision mini=$isMinimized');
    notifyListeners();
  }

  /// Full-screen route dropped [videoSurfaceKey] (minimize already clears this).
  void releaseVideoSurface() {
    if (!_fullPlayerOwnsVideo) return;
    _fullPlayerOwnsVideo = false;
    JavpLog.i('player', 'surface=dock rev=$engineRevision mini=$isMinimized');
    notifyListeners();
  }

  /// Toggle cinema (fullscreen immersive) vs watch + browse.
  Future<void> setCinemaMode(bool enabled) async {
    if (_cinemaMode == enabled) return;
    if (isPlayingAd) {
      _pingAdEvent(enabled ? 'playerExpand' : 'playerCollapse');
    }
    _cinemaMode = enabled;
    notifyListeners();
    if (_expanded && !_minimized) {
      unawaited(_syncSystemChrome());
    }
    if (isDesktopPlatform) {
      unawaited(DesktopWindowService.instance.setCinemaFullscreen(enabled));
    }
  }

  Future<void> toggleCinemaMode() => setCinemaMode(!_cinemaMode);

  Future<void> setVideoAspectMode(VideoAspectMode mode) async {
    if (_videoAspectMode == mode) return;
    _videoAspectMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_videoAspectPrefKey, mode.storageValue);
    } catch (_) {}
  }

  Future<void> setDeinterlaceMode(VideoDeinterlaceMode mode) async {
    if (_deinterlaceMode == mode) return;
    _deinterlaceMode = mode;
    notifyListeners();
    final player = _player;
    if (player != null) unawaited(_configureDeinterlace(player));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_deinterlacePrefKey, mode.storageValue);
    } catch (_) {}
  }

  Future<void> setShowStreamStats(bool enabled) async {
    if (_showStreamStats == enabled) return;
    _showStreamStats = enabled;
    notifyListeners();
    unawaited(_persistStreamStats(enabled));
  }

  Future<void> _persistStreamStats(bool enabled) async {
    await pumpUi();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_streamStatsPrefKey, enabled);
    } catch (_) {}
  }

  Future<void> toggleStreamStats() => setShowStreamStats(!_showStreamStats);

  Future<void> _hydratePlayerDisplayPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final aspect = VideoAspectModeX.fromStorage(
        prefs.getString(_videoAspectPrefKey),
      );
      final deint = VideoDeinterlaceModeX.fromStorage(
        prefs.getString(_deinterlacePrefKey),
      );
      final stats = prefs.getBool(_streamStatsPrefKey) ?? false;
      if (_videoAspectMode == aspect &&
          _deinterlaceMode == deint &&
          _showStreamStats == stats) {
        return;
      }
      _videoAspectMode = aspect;
      _deinterlaceMode = deint;
      _showStreamStats = stats;
      notifyListeners();
      final player = _player;
      if (player != null) unawaited(_configureDeinterlace(player));
    } catch (_) {}
  }

  /// Collapse or expand the watch+browse side/bottom panel (not cinema).
  void setBrowsePanelCollapsed(bool collapsed) {
    _browsePanelTouched = true;
    if (_browsePanelCollapsed == collapsed) return;
    _browsePanelCollapsed = collapsed;
    notifyListeners();
    unawaited(_persistBrowsePanelCollapsed(collapsed));
  }

  Future<void> _persistBrowsePanelCollapsed(bool collapsed) async {
    await pumpUi();
    if (_browsePanelCollapsed != collapsed) return;
    unawaited(library.saveBrowsePanelCollapsed(collapsed));
  }

  Future<void> _hydrateBrowsePanelCollapsed() async {
    final collapsed = await library.loadBrowsePanelCollapsed();
    if (_browsePanelTouched || _browsePanelCollapsed == collapsed) return;
    _browsePanelCollapsed = collapsed;
    notifyListeners();
  }

  @visibleForTesting
  Future<void> debugEnsureBrowsePanelHydrated() => _browsePanelHydrate;

  void toggleBrowsePanel() => setBrowsePanelCollapsed(!_browsePanelCollapsed);

  /// Enter Picture-in-Picture (Android system PiP, or desktop mini-window).
  ///
  /// Desktop keeps the expanded player route. [PlayerScreen] paints video-only
  /// while [isInPip] — do not copy [minimize] (that turns cinema off and shows
  /// the watch+browse sidebar in the tiny window).
  Future<bool> enterPip() async {
    if (!canEnterPip) return false;
    final size = _pipAspect();
    final ok = await _pip.enter(
      aspectX: size.$1,
      aspectY: size.$2,
      playing: _enginePlaying,
    );
    if (ok) notifyListeners();
    return ok;
  }

  /// Pause/play, entering timeshift when resuming after a live-edge pause.
  ///
  /// Live HLS and Xtream timeshift are different URLs. We don't map HLS
  /// segment sequence numbers — we stamp wall-clock on pause (same as scrub)
  /// and request a timeshift URL for that start when play is pressed again.
  Future<void> onAppBackgrounded() async {
    if (_appInBackground) return;
    // Picture-in-Picture keeps playing — pausing here freezes the bubble and
    // clears playbackActive so idle catalog syncs stampede on return.
    if (isInPip) return;
    // Windows: keep playing when the window is hidden / minimized. The 45s
    // blur pause and a lifecycle pause both stopped video behind your back.
    if (isWindowsDesktop) {
      JavpLog.i(
        'player',
        'background keep-playing windows mini=$isMinimized playing=$playing',
      );
      return;
    }
    _appInBackground = true;
    _backgroundedAt = DateTime.now();
    if (AppCapabilities.usesVideoPlayerBackend) {
      final vp = _vp;
      if (vp == null) return;
      _playingBeforeBackground = vp.playing;
      if (!_playingBeforeBackground) return;
      try {
        await vp.pause();
      } catch (_) {}
      return;
    }
    final player = _player;
    if (player == null) return;
    _playingBeforeBackground = player.state.playing;
    if (!_playingBeforeBackground) return;
    try {
      await player.pause();
    } catch (_) {}
  }

  /// Soft resume after foreground — only if we paused for background.
  Future<void> onAppForegrounded() async {
    if (!_appInBackground) return;
    _appInBackground = false;
    _pausedForWindowsLongBlur = false;
    final shouldResume = _playingBeforeBackground;
    _playingBeforeBackground = false;
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    final hasEngine = AppCapabilities.usesVideoPlayerBackend
        ? _vp != null
        : _player != null;
    if (!shouldResume || !hasEngine || _item == null) return;
    // After a long AFK Android often drops the MediaCodec/GPU surface; forcing
    // play() immediately is a common ANR. Leave paused — user taps play.
    // Same policy on Windows after a long minimize: avoid slamming textures
    // back into the embedder the instant focus returns.
    if (backgroundedAt != null &&
        DateTime.now().difference(backgroundedAt) >
            const Duration(seconds: 90)) {
      return;
    }
    // Let the Video surface re-attach before kicking playback.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (_appInBackground) return;
    final stillReady = AppCapabilities.usesVideoPlayerBackend
        ? _vp != null
        : _player != null;
    if (!stillReady) return;
    try {
      await _enginePlay();
    } catch (_) {}
  }

  /// Desktop blur — playback keeps going. A 45s pause used to run here to
  /// avoid a Windows embedder crash on long restore; it also paused video
  /// whenever you switched windows, which was worse than the crash it
  /// avoided for most sessions.
  void onDesktopShellBlurred() {
    JavpLog.i(
      'player',
      'desktop blur keep-playing mini=$isMinimized playing=$playing',
    );
  }

  /// Previously paused video after a long Windows minimize. Always false —
  /// audio-only and video both keep playing while unfocused.
  @visibleForTesting
  static bool shouldPauseForWindowsLongBlur({required bool audioOnly}) => false;

  /// Desktop focus — cancel a pending long-blur pause; soft-resume if we
  /// already paused for Windows texture safety.
  Future<void> onDesktopShellFocused() async {
    if (!isWindowsDesktop) return;
    JavpLog.i(
      'player',
      'desktop focus mini=$isMinimized playing=$playing '
          'blurPaused=$_pausedForWindowsLongBlur',
    );
    if (!_pausedForWindowsLongBlur) return;
    await onAppForegrounded();
  }

  void _resetAudioDecodeErrorTracking() {
    _audioDecodeErrorWindowStart = null;
    _audioDecodeErrorCount = 0;
    _lastAudioDecodeLogAt = null;
  }

  /// Rate-limit mid-playback decode spam; pause after a flood instead of
  /// hammering the console / log while libmpv keeps failing.
  void _noteNonsurfacedPlayerError(String message) {
    if (!isAudioDecodeError(message)) {
      debugPrint('Player message while playing: $message');
      return;
    }
    final now = DateTime.now();
    final windowStart = _audioDecodeErrorWindowStart;
    if (windowStart == null ||
        now.difference(windowStart) > _audioDecodeErrorWindow) {
      _audioDecodeErrorWindowStart = now;
      _audioDecodeErrorCount = 0;
    }
    _audioDecodeErrorCount++;
    final lastLog = _lastAudioDecodeLogAt;
    if (lastLog == null ||
        now.difference(lastLog) >= _audioDecodeLogMinInterval) {
      _lastAudioDecodeLogAt = now;
      debugPrint(
        'Player audio decode error '
        '(n=$_audioDecodeErrorCount): $message',
      );
      JavpLog.w('playback', 'audio decode error n=$_audioDecodeErrorCount');
    }
    if (_audioDecodeErrorCount < _audioDecodeErrorPauseAfter) return;
    if (!_enginePlaying) return;
    _audioDecodeErrorCount = 0;
    _audioDecodeErrorWindowStart = now;
    JavpLog.w('playback', 'audio decode errors flood — pausing');
    unawaited(_enginePause());
  }

  Future<void> togglePlayPause() async {
    if (library.cast.isCasting) {
      await library.cast.playOrPause();
      return;
    }
    final wantPlaying = !playing;
    if (isPlayingAd) {
      unawaited(_applyEnginePlaying(wantPlaying));
      _setPlayingOverride(wantPlaying);
      if (wantPlaying) {
        _pingAdEvent('resume');
      } else {
        _pingAdEvent('pause');
      }
      return;
    }
    // Already in a timeshift clip — pause/resume in place.
    if (_dvrStart != null) {
      unawaited(_applyEnginePlaying(wantPlaying));
      _setPlayingOverride(wantPlaying);
      return;
    }

    // Resume after pausing at the live edge → native HLS window, else timeshift.
    if (wantPlaying && _livePausedAt != null && canLiveDvr) {
      final pausedAt = _livePausedAt!;
      _clearLivePausedAt();
      if (_canUseNativeHlsDvrFor(pausedAt)) {
        final behind = DateTime.now().difference(pausedAt);
        if (behind > kLiveEdgeSeekMargin) {
          await _seekNativeHlsDvrTo(pausedAt);
        }
        unawaited(_applyEnginePlaying(true));
        _setPlayingOverride(true);
        return;
      }
      unawaited(_applyEnginePlaying(true));
      _setPlayingOverride(true);
      if (DateTime.now().difference(pausedAt) > const Duration(seconds: 12)) {
        unawaited(seekLiveDvrTo(pausedAt));
        return;
      }
      return;
    }

    // Pausing DVR-capable live (edge or native in-window rewind) — freeze the
    // wall-clock playhead. Native HLS keeps [_dvrStart] null while behind live,
    // so without a pause stamp `now - (duration - position)` would drift.
    if (!wantPlaying &&
        canLiveDvr &&
        (isAtLiveEdge || _nativeHlsDvrEnabled)) {
      _livePausedAt = _dvrPlayheadWallClock ?? DateTime.now();
      _armLivePauseTicker();
      unawaited(_applyEnginePlaying(false));
      _setPlayingOverride(false);
      return;
    }

    if (!wantPlaying) {
      _clearLivePausedAt();
      // Pause is not an initial wait — drop a stuck awaiting flag so the
      // loading badge cannot come back while idle.
      if (_position > Duration.zero) {
        _onInitialPlaybackStarted();
      }
    }
    unawaited(_applyEnginePlaying(wantPlaying));
    _setPlayingOverride(wantPlaying);
  }

  Future<void> stop() async {
    if (library.cast.isCasting) {
      await library.cast.stop();
    }
    final restoreDesktopMini = _pip.usesDesktopMiniWindow && _pip.isInPip;
    // Cancel before any await so an in-flight [open] cannot recreate the session
    // while we tear down (Android TV close awaits this before popping).
    if (isPlayingAd) {
      _pingAdEvent('closeLinear');
      _resolveViewable(leftEarly: true, undetermined: true);
    }
    _clearVastSession();
    _cancelInFlightOpen();
    _miniGeneration++;
    _clearSeekBusy();
    _clearSleepTimer(notify: false);
    _sleepFiredFlag = false;
    library.setPlaybackActive(false);
    _endMediaServerLiveSession(stopped: true);
    // Flush while [_item] is still set — it captures locally before the first
    // await. Drop the session next so the mini bar can vanish this frame.
    final flush = _flushProgress();
    final torrents = _torrents.stopActive(deleteFiles: false);
    unawaited(_enginePause());
    _item = null;
    _liveChannel = null;
    _dvrStart = null;
    _lastTimeshiftExtendAt = null;
    _pendingNativeHlsLiveJoin = false;
    _nearLiveSeekGeneration++;
    _clearLivePausedAt();
    _clearSlowLoadHint(resetAwaiting: true);
    _clearHlsQualitySession();
    _activePlayUrl = null;
    _resetVolumeBoost();
    _minimized = false;
    _expanded = false;
    _cinemaMode = false;
    _fullPlayerOwnsVideo = false;
    _error = null;
    _playingOverride = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();
    if (restoreDesktopMini) {
      unawaited(_pip.exitDesktopMini());
    }
    await flush;
    await torrents;
    await _releaseEngine();
    unawaited(_syncSystemChrome());
    unawaited(_syncPipAutoEnter());
  }

  /// Recreate the libmpv engine after [LibraryProvider.softwareVideoDecoder]
  /// changes so the new `hwdec` applies immediately.
  Future<void> reloadForDecoderChange() async {
    if (!AppCapabilities.usesMediaKit) return;
    // Honor the user's Settings toggle over any session auto-fallback.
    _sessionSoftwareDecoder = false;
    final item = _item;
    if (item == null) {
      if (_player != null) await _releaseEngine();
      notifyListeners();
      return;
    }
    final expand = isExpanded || !isMinimized;
    final pos = _position;
    final liveEdge = item.isLive && _dvrStart == null;
    final resumeItem = item;
    await stop();
    await open(resumeItem, expand: expand);
    if (!liveEdge && pos > Duration.zero) {
      try {
        await seekTo(pos);
      } catch (_) {}
    }
  }

  /// Recreate the engine with `hwdec=no` after a MediaCodec open failure.
  /// Keeps the current session (unlike [stop]) and does not persist Settings.
  Future<void> _fallbackToSoftwareDecoder() async {
    if (!AppCapabilities.usesMediaKit) return;
    if (_codecFallbackInFlight || _useSoftwareDecoder) return;
    final item = _item;
    if (item == null) return;

    _codecFallbackInFlight = true;
    _sessionSoftwareDecoder = true;
    _error = null;
    _opening = true;
    notifyListeners();

    // Keep whatever chrome the user already has (mini dock vs full player).
    final expand = isExpanded || !isMinimized;
    final pos = _position;
    final liveEdge = item.isLive && _dvrStart == null;
    try {
      await _releaseEngine();
      _position = Duration.zero;
      _duration = Duration.zero;
      await open(item, expand: expand);
      if (!liveEdge && pos > Duration.zero) {
        try {
          await seekTo(pos);
        } catch (_) {}
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    } finally {
      _codecFallbackInFlight = false;
      _opening = false;
      notifyListeners();
    }
  }

  /// Default stream headers; catalog `httpHeaders` override on conflict.
  Map<String, String> _playbackHeaders([Map<String, String>? extra]) {
    final cleaned = withoutDrmHintHeaders(extra);
    if (cleaned.isEmpty) {
      return Map<String, String>.from(_defaultHttpHeaders);
    }
    return {..._defaultHttpHeaders, ...cleaned};
  }

  /// Headers for the active play URL. Non-HTTP schemes get an empty map
  /// (mpv properties handle transport).
  Map<String, String> _headersForPlayUrl(
    String playUrl, [
    Map<String, String>? extra,
  ]) {
    final remoteHttp =
        playUrl.startsWith('http://') || playUrl.startsWith('https://');
    if (!remoteHttp) return withoutDrmHintHeaders(extra);
    return _playbackHeaders(extra);
  }

  Future<String> _playableUrlFor(MediaItem item) async {
    final offline = library.offlinePlayPathFor(item);
    if (offline != null) {
      await _torrents.stopActive(deleteFiles: false);
      return offline;
    }

    if (item.origin == MediaOrigin.torrent ||
        looksLikeTorrentPlayUrl(item.playUrl)) {
      if (!AppCapabilities.torrents) {
        throw Exception(
          kIsWeb
              ? WebAppLimitation.featureUnavailablePlaybackMessage('Torrents')
              : 'Torrents are not supported on this device.',
        );
      }
      _resolvingTorrent = true;
      notifyListeners();
      try {
        final resolved = await _torrents.resolveToStream(
          item.playUrl,
          episodeNumber: item.episodeNumber,
          seasonNumber: item.seasonNumber,
          preferredFileName: item.torrentFile,
        );
        if (item.title == 'Torrent' ||
            item.title.startsWith('Torrent ') ||
            item.title.toLowerCase().startsWith('magnet')) {
          _item = item.copyWith(
            title: resolved.title,
            subtitle: resolved.fileName,
          );
        }
        return resolved.httpUrl;
      } finally {
        if (_resolvingTorrent) {
          _resolvingTorrent = false;
          notifyListeners();
        }
      }
    }
    await _torrents.stopActive(deleteFiles: false);

    if (item.origin == MediaOrigin.jellyfin ||
        item.origin == MediaOrigin.emby ||
        item.origin == MediaOrigin.plex ||
        (item.serverItemId != null && item.playUrl.isEmpty)) {
      if (item.serverItemId == null || item.serverItemId!.trim().isEmpty) {
        throw Exception(
          'Could not resolve media server stream URL '
          '(missing server item id — re-sync the source)',
        );
      }
      final resolved = await library.resolveServerStreamUrl(item);
      if (resolved == null || resolved.isEmpty) {
        throw Exception('Could not resolve media server stream URL');
      }
      return resolved;
    }
    if (item.origin == MediaOrigin.iptvStalker) {
      return library.resolveStalkerStreamUrl(item);
    }
    if (item.origin == MediaOrigin.iptvXtream) {
      return library.resolveXtreamStreamUrl(item);
    }
    return item.playUrl;
  }

  /// Resolve torrents/servers, then apply an HLS master playback plan.
  ///
  /// Muxed multi-bitrate masters stay on the master URL (Auto = ABR).
  /// Demuxed-audio masters open a media playlist (libmpv otherwise drops
  /// video); quality switching re-opens other variants. Muxed quality
  /// picks stay on the master and retarget `vid` — never `hls-bitrate`
  /// (that option only applies on open and hides the other programs).
  /// Alternate audio/subs from `#EXT-X-MEDIA` are merged as external tracks.
  Future<({MediaItem item, String playUrl})> _preparePlayable(
    MediaItem item,
  ) async {
    final playUrl = await _playableUrlFor(item);
    if (headersIndicateDrm(item.httpHeaders)) {
      throw UnsupportedDrmException(
        kind: drmKindFromHeaders(item.httpHeaders) ?? DrmKind.cenc,
        playUrl: playUrl,
      );
    }
    final headers = _headersForPlayUrl(playUrl, item.httpHeaders);
    await DrmManifestProbe.throwIfProtected(
      playUrl,
      httpHeaders: headers.isEmpty ? null : headers,
    );
    final plan = await HlsMaster.resolvePlaybackPlan(
      playUrl,
      httpHeaders: headers.isEmpty ? null : headers,
    );
    if (plan == null) {
      _clearHlsQualitySession();
      return (item: item, playUrl: playUrl);
    }
    _applyHlsPlaybackPlan(plan);
    JavpLog.i(
      'player',
      'hls plan open=${plan.openUrl} '
          'master=${plan.masterUrl} '
          'abr=${plan.openMasterForAbr} '
          'demuxed=${plan.demuxedAudio} '
          'n=${plan.variants.length} '
          '[${HlsQualitySwitch.describeVariants(plan.variants)}]',
    );
    // Muxed masters always open the master so lavf keeps every program.
    // A locked pick is applied with `vid` after tracks appear.
    final openUrl = plan.openMasterForAbr
        ? plan.openUrl
        : (_hlsQualityAuto
              ? plan.openUrl
              : (_hlsLockedVariantUrl ?? plan.openUrl));
    final merged = item.copyWith(
      audioTracks: HlsMaster.mergeAudioTracks(
        item.audioTracks,
        plan.audioTracks,
      ),
      subtitles: HlsMaster.mergeSubtitleTracks(item.subtitles, plan.subtitles),
    );
    return (item: merged, playUrl: openUrl);
  }

  void _clearHlsQualitySession() {
    _hlsVariants = const [];
    _hlsMasterUrl = null;
    _hlsSourceUrl = null;
    _hlsOpenMasterForAbr = false;
    _hlsQualityAuto = true;
    _hlsLockedVariantUrl = null;
    _hlsDemuxerCache = const [];
  }

  void _applyHlsPlaybackPlan(HlsPlaybackPlan plan) {
    final sameMaster =
        HlsQualitySwitch.sameMasterUrl(_hlsMasterUrl, plan.masterUrl) ||
        HlsQualitySwitch.sameMasterUrl(_hlsSourceUrl, plan.sourceUrl) ||
        HlsQualitySwitch.sameMasterUrl(_hlsMasterUrl, plan.sourceUrl) ||
        HlsQualitySwitch.sameMasterUrl(_hlsSourceUrl, plan.masterUrl);
    _hlsVariants = plan.variants;
    _hlsMasterUrl = plan.masterUrl;
    _hlsSourceUrl = plan.sourceUrl;
    _hlsOpenMasterForAbr = plan.openMasterForAbr;
    unawaited(_maybePinVideoOutput());
    if (!sameMaster) {
      // New title / master — always start on Auto.
      _hlsQualityAuto = true;
      _hlsLockedVariantUrl = null;
      _hlsDemuxerCache = const [];
      return;
    }
    // Retry / quality reload of the same master — keep a valid lock.
    if (_hlsLockedVariantUrl != null) {
      final stillThere = plan.variants.any(
        (v) => v.uri.toString() == _hlsLockedVariantUrl,
      );
      if (!stillThere) {
        _hlsQualityAuto = true;
        _hlsLockedVariantUrl = null;
      } else {
        _hlsQualityAuto = false;
      }
    } else {
      _hlsQualityAuto = true;
    }
  }

  Future<void> _setHlsQualityAuto() async {
    if (_hlsVariants.isEmpty) return;
    _hlsQualityAuto = true;
    _hlsLockedVariantUrl = null;
    notifyListeners();
    JavpLog.i(
      'player',
      'hls pick=auto onMaster=$_playingHlsMasterUrl '
          'abr=$_hlsOpenMasterForAbr',
    );
    if (await _applyHlsQualityInPlace(auto: true)) {
      return;
    }
    final master = _hlsMasterUrl;
    if (_hlsOpenMasterForAbr && master != null && master.isNotEmpty) {
      // vid=auto is a no-op after a lock on some live masters — reopen
      // with no bitrate cap so lavf republishes every program.
      JavpLog.w('player', 'hls auto fallback=reload-master');
      await _setMpvHlsBitrate('no');
      await _runQualityRetune(
        () => _reloadAtCurrentPosition(master, quiet: true),
      );
      await _applyHlsQualityInPlace(auto: true);
      notifyListeners();
      return;
    }
    if (!_hlsOpenMasterForAbr) {
      final url = _hlsVariants.first.uri.toString();
      JavpLog.w('player', 'hls auto fallback=reload-best (demuxed)');
      await _runQualityRetune(() => _reloadAtCurrentPosition(url, quiet: true));
    }
    notifyListeners();
  }

  Future<void> _setHlsQualityLocked(String variantUrl) async {
    if (variantUrl.isEmpty) return;
    final known = _hlsVariants.any((v) => v.uri.toString() == variantUrl);
    if (!known) return;
    _hlsQualityAuto = false;
    _hlsLockedVariantUrl = variantUrl;
    notifyListeners();
    HlsVariant? variant;
    for (final v in _hlsVariants) {
      if (v.uri.toString() == variantUrl) {
        variant = v;
        break;
      }
    }
    JavpLog.i(
      'player',
      'hls pick=${variant?.qualityLabel ?? variantUrl} '
          'h=${variant?.height} br=${variant?.bandwidth} '
          'onMaster=$_playingHlsMasterUrl abr=$_hlsOpenMasterForAbr',
    );
    final issued = await _applyHlsQualityInPlace(
      auto: false,
      variantUrl: variantUrl,
    );
    if (!HlsQualitySwitch.shouldReloadMuxedLock(issuedVidSwitch: issued)) {
      return;
    }
    if (_hlsOpenMasterForAbr) {
      final master = _hlsMasterUrl;
      if (master != null && master.isNotEmpty && !_playingHlsMasterUrl) {
        JavpLog.w('player', 'hls lock fallback=rejoin-master-then-vid');
        await _setMpvHlsBitrate('no');
        await _runQualityRetune(
          () => _reloadAtCurrentPosition(master, quiet: true),
        );
        if (await _applyHlsQualityInPlace(
          auto: false,
          variantUrl: variantUrl,
        )) {
          notifyListeners();
          return;
        }
      }
      // Muxed master: never loadfile the media playlist. That hides the
      // other programs so every later pick reloads. Stay on the master.
      JavpLog.w(
        'player',
        'hls lock skip media-playlist reload '
            '${variant?.qualityLabel ?? variantUrl}',
      );
      notifyListeners();
      return;
    }
    JavpLog.w('player', 'hls lock fallback=reload-variant (demuxed)');
    await _runQualityRetune(
      () => _reloadAtCurrentPosition(variantUrl, quiet: true),
    );
    notifyListeners();
  }

  /// Stay on the muxed master and retarget `vid` (YouTube-style).
  ///
  /// Returns true when `vid` was set. lavf applies that at the next
  /// segment — do not `loadfile` a media playlist on decoder lag.
  /// `hls-bitrate` only applies on the next open and hides programs.
  /// Demuxed-audio masters still have to reload a media playlist.
  Future<bool> _applyHlsQualityInPlace({
    required bool auto,
    String? variantUrl,
  }) async {
    if (!AppCapabilities.usesMediaKit || _player == null) return false;
    await _maybePinVideoOutput();
    if (!_hlsOpenMasterForAbr) {
      JavpLog.i('player', 'hls in-place skip reason=demuxed-master');
      return false;
    }

    HlsVariant? variant;
    if (!auto) {
      for (final v in _hlsVariants) {
        if (v.uri.toString() == variantUrl) {
          variant = v;
          break;
        }
      }
      if (variant == null) {
        JavpLog.w('player', 'hls in-place skip reason=unknown-variant');
        return false;
      }
    }

    final before = await _hlsCurrentVideo();
    final demuxer = await _waitHlsDemuxerVideos();
    JavpLog.i(
      'player',
      'hls demuxer n=${demuxer.length}/${_hlsVariants.length} '
          '[${HlsQualitySwitch.describeDemuxer(demuxer)}] '
          'now=vid=${before.vid} ${before.width}x${before.height}',
    );
    if (!HlsQualitySwitch.canSwitchInPlace(
      openMasterForAbr: _hlsOpenMasterForAbr,
      onMaster: _playingHlsMasterUrl,
      demuxerVideoCount: demuxer.length,
    )) {
      JavpLog.w(
        'player',
        'hls in-place skip reason=not-on-master '
            'onMaster=$_playingHlsMasterUrl vids=${demuxer.length}',
      );
      return false;
    }
    final matched = variant == null
        ? null
        : HlsQualitySwitch.matchDemuxerTrack(
            variant,
            demuxer,
            all: _hlsVariants,
          );
    if (!auto &&
        !HlsQualitySwitch.canLockInPlace(hasDemuxerMatch: matched != null)) {
      JavpLog.w(
        'player',
        'hls in-place skip reason=no-vid-match '
            'want=${variant?.qualityLabel} h=${variant?.height}',
      );
      return false;
    }
    if (auto && demuxer.length < 2) {
      // One vid means lavf already pinned a variant. Auto needs a reopen
      // only when we are not on the master.
      JavpLog.w('player', 'hls in-place skip reason=single-vid auto');
      return false;
    }

    try {
      if (auto) {
        await _setMpvVid('auto');
        await _player!.setVideoTrack(VideoTrack.auto());
      } else if (matched != null) {
        VideoTrack? native;
        for (final t in demuxerVideoTracks) {
          if (t.id == matched.id) {
            native = t;
            break;
          }
        }
        native ??= VideoTrack(matched.id, null, null);
        await _setMpvVid(matched.id);
        await _player!.setVideoTrack(native);
      }
      // `vid` is queued; lavf swaps the bitstream at the next segment.
      // Do not treat a 2s decoder lag as failure — that used to loadfile
      // the media playlist and kill in-place switching for the session.
      unawaited(
        _verifyHlsQualityApplied(
          auto: auto,
          targetHeight: variant?.height,
          targetVid: matched?.id,
        ).then((ok) {
          JavpLog.i(
            'player',
            auto
                ? 'hls quality=auto in-place landed=$ok'
                : 'hls quality=${variant?.qualityLabel ?? variantUrl} '
                      'in-place vid=${matched?.id} landed=$ok',
          );
        }),
      );
      JavpLog.i(
        'player',
        auto
            ? 'hls quality=auto in-place issued'
            : 'hls quality=${variant?.qualityLabel ?? variantUrl} '
                  'in-place vid=${matched?.id} issued',
      );
      return true;
    } catch (e) {
      JavpLog.w('player', 'hls in-place failed', error: e);
      return false;
    }
  }

  bool get _playingHlsMasterUrl {
    return HlsQualitySwitch.sameMasterUrl(_activePlayUrl, _hlsMasterUrl) ||
        HlsQualitySwitch.sameMasterUrl(_activePlayUrl, _hlsSourceUrl) ||
        ((_activePlayUrl == null || _activePlayUrl!.isEmpty) &&
            _hlsOpenMasterForAbr &&
            _hlsMasterUrl != null);
  }

  Future<void> _cacheHlsDemuxerFromState() async {
    if (_hlsVariants.length < 2) return;
    await _hlsDemuxerVideos();
  }

  /// libmpv video tracks, including `hls-bitrate` media_kit does not copy.
  Future<List<HlsDemuxerVideo>> _hlsDemuxerVideos({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _hlsDemuxerCache.length >= 2 &&
        (_hlsVariants.length < 2 ||
            _hlsDemuxerCache.length >= _hlsVariants.length)) {
      return _hlsDemuxerCache;
    }
    final fromState = [
      for (final t in demuxerVideoTracks)
        HlsDemuxerVideo(id: t.id, height: t.h, bitrate: t.bitrate),
    ];
    final platform = _player?.platform;
    if (platform is! NativePlayer) {
      return _rememberHlsDemuxer(fromState);
    }
    try {
      final count =
          int.tryParse('${await platform.getProperty('track-list/count')}') ??
          0;
      if (count <= 0) return _rememberHlsDemuxer(fromState);
      final out = <HlsDemuxerVideo>[];
      final slice = Stopwatch()..start();
      for (var i = 0; i < count; i++) {
        final type = '${await platform.getProperty('track-list/$i/type')}';
        if (type != 'video') {
          await yieldUiSlice(
            slice,
            i: i,
            checkMask: 3,
            label: 'playback-hls-track-skip',
          );
          continue;
        }
        final id = '${await platform.getProperty('track-list/$i/id')}';
        if (id.isEmpty || id == 'auto' || id == 'no') continue;
        final h = int.tryParse(
          '${await platform.getProperty('track-list/$i/demux-h')}',
        );
        final hlsBr = int.tryParse(
          '${await platform.getProperty('track-list/$i/hls-bitrate')}',
        );
        final demuxBr = int.tryParse(
          '${await platform.getProperty('track-list/$i/demux-bitrate')}',
        );
        out.add(HlsDemuxerVideo(id: id, height: h, bitrate: hlsBr ?? demuxBr));
        await yieldUiSlice(
          slice,
          i: i,
          checkMask: 3,
          label: 'playback-hls-track-add',
        );
      }
      final best = out.length >= fromState.length ? out : fromState;
      return _rememberHlsDemuxer(best);
    } catch (_) {
      return _rememberHlsDemuxer(fromState);
    }
  }

  /// Current decoder `vid` + coded size (state, then mpv properties).
  Future<({String? vid, int? width, int? height})> _hlsCurrentVideo() async {
    final player = _player;
    final fromState = (
      vid: player?.state.track.video.id,
      width: player?.state.width,
      height: player?.state.height,
    );
    final platform = player?.platform;
    if (platform is! NativePlayer) return fromState;
    try {
      final vid = '${await platform.getProperty('vid')}';
      final w = int.tryParse('${await platform.getProperty('video-params/w')}');
      final h = int.tryParse('${await platform.getProperty('video-params/h')}');
      return (
        vid: vid.isEmpty ? fromState.vid : vid,
        width: (w != null && w > 0) ? w : fromState.width,
        height: (h != null && h > 0) ? h : fromState.height,
      );
    } catch (_) {
      return fromState;
    }
  }

  /// Confirm libmpv actually switched — `setVideoTrack` can ACK a no-op.
  Future<bool> _verifyHlsQualityApplied({
    required bool auto,
    int? targetHeight,
    String? targetVid,
  }) async {
    final deadline = DateTime.now().add(HlsQualitySwitch.applyVerifyWait);
    ({String? vid, int? width, int? height})? last;
    while (true) {
      last = await _hlsCurrentVideo();
      if (auto) {
        if (HlsQualitySwitch.isAutoVid(last.vid)) {
          JavpLog.i(
            'player',
            'hls verify auto vid=${last.vid} '
                '${last.width}x${last.height}',
          );
          return true;
        }
      } else {
        final vidOk =
            targetVid != null && targetVid.isNotEmpty && last.vid == targetVid;
        final hOk = HlsQualitySwitch.heightMatchesLock(
          last.height,
          targetHeight,
        );
        if (vidOk) {
          // vid retarget landed; coded height can lag behind the switch.
          JavpLog.i(
            'player',
            'hls verify lock vid=${last.vid} '
                '${last.width}x${last.height} wantH=$targetHeight',
          );
          return true;
        }
        if (hOk) {
          // Decoder height moved; vid property can lag on live HLS.
          JavpLog.i(
            'player',
            'hls verify lock by-height vid=${last.vid} '
                '${last.width}x${last.height} wantVid=$targetVid',
          );
          return true;
        }
      }
      if (!DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(HlsQualitySwitch.applyVerifyPoll);
    }
    JavpLog.w(
      'player',
      auto
          ? 'hls verify auto failed vid=${last.vid} '
                '${last.width}x${last.height}'
          : 'hls verify lock failed vid=${last.vid} '
                '${last.width}x${last.height} '
                'wantVid=$targetVid wantH=$targetHeight',
    );
    return false;
  }

  List<HlsDemuxerVideo> _rememberHlsDemuxer(List<HlsDemuxerVideo> tracks) {
    if (tracks.length >= 2) {
      _hlsDemuxerCache = List<HlsDemuxerVideo>.unmodifiable(tracks);
      return _hlsDemuxerCache;
    }
    if (_hlsDemuxerCache.length >= 2) return _hlsDemuxerCache;
    return tracks;
  }

  Future<List<HlsDemuxerVideo>> _waitHlsDemuxerVideos() async {
    var tracks = await _hlsDemuxerVideos();
    if (!HlsQualitySwitch.shouldWaitForDemuxerTracks(
      tracks,
      variantCount: _hlsVariants.length,
    )) {
      return tracks;
    }
    final deadline = DateTime.now().add(HlsQualitySwitch.demuxerWait);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(HlsQualitySwitch.demuxerPoll);
      tracks = await _hlsDemuxerVideos(forceRefresh: true);
      if (!HlsQualitySwitch.shouldWaitForDemuxerTracks(
        tracks,
        variantCount: _hlsVariants.length,
      )) {
        return tracks;
      }
    }
    return tracks;
  }

  Future<void> _setMpvHlsBitrate(String value) async {
    final platform = _player?.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty('hls-bitrate', value);
  }

  Future<void> _setMpvVid(String id) async {
    final platform = _player?.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty('vid', id);
  }

  /// Show the loading overlay for a quality retune without [_opening]
  /// (which would make Back abandon the session).
  Future<T> _runQualityRetune<T>(Future<T> Function() body) async {
    _retuneDepth++;
    if (_retuneDepth == 1) notifyListeners();
    try {
      return await body();
    } finally {
      if (_retuneDepth > 0) _retuneDepth--;
      if (_retuneDepth == 0) notifyListeners();
    }
  }

  /// Re-open [url] seeking back to the current playhead (quality switches).
  ///
  /// [quiet] skips [_opening] so minimize still docks and engineRevision
  /// stays put. Pair with [_runQualityRetune] so the loading overlay still
  /// paints.
  Future<void> _reloadAtCurrentPosition(
    String url, {
    bool quiet = false,
  }) async {
    final item = _item;
    if (item == null) return;
    _rememberCurrentTracksForReload();
    _markLanguagePrefsDirtyForReload();
    final pos = _position;
    final liveEdge = item.isLive && _dvrStart == null;
    if (!quiet) {
      _opening = true;
      _error = null;
      notifyListeners();
    }
    try {
      await _openMedia(
        Media(
          url,
          start: liveEdge || pos <= Duration.zero ? null : pos,
          httpHeaders: _headersForPlayUrl(url, item.httpHeaders),
        ),
        play: true,
      );
      if (!liveEdge && pos > Duration.zero) {
        try {
          await seekTo(pos);
        } catch (_) {}
      }
      await _applyCatalogTracks(item);
      await _maybeApplyLanguagePreferences(force: true);
    } catch (e) {
      _error = e.toString();
    } finally {
      if (!quiet) _opening = false;
      notifyListeners();
    }
  }

  String? get currentPlayUrl {
    final item = _item;
    if (item == null) return null;
    final active = _activePlayUrl;
    if (active != null && active.isNotEmpty) return active;
    if (AppCapabilities.usesVideoPlayerBackend) {
      return _vpPlayUrl ?? item.playUrl;
    }
    try {
      final medias = _player?.state.playlist.medias ?? const [];
      return medias.isEmpty ? item.playUrl : medias.first.uri;
    } catch (_) {
      return item.playUrl;
    }
  }

  Future<void> castCurrent({CastTarget? target}) async {
    final item = _item;
    // Cast the URL the player actually opened. For "demuxed" masters that
    // still mux AAC inside MPEG-TS (demuxed-audio HLS), that is the media playlist.
    // Sending the master makes CAF assume packed-audio HLS and reject LOAD.
    final url = currentPlayUrl;
    if (item == null || url == null) return;
    final picked =
        target ?? library.cast.activeTarget ?? library.cast.preferredTarget;
    String? transcodeUrl;
    if (library.castServerTranscodeFallback && item.origin.isMediaServer) {
      final resolved = await library.resolveServerStreamUrl(
        item.copyWith(resolution: MediaServerStreamQuality.high.name),
      );
      if (resolved != null && resolved.isNotEmpty && resolved != url) {
        transcodeUrl = resolved;
      }
    }
    final ok = await library.cast.castMedia(
      url: url,
      title: item.title,
      subtitle: item.subtitle,
      posterUrl: item.artUrl,
      position: _position,
      duration: _duration == Duration.zero ? null : _duration,
      live: item.isLive,
      fileName:
          item.torrentFile ??
          (item.origin == MediaOrigin.torrent ? item.subtitle : null),
      transcodeUrl: transcodeUrl,
      codecHint: [
        item.videoCodec,
        item.audioCodec,
        item.hdr,
      ].whereType<String>().where((s) => s.isNotEmpty).join(' '),
      target: picked,
    );
    if (ok) {
      await _enginePause();
      unawaited(_ensureSkipSegments());
    }
  }

  Future<void> retry() async {
    final item = _item;
    if (item == null) return;
    _error = null;
    _opening = true;
    _beginAwaitingInitialPlayback(item);
    notifyListeners();
    try {
      final prepared = await _preparePlayable(item);
      _item = prepared.item;
      await _openMedia(
        Media(
          prepared.playUrl,
          httpHeaders: _headersForPlayUrl(
            prepared.playUrl,
            prepared.item.httpHeaders,
          ),
        ),
        play: true,
      );
      await _applyCatalogTracks(prepared.item);
      await _maybeApplyLanguagePreferences(force: true);
    } catch (e) {
      _error = e.toString();
      _maybeSuggestLowerQualityOnFailure(item);
    } finally {
      _opening = false;
      notifyListeners();
    }
  }

  bool _isMediaServerPlayback(MediaItem item) =>
      item.origin.isMediaServer ||
      (item.serverItemId != null && item.playUrl.isEmpty);

  void _beginAwaitingInitialPlayback(MediaItem item) {
    _slowLoadTimer?.cancel();
    _slowLoadTimer = null;
    _suggestLowerQuality = false;
    _slowLoadHintDismissed = false;
    _awaitingInitialPlayback = true;
    if (!_isMediaServerPlayback(item)) return;
    if (mediaServerStreamQuality.lowerQuality == null) return;
    _slowLoadTimer = Timer(_slowLoadHintDelay, () {
      if (!_awaitingInitialPlayback || _slowLoadHintDismissed) return;
      if (_error != null) return;
      final current = _item;
      if (current == null || !_isMediaServerPlayback(current)) return;
      if (mediaServerStreamQuality.lowerQuality == null) return;
      _suggestLowerQuality = true;
      JavpLog.w(
        'play',
        'slow-load hint after ${_slowLoadHintDelay.inSeconds}s '
            'kind=${current.kind.name} origin=${current.origin.name}',
      );
      notifyListeners();
    });
  }

  void _onInitialPlaybackStarted() {
    if (!_awaitingInitialPlayback && !_suggestLowerQuality) return;
    _clearSlowLoadHint(resetAwaiting: true);
  }

  void _maybeSuggestLowerQualityOnFailure(MediaItem item) {
    if (_slowLoadHintDismissed) return;
    if (!_isMediaServerPlayback(item)) return;
    if (mediaServerStreamQuality.lowerQuality == null) return;
    if (_suggestLowerQuality) return;
    _suggestLowerQuality = true;
  }

  void _clearSlowLoadHint({required bool resetAwaiting}) {
    _slowLoadTimer?.cancel();
    _slowLoadTimer = null;
    if (resetAwaiting) _awaitingInitialPlayback = false;
    if (_suggestLowerQuality) {
      _suggestLowerQuality = false;
    }
  }

  void dismissLowerQualitySuggestion() {
    _slowLoadHintDismissed = true;
    _slowLoadTimer?.cancel();
    _slowLoadTimer = null;
    if (!_suggestLowerQuality) return;
    _suggestLowerQuality = false;
    notifyListeners();
  }

  /// Persist [quality], tag the current item, and reopen the stream.
  Future<void> reopenWithMediaServerQuality(
    MediaServerStreamQuality quality,
  ) async {
    final item = _item;
    if (item == null) return;
    await library.saveMediaServerStreamQuality(quality);
    final updated = item.copyWith(resolution: quality.name);
    _item = updated;
    _clearSlowLoadHint(resetAwaiting: true);
    _error = null;
    notifyListeners();
    await _runQualityRetune(() async {
      await open(updated, expand: _expanded || !_minimized, quiet: true);
    });
  }

  /// Drop one quality step and reopen (Original → High → … → Data saver).
  Future<void> tryLowerMediaServerQuality() async {
    final next = nextLowerMediaServerQuality;
    if (next == null) return;
    await reopenWithMediaServerQuality(next);
  }

  Future<void> _flushProgress({MediaItem? item}) async {
    if (_currentAd != null) return;
    item ??= _item;
    if (item == null) return;
    if (item.isLive && _dvrStart == null) {
      await library.recordWatch(item);
      await library.flushPendingWrites();
      return;
    }
    if (_dvrStart != null) {
      await _persistDvrProgress();
      await library.flushPendingWrites();
      return;
    }
    final duration = _engineDuration;
    if (duration.inMilliseconds <= 0) return;
    final progress = _enginePosition.inMilliseconds / duration.inMilliseconds;
    if (progress > 0) {
      await library.recordProgress(
        item,
        progress,
        duration: duration,
        forceScrobble: true,
      );
      await library.reportServerProgress(
        item,
        position: _enginePosition,
        isPaused: true,
        duration: duration,
        stopped: true,
      );
      await library.flushPendingWrites();
    }
  }

  void _reportServerProgress({
    required bool isPaused,
    bool stopped = false,
    bool force = false,
  }) {
    final item = _item;
    if (item == null || item.isLive || item.serverItemId == null) return;
    if (_dvrStart != null) return;
    final now = DateTime.now();
    if (!force &&
        !stopped &&
        !isPaused &&
        _lastServerProgressAt != null &&
        now.difference(_lastServerProgressAt!) < _serverProgressMinInterval) {
      return;
    }
    _lastServerProgressAt = now;
    final duration = _duration > Duration.zero ? _duration : item.duration;
    unawaited(
      library.reportServerProgress(
        item,
        position: _position,
        isPaused: isPaused,
        duration: duration,
        stopped: stopped,
      ),
    );
  }

  void _startPlexLiveKeepalive(MediaItem item, String playUrl) {
    _endMediaServerLiveSession(stopped: false);
    if ((!item.isLive && item.kind != MediaKind.catchup) ||
        item.origin != MediaOrigin.plex) {
      return;
    }
    final path = Uri.tryParse(playUrl)?.queryParameters['path']?.trim();
    if (path == null || !path.contains('/livetv/sessions/')) return;
    _plexLiveSessionKey = path;
    _plexLiveKeepaliveTimer = Timer.periodic(_plexLiveKeepaliveInterval, (_) {
      final channel = liveChannel ?? _item;
      final key = _plexLiveSessionKey;
      if (channel == null || key == null) return;
      unawaited(
        library.pingPlexLiveSession(
          channel,
          sessionKey: key,
          isPaused: !_enginePlaying,
        ),
      );
    });
    // Immediate ping so PMS sees the consumer right after tune.
    unawaited(
      library.pingPlexLiveSession(item, sessionKey: path, isPaused: false),
    );
  }

  /// Stop Plex keepalive and explicitly close JF / Emby / Plex tuner sessions
  /// on zap, quality change, or leave.
  void _endMediaServerLiveSession({required bool stopped}) {
    _plexLiveKeepaliveTimer?.cancel();
    _plexLiveKeepaliveTimer = null;
    final key = _plexLiveSessionKey;
    final channel = liveChannel ?? _item;
    _plexLiveSessionKey = null;
    if (!stopped || channel == null || !channel.origin.isMediaServer) return;
    if (channel.origin == MediaOrigin.plex && key != null) {
      unawaited(
        library.pingPlexLiveSession(
          channel,
          sessionKey: key,
          isPaused: true,
          stopped: true,
        ),
      );
    }
    unawaited(library.closeMediaServerLiveSession(channel));
  }

  bool _expandedForChrome = false;
  bool _minimizedForChrome = true;
  bool _cinemaForChrome = false;

  /// Skip no-op SystemChrome / orientation calls (they hitch zaps in cinema).
  Future<void> _syncSystemChromeIfChanged({
    required bool expanded,
    required bool minimized,
  }) async {
    if (expanded == _expandedForChrome &&
        minimized == _minimizedForChrome &&
        _cinemaMode == _cinemaForChrome) {
      return;
    }
    await _syncSystemChrome();
  }

  /// Expanded browse uses edge-to-edge; cinema uses immersive sticky.
  Future<void> _syncSystemChrome() async {
    _expandedForChrome = _expanded;
    _minimizedForChrome = _minimized;
    _cinemaForChrome = _cinemaMode;
    if (!_expanded || _minimized) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
      ]);
      return;
    }
    if (_cinemaMode) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
  }

  void _onPipServiceChanged() {
    notifyListeners();
    // Probe can finish after the first open(); arm auto-enter then.
    unawaited(_syncPipAutoEnter());
  }

  void _onCastChanged() {
    notifyListeners();
    if (isCasting) unawaited(_maybeAutoSkipCastSegment());
  }

  void _onPipAction(String action) {
    if (action == 'play' && !_enginePlaying) {
      unawaited(togglePlayPause());
    } else if (action == 'pause' && _enginePlaying) {
      unawaited(togglePlayPause());
    }
  }

  (int, int) _pipAspect() {
    if (isAudioOnly) return (1, 1);
    if (AppCapabilities.usesVideoPlayerBackend) {
      final size = _vp?.controller?.value.size;
      if (size != null && size.width > 0 && size.height > 0) {
        return (size.width.round(), size.height.round());
      }
      return (16, 9);
    }
    final w = _player?.state.width;
    final h = _player?.state.height;
    if (w != null && h != null && w > 0 && h > 0) return (w, h);
    return (16, 9);
  }

  void _syncPipAspectRatio() {
    if (!_pip.isSupported) return;
    final size = _pipAspect();
    unawaited(_pip.setAspectRatio(aspectX: size.$1, aspectY: size.$2));
  }

  Future<void> _syncPipAutoEnter() async {
    if (_disposed || !_pip.isSupported) return;
    final size = _pipAspect();
    await _pip.setAutoEnter(
      enabled: isExpanded && hasSession,
      aspectX: size.$1,
      aspectY: size.$2,
      playing: _enginePlaying,
    );
  }

  MediaItem _asLiveChannel(MediaItem catchup) {
    // Prefer rebuilding from the Xtream source so credential-stripped
    // timeshift URLs (`/timeshift/45/…/id.ts`) never become a dead
    // `/live/id.ts` guess without a stream id we can rebuild from.
    var liveUrl =
        _liveUrlFromSource(catchup) ??
        XtreamClient.liveUrlFromTimeshift(catchup.playUrl) ??
        catchup.playUrl;
    // Persist credential-free like other Xtream rows; play injects via
    // [_preparePlayable] / [resolveXtreamStreamUrl].
    if (isXtreamStreamUrl(liveUrl)) {
      liveUrl = stripXtreamCredentials(liveUrl);
    }
    String? serverItemId = catchup.serverItemId;
    if (catchup.origin == MediaOrigin.plex) {
      final live = PlexClient.parseLiveServerItemId(serverItemId ?? '');
      if (live != null) {
        serverItemId = PlexClient.liveServerItemId(
          dvrId: live.dvrId,
          channelId: live.channelId,
        );
      }
    } else if (catchup.origin == MediaOrigin.jellyfin ||
        catchup.origin == MediaOrigin.emby) {
      final live = JellyfinClient.parseLiveServerItemId(serverItemId ?? '');
      final channelId = live?.channelId ?? catchup.streamId;
      if (channelId != null && channelId.isNotEmpty) {
        serverItemId = JellyfinClient.liveServerItemId(channelId);
      }
    }
    return MediaItem(
      id: 'live-${catchup.sourceId}-${catchup.streamId}',
      title: catchup.subtitle ?? catchup.title,
      playUrl: liveUrl,
      kind: MediaKind.live,
      origin: catchup.origin,
      subtitle: catchup.group,
      thumbnailUrl: catchup.thumbnailUrl,
      group: catchup.group,
      channelId: catchup.channelId,
      streamId: catchup.streamId,
      epgChannelId: catchup.epgChannelId,
      catchupDays: catchup.catchupDays,
      sourceId: catchup.sourceId,
      serverItemId: serverItemId,
      resolution: catchup.resolution,
    );
  }

  /// Rebuild `/live/...` from the Xtream source when URL guessing fails.
  String? _liveUrlFromSource(MediaItem catchup) {
    final streamId = catchup.streamId?.trim();
    if (streamId == null || streamId.isEmpty) return null;
    final source = library.sources.cast<IptvSource?>().firstWhere(
      (s) => s?.id == catchup.sourceId,
      orElse: () => null,
    );
    if (source == null ||
        source.type != IptvSourceType.xtream ||
        source.serverUrl == null ||
        source.serverUrl!.trim().isEmpty) {
      return null;
    }
    return XtreamClient.liveStreamUrl(source: source, streamId: streamId);
  }

  @override
  void dispose() {
    _disposed = true;
    _pip.onPipAction = null;
    _pip.removeListener(_onPipServiceChanged);
    library.cast.removeListener(_onCastChanged);
    unawaited(_pip.setAutoEnter(enabled: false));
    if (_ownsPip) _pip.dispose();
    _livePauseTicker?.cancel();
    _slowLoadTimer?.cancel();
    _seekBusyTimer?.cancel();
    _clearSleepTimer(notify: false);
    _endMediaServerLiveSession(stopped: true);
    unawaited(_flushProgress());
    unawaited(_torrents.stopActive(deleteFiles: false));
    _clearVastSession();
    final vp = _vp;
    unawaited(() async {
      await _releaseEngine();
      if (vp != null) await vp.closeStreams();
    }());
    super.dispose();
  }
}
