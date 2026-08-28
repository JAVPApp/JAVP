import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/playback_speeds.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/multi_view_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/screens/player/player_seek_gestures.dart';
import 'package:javp/screens/player/player_side_strip_gestures.dart';
import 'package:javp/services/playback/live_edge_rate.dart';
import 'package:javp/services/playback/player_clock.dart';
import 'package:javp/services/input/gamepad_events.dart';
import 'package:javp/services/input/gamepad_service.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/platform/screen_brightness.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/cast/cast_device_sheet.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:javp/widgets/download/dvr_download_dialog.dart';
import 'package:javp/widgets/multi_view/multi_view_channel_picker.dart';
import 'package:javp/widgets/player/desktop_player_keyboard.dart';
import 'package:javp/widgets/player/live_dvr_playhead.dart';
import 'package:javp/widgets/player/player_error_overlay.dart';
import 'package:javp/widgets/player/player_settings_panel.dart';
import 'package:javp/widgets/player/slow_load_quality_prompt.dart';
import 'package:javp/compat/media_kit.dart';
import 'package:javp/compat/media_kit_video.dart';
import 'package:provider/provider.dart';

/// Gesture-driven overlay: auto-hiding chrome, side double-tap seek
/// (then same-side single taps while the burst is open),
/// side press-and-hold (or hold Space on desktop) for temporary 2x,
/// live DVR scrubbing, and EPG now-playing.
class GesturePlayerControls extends StatefulWidget {
  const GesturePlayerControls({
    super.key,
    required this.player,
    required this.controller,
    required this.item,
    this.error,
    this.onRetry,
    this.onClose,
    this.onMinimize,
    this.onCaptionSettings,
    this.onToggleCinema,
    this.onToggleBrowsePanel,
  });

  final Player player;
  final VideoController controller;
  final MediaItem item;
  final String? error;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;
  final VoidCallback? onMinimize;
  final VoidCallback? onCaptionSettings;
  final VoidCallback? onToggleCinema;
  final VoidCallback? onToggleBrowsePanel;

  @override
  State<GesturePlayerControls> createState() => _GesturePlayerControlsState();
}

/// Which input armed the temporary 2x hold (pointer side-hold and/or Space).
enum _HoldBoostSource { pointer, space }

class _GesturePlayerControlsState extends State<GesturePlayerControls> {
  static const _holdSpeed = 2.0;

  /// Faster than Flutter’s default long-press so 2x feels immediate.
  static const _holdBoostDelay = Duration(milliseconds: 280);
  static const _hideAfter = Duration(seconds: 3);
  static const _seekStepSeconds = 10;

  bool _visible = true;
  bool _holdingBoost = false;

  /// Active hold inputs; boost ends only when this set is empty.
  final Set<_HoldBoostSource> _holdBoostSources = <_HoldBoostSource>{};

  /// True from hold-arm until the matching restore [setRate] finishes.
  bool _boostRateInFlight = false;

  /// Bumped on each arm/end so a stale restore [whenComplete] cannot clear
  /// [_boostRateInFlight] while a newer boost cycle is active.
  int _boostEpoch = 0;
  double _baseRate = 1.0;
  double _selectedRate = 1.0;
  bool _locked = false;

  /// Unlock affordance while locked (auto-hides like normal chrome).
  bool _lockChromeVisible = false;
  String? _seekHint;
  Timer? _hideTimer;
  Timer? _seekHintTimer;
  Timer? _holdBoostTimer;
  Timer? _spaceHoldTimer;
  Timer? _pendingChromeTimer;
  int? _pendingSeekTapSide;
  DateTime? _pendingSeekTapAt;

  /// Space is physically down; used to ignore auto-repeat and pair KeyUp.
  bool _spaceDown = false;

  /// True after Space KeyDown while waiting to see if it is a tap or a 2x hold.
  bool _spaceDeferToggle = false;

  /// After a side-hold 2x, ignore the tap that fires on finger-up.
  bool _suppressTapAfterBoost = false;
  Offset? _tapDown;

  /// −1 = left / rewind, +1 = right / forward.
  int? _seekBurstSide;
  int _seekBurstSeconds = 0;
  Duration? _seekTarget;
  DateTime? _dvrBurstWallClock;

  /// Relative step for the first seek of a DVR burst (`seekLiveDvrBy`).
  Duration? _dvrBurstFirstStep;

  /// True when [_seekTarget] / DVR wall-clock changed and needs an engine seek.
  bool _seekCommitDirty = false;
  StreamSubscription<double>? _rateSub;
  StreamSubscription<Duration>? _positionSub;
  double? _dvrDragProgress;

  /// True while the playhead thumb is held — keep chrome up for the whole scrub.
  bool _scrubbing = false;

  /// VOD overlay: left clock shows remaining (`-m:ss`) instead of elapsed.
  bool _showRemaining = false;
  MediaSegmentBundle? _segments;
  MediaSegment? _activeSegment;
  bool _autoSkipped = false;
  String? _segmentsItemId;

  /// Desktop only: keyboard target, volume OSD, and hover bookkeeping.
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'playerKeys');
  String? _volumeHint;
  Timer? _volumeHintTimer;
  DateTime? _lastHoverWake;
  DateTime? _lastPictureClickAt;

  /// Phone side-strip: right = volume, left = brightness.
  bool _stripActive = false;
  PlayerSideStripKind? _stripKind;
  Offset? _stripOrigin;
  double _stripBaseVolume = 100;
  double _stripBaseBrightness = 0.5;
  bool _brightnessStripReady = false;
  double? _pendingBrightnessDy;
  bool _didOverrideBrightness = false;
  IconData? _osdIcon;

  /// Center play/pause confirmation; null when hidden.
  bool? _playPauseFlashPlaying;
  int _playPauseFlashEpoch = 0;
  Timer? _playPauseFlashTimer;
  DateTime? _lastToggleAt;

  bool get _desktop => DesktopUi.enabled;

  static const _volumeStep = 5.0;

  @override
  void initState() {
    super.initState();
    // Rate stream does not replay the current value — seed from player state
    // so remounts (cinema toggle, engine rebuild) don't show 1x while mpv
    // is still at a boosted / previously chosen rate.
    final initialRate = widget.player.state.rate;
    _selectedRate = initialRate;
    _baseRate = initialRate;
    _armHideTimer();
    if (_desktop) {
      // Top of the stack: the pad drives playback while the player is open.
      GamepadService.instance.addHandler(_handleGamepad);
      GamepadService.instance.start();
      _keyboardFocus.addListener(_onKeyboardFocusChange);
    }
    _rateSub = widget.player.stream.rate.listen((rate) {
      if (!mounted) return;
      if (_holdingBoost || _boostRateInFlight) {
        // Live-edge snap (PlaybackProvider) may drop rate to 1x while the
        // finger is still down — clear the boost chrome to match, and keep
        // [_baseRate] at realtime so [_endHoldBoost] does not re-apply a
        // pre-hold catch-up speed on the live mount.
        if (rate <= 1.01 && context.read<PlaybackProvider>().isAtLiveEdge) {
          _baseRate = rate;
          _endHoldBoost();
        }
        return;
      }
      setState(() {
        _selectedRate = rate;
        _baseRate = rate;
      });
    });
    _positionSub = widget.player.stream.position.listen(_onPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadSegments());
    });
  }

  @override
  void didUpdateWidget(covariant GesturePlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _segments = null;
      _activeSegment = null;
      _autoSkipped = false;
      _showRemaining = false;
      unawaited(_loadSegments());
    }
    if (widget.error != null && oldWidget.error == null) {
      _hideTimer?.cancel();
      if (!_visible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_visible) setState(() => _visible = true);
        });
      }
    }
  }

  Future<void> _loadSegments() async {
    final item = context.read<PlaybackProvider>().item ?? widget.item;
    if (item.isLive) return;
    try {
      final library = context.read<LibraryProvider>();
      final bundle = await library.segmentsFor(item);
      if (!mounted) return;
      setState(() => _segments = bundle);
      _onPosition(widget.player.state.position);
    } catch (_) {}
  }

  void _onPosition(Duration position) {
    final bundle = _segments;
    if (bundle == null || bundle.segments.isEmpty) return;
    final active = bundle.activeAt(position);
    if (active?.type != _activeSegment?.type) {
      if (mounted) setState(() => _activeSegment = active);
    } else {
      _activeSegment = active;
    }
    if (active == null) {
      _autoSkipped = false;
      return;
    }
    final library = context.read<LibraryProvider>();
    final settings = library.skipSettings;
    final shouldAuto = switch (active.type) {
      MediaSegmentType.intro => settings.autoSkipIntro,
      MediaSegmentType.recap => settings.autoSkipRecap,
      MediaSegmentType.credits => settings.autoSkipCredits,
      MediaSegmentType.preview => false,
    };
    if (shouldAuto && !_autoSkipped && active.end != null) {
      _autoSkipped = true;
      unawaited(context.read<PlaybackProvider>().seekTo(active.end!));
    }
  }

  Future<void> _skipActiveSegment() async {
    final seg = _activeSegment;
    if (seg == null) return;
    final target = seg.end ?? seg.start + const Duration(seconds: 1);
    await context.read<PlaybackProvider>().seekTo(target);
    _armHideTimer();
  }

  String _skipLabel(MediaSegmentType type) {
    return switch (type) {
      MediaSegmentType.intro => context.l10n.skipIntro,
      MediaSegmentType.recap => context.l10n.skipRecap,
      MediaSegmentType.credits => context.l10n.skipCredits,
      MediaSegmentType.preview => context.l10n.skipPreview,
    };
  }

  /// Sheets must use the root navigator — [Video] controls live in a clipped
  /// overlay (especially portrait watch+browse), so a local sheet can dim the
  /// app while drawing the panel off-screen / zero-height.
  Future<T?> _showPlayerSheet<T>({
    required WidgetBuilder builder,
    bool isScrollControlled = true,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: isScrollControlled,
      backgroundColor: AppColors.surface,
      // A track list stretched across a 1280px window is mostly empty space;
      // keep the panel a readable width and let it centre itself.
      constraints: _desktop ? const BoxConstraints(maxWidth: 560) : null,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.85;
        return AnimatedPadding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          duration: const Duration(milliseconds: 100),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: builder(sheetContext),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekHintTimer?.cancel();
    _pendingChromeTimer?.cancel();
    _holdBoostTimer?.cancel();
    _spaceHoldTimer?.cancel();
    _volumeHintTimer?.cancel();
    _playPauseFlashTimer?.cancel();
    if (_desktop) {
      GamepadService.instance.removeHandler(_handleGamepad);
      _keyboardFocus.removeListener(_onKeyboardFocusChange);
    }
    _keyboardFocus.dispose();
    _rateSub?.cancel();
    _positionSub?.cancel();
    _seekTarget = null;
    _dvrBurstFirstStep = null;
    _seekCommitDirty = false;
    if (_holdingBoost) {
      // Best-effort restore; widget is going away.
      unawaited(widget.player.setRate(_baseRate));
      _holdingBoost = false;
      _holdBoostSources.clear();
      _boostRateInFlight = false;
    }
    if (_locked) {
      unawaited(_restorePlayerOrientations());
    }
    if (_didOverrideBrightness) {
      unawaited(ScreenBrightness.set(null));
    }
    super.dispose();
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    if (!_visible || _holdingBoost || _locked || _scrubbing) return;
    _hideTimer = Timer(_hideAfter, () {
      if (!mounted || _scrubbing) return;
      final playback = context.read<PlaybackProvider>();
      if (!playback.playing ||
          playback.isLoading ||
          playback.error != null ||
          playback.shouldAbandonSessionOnLeave) {
        return;
      }
      setState(() => _visible = false);
    });
  }

  /// Opening / error must keep the top chevron — PlayerScreen used to paint a
  /// second one on top of this bar while [shouldAbandonSessionOnLeave].
  void _ensureChromeWhileAbandoning(PlaybackProvider playback) {
    if (!playback.shouldAbandonSessionOnLeave || _visible || _locked) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _visible || _locked) return;
      if (!context.read<PlaybackProvider>().shouldAbandonSessionOnLeave) {
        return;
      }
      setState(() => _visible = true);
    });
  }

  void _beginScrub() {
    _hideTimer?.cancel();
    _scrubbing = true;
    if (!_visible && mounted) setState(() => _visible = true);
  }

  void _endScrub() {
    if (!_scrubbing) return;
    _scrubbing = false;
    if (mounted) _armHideTimer();
  }

  void _armLockHideTimer() {
    _hideTimer?.cancel();
    if (!_locked || !_lockChromeVisible) return;
    _hideTimer = Timer(_hideAfter, () {
      if (mounted && _locked) {
        setState(() => _lockChromeVisible = false);
      }
    });
  }

  void _toggleChrome() {
    if (_locked) return;
    setState(() => _visible = !_visible);
    if (_visible) _armHideTimer();
  }

  Future<void> _togglePlay({bool force = false}) async {
    if (_locked) return;
    final now = DateTime.now();
    if (!force &&
        !shouldAcceptPlayPauseToggle(now: now, lastToggleAt: _lastToggleAt)) {
      return;
    }
    _lastToggleAt = now;
    final playback = context.read<PlaybackProvider>();
    // Route through PlaybackProvider so live-edge pause can enter DVR on resume.
    // Don't await the engine — chrome is already optimistic.
    unawaited(playback.togglePlayPause());
    _armHideTimer();
  }

  void _flashPlayPause({required bool playing}) {
    _playPauseFlashTimer?.cancel();
    setState(() {
      _playPauseFlashEpoch++;
      _playPauseFlashPlaying = playing;
    });
    _playPauseFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _playPauseFlashPlaying = null);
    });
  }

  /// Chrome bars are sparse (Spacer, padding) and miss hits otherwise, so the
  /// fill play/pause detector behind them would fire. Opaque hit-testing keeps
  /// those clicks on the UI — only the picture toggles playback.
  Widget _absorbChromeHits(Widget child) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _armHideTimer(),
      child: child,
    );
  }

  int _sideFor(Offset? local) {
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    final x = local?.dx ?? width / 2;
    if (width <= 0) return 0;
    if (x < width / 3) return -1;
    if (x > width * 2 / 3) return 1;
    return 0;
  }

  void _clearSeekBurst({bool commitPending = false}) {
    if (commitPending) {
      _flushSeekCommit();
    } else {
      _seekCommitDirty = false;
    }
    _seekHintTimer?.cancel();
    _seekBurstSide = null;
    _seekBurstSeconds = 0;
    _seekTarget = null;
    _dvrBurstWallClock = null;
    _dvrBurstFirstStep = null;
    if (_seekHint != null && mounted) {
      setState(() => _seekHint = null);
    } else {
      _seekHint = null;
    }
  }

  /// Apply the latest burst target to the engine (VOD or live DVR).
  void _flushSeekCommit() {
    if (!_seekCommitDirty || !mounted) return;
    _seekCommitDirty = false;
    final playback = context.read<PlaybackProvider>();
    if (playback.canLiveDvr) {
      final first = _dvrBurstFirstStep;
      if (first != null) {
        _dvrBurstFirstStep = null;
        unawaited(playback.seekLiveDvrBy(first));
        return;
      }
      final wall = _dvrBurstWallClock;
      if (wall != null) {
        unawaited(playback.seekLiveDvrTo(wall));
      }
      return;
    }
    final target = _seekTarget;
    if (target != null) {
      unawaited(playback.seekTo(target));
    }
  }

  /// Burst seek: each call nudges ±[stepSeconds]; badge shows the running total.
  ///
  /// [keepChrome] stays true for ±10 transport buttons so the overlay does not
  /// dismiss mid-burst; double-tap seeks still hide chrome around the badge.
  ///
  /// Every nudge seeks immediately. The badge and [_seekTarget] still accumulate
  /// so a burst of +10 taps lands at +10 / +20 / +30 rather than re-reading a
  /// stale playhead between hops.
  Future<void> _nudgeSeek(
    int side, {
    bool keepChrome = false,
    int stepSeconds = _seekStepSeconds,
  }) async {
    if (_locked || side == 0) return;

    final continuing = _seekBurstSide == side;
    if (continuing) {
      _seekBurstSeconds += stepSeconds * side;
    } else {
      _seekBurstSide = side;
      _seekBurstSeconds = stepSeconds * side;
      _seekTarget = null;
      _dvrBurstWallClock = null;
      _dvrBurstFirstStep = null;
    }

    final step = Duration(seconds: stepSeconds * side);
    final playback = context.read<PlaybackProvider>();

    if (playback.canLiveDvr) {
      // Prefer in-clip relative seeks. Burst wall-clock is only used so rapid
      // taps accumulate before each seek finishes.
      if (_dvrBurstWallClock != null) {
        _dvrBurstWallClock = _dvrBurstWallClock!.add(step);
        _dvrBurstFirstStep = null;
      } else {
        _dvrBurstWallClock = playback.playbackWallClock.add(step);
        // First hop uses relative seek (better in-clip path); follow-ups use
        // absolute wall-clock via [_flushSeekCommit].
        _dvrBurstFirstStep = step;
      }
    } else {
      final base = _seekTarget ?? playback.position;
      final dur = playback.duration;
      final endMs = dur.inMilliseconds <= 0
          ? (base + step).inMilliseconds
          : dur.inMilliseconds;
      _seekTarget = Duration(
        milliseconds: (base + step).inMilliseconds.clamp(0, endMs),
      );
    }

    final abs = _seekBurstSeconds.abs();
    setState(() {
      _seekHint = _seekBurstSeconds < 0 ? '−${abs}s' : '+${abs}s';
      if (!keepChrome) _visible = false;
    });
    if (keepChrome) _armHideTimer();

    _seekCommitDirty = true;
    _flushSeekCommit();

    _seekHintTimer?.cancel();
    _seekHintTimer = Timer(kSeekDoubleTapWindow, () {
      if (!mounted) return;
      _flushSeekCommit();
      setState(() {
        _seekHint = null;
        _seekBurstSide = null;
        _seekBurstSeconds = 0;
        _seekTarget = null;
        _dvrBurstWallClock = null;
        _dvrBurstFirstStep = null;
      });
    });
  }

  Future<void> _seekBy(Duration delta) async {
    final seconds = delta.inSeconds.abs();
    await _nudgeSeek(
      delta.isNegative ? -1 : 1,
      keepChrome: true,
      stepSeconds: seconds == 0 ? _seekStepSeconds : seconds,
    );
  }

  void _cancelPendingChromeFromTap() {
    _pendingChromeTimer?.cancel();
    _pendingChromeTimer = null;
  }

  void _armPendingChromeFromTap() {
    _pendingChromeTimer?.cancel();
    _pendingChromeTimer = Timer(kSeekDoubleTapWindow, () {
      if (!mounted) return;
      _pendingChromeTimer = null;
      _pendingSeekTapSide = null;
      _pendingSeekTapAt = null;
      _toggleChrome();
    });
  }

  void _armHoldBoostAt(Offset local) {
    if (_locked || _holdBoostSources.contains(_HoldBoostSource.pointer)) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    final x = local.dx;
    if (width > 0 && x >= width / 3 && x <= width * 2 / 3) return;
    _beginHoldBoost(source: _HoldBoostSource.pointer);
  }

  /// Temporary 2x while a side-hold or Space-hold is active.
  ///
  /// [playIfPaused] matches YouTube: holding Space from pause starts playback
  /// at 2x, then release restores the previous rate (still playing).
  void _beginHoldBoost({
    bool playIfPaused = false,
    required _HoldBoostSource source,
  }) {
    if (_locked || _holdBoostSources.contains(source)) return;

    // Already boosting from another input — join without re-arming rate.
    if (_holdingBoost) {
      _holdBoostSources.add(source);
      // Only the pointer path synthesizes a tap on finger-up.
      if (source == _HoldBoostSource.pointer) {
        _suppressTapAfterBoost = true;
      }
      return;
    }

    final playback = context.read<PlaybackProvider>();
    // At the live edge, >1x only waits for the next published segment.
    if (playback.isAtLiveEdge) return;

    if (playIfPaused && !playback.playing) {
      unawaited(_togglePlay());
    }

    _hideTimer?.cancel();
    // Keep [_baseRate] as the last user/stream-confirmed rate. Do not read
    // player.state.rate — a quick release→re-hold can still see mpv at 2x
    // while restore is queued, which permanently sticks playback at hold
    // speed while the label stays on the pre-boost value (often 1x).
    _boostEpoch++;
    _boostRateInFlight = true;
    _holdBoostSources.add(source);
    // Show only the 2x badge — do not force chrome/scrim (dims top & bottom).
    setState(() {
      _holdingBoost = true;
      _visible = false;
      // Space never produces a finger-up tap; only suppress after side-hold.
      if (source == _HoldBoostSource.pointer) {
        _suppressTapAfterBoost = true;
      }
    });
    HapticFeedback.lightImpact();
    // Fire-and-forget: awaiting setRate delays UI and can feel like a hitch.
    unawaited(widget.player.setRate(_holdSpeed));
  }

  /// Drop one hold input; restore rate only when no sources remain.
  void _releaseHoldBoostSource(_HoldBoostSource source) {
    if (!_holdBoostSources.remove(source)) return;
    if (_holdBoostSources.isEmpty) {
      _endHoldBoost();
    }
  }

  void _endHoldBoost() {
    _holdBoostTimer?.cancel();
    _holdBoostTimer = null;
    _holdBoostSources.clear();
    if (!_holdingBoost) return;
    final atLiveEdge = context.read<PlaybackProvider>().isAtLiveEdge;
    final restore = holdBoostRestoreRate(
      atLiveEdge: atLiveEdge,
      baseRate: _baseRate,
    );
    if (restore != _baseRate) _baseRate = restore;
    final epoch = _boostEpoch;
    setState(() {
      _holdingBoost = false;
      // Keep the label on the user's rate immediately; don't wait for the
      // rate stream (and never leave it stuck on a transient 2x sample).
      _selectedRate = restore;
    });
    unawaited(
      widget.player.setRate(restore).whenComplete(() {
        if (epoch == _boostEpoch) _boostRateInFlight = false;
      }),
    );
    _armHideTimer();
  }

  void _onBoostPointerDown(Offset local) {
    _tapDown = local;
    _holdBoostTimer?.cancel();
    if (_locked || _holdBoostSources.contains(_HoldBoostSource.pointer)) {
      return;
    }
    if (_sideFor(local) == 0) return;
    _holdBoostTimer = Timer(_holdBoostDelay, () {
      if (!mounted || _stripActive) return;
      _armHoldBoostAt(local);
    });
  }

  void _onBoostPointerUp() {
    _holdBoostTimer?.cancel();
    _holdBoostTimer = null;
    if (_stripActive) {
      _endStrip();
      return;
    }
    _releaseHoldBoostSource(_HoldBoostSource.pointer);
  }

  bool get _sideStripEnabled =>
      !_desktop && !TvPlatform.isAndroidTv && !_locked;

  void _onStripPointerMove(PointerMoveEvent event) {
    if (!_sideStripEnabled) return;
    final origin = _stripOrigin ?? _tapDown;
    if (origin == null) return;
    final decision = playerSideStripDecision(
      touch:
          event.kind == PointerDeviceKind.touch ||
          event.kind == PointerDeviceKind.stylus,
      side: _sideFor(origin),
      dx: event.localPosition.dx - origin.dx,
      dy: event.localPosition.dy - origin.dy,
    );
    if (!decision.active) return;
    if (!_stripActive) {
      _holdBoostTimer?.cancel();
      _holdBoostTimer = null;
      if (_holdingBoost) _endHoldBoost();
      _stripActive = true;
      _stripKind = decision.kind;
      _stripOrigin = origin;
      _suppressTapAfterBoost = true;
      final playback = context.read<PlaybackProvider>();
      _stripBaseVolume = playback.volume;
      if (decision.kind == PlayerSideStripKind.brightness) {
        _brightnessStripReady = false;
        _pendingBrightnessDy = null;
        unawaited(_beginBrightnessStrip());
      } else {
        _brightnessStripReady = false;
        _pendingBrightnessDy = null;
      }
    }
    final dy = event.localPosition.dy - origin.dy;
    if (_stripKind == PlayerSideStripKind.brightness &&
        !_brightnessStripReady) {
      _pendingBrightnessDy = dy;
      return;
    }
    _applyStripDelta(dy);
  }

  Future<void> _beginBrightnessStrip() async {
    if (_stripKind != PlayerSideStripKind.brightness) return;
    final current = await ScreenBrightness.get();
    if (!mounted ||
        !_stripActive ||
        _stripKind != PlayerSideStripKind.brightness) {
      return;
    }
    _stripBaseBrightness = current ?? 0.5;
    _brightnessStripReady = true;
    final pending = _pendingBrightnessDy;
    _pendingBrightnessDy = null;
    if (pending != null) {
      _applyStripDelta(pending);
    }
  }

  void _applyStripDelta(double dy) {
    final height = context.size?.height ?? 0;
    if (_stripKind == PlayerSideStripKind.volume) {
      final next =
          (_stripBaseVolume + playerSideStripDelta(dy: dy, extent: height))
              .clamp(0.0, 100.0);
      unawaited(context.read<PlaybackProvider>().setVolume(next));
      _showOsd(
        next <= 0 ? context.l10n.muted : '${next.round()}%',
        icon: next <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
      );
      return;
    }
    if (_stripKind == PlayerSideStripKind.brightness) {
      final next =
          (_stripBaseBrightness +
                  playerSideStripDelta(dy: dy, extent: height, range: 1))
              .clamp(0.0, 1.0);
      _didOverrideBrightness = true;
      unawaited(ScreenBrightness.set(next));
      _showOsd('${(next * 100).round()}%', icon: Icons.wb_sunny_rounded);
    }
  }

  void _endStrip() {
    _stripActive = false;
    _stripKind = null;
    _stripOrigin = null;
    _brightnessStripReady = false;
    _pendingBrightnessDy = null;
  }

  // ---------------------------------------------------------------- desktop

  /// Mouse/keyboard activity: bring chrome back and restart the hide timer.
  void _wakeChrome() {
    if (_locked) {
      if (!_lockChromeVisible) setState(() => _lockChromeVisible = true);
      _armLockHideTimer();
      return;
    }
    if (!_visible) {
      setState(() => _visible = true);
    }
    _armHideTimer();
  }

  void _onMouseHover(PointerHoverEvent event) {
    if (!_desktop || event.kind != PointerDeviceKind.mouse) return;
    if (!_keyboardFocus.hasFocus && _keyboardFocus.canRequestFocus) {
      _keyboardFocus.requestFocus();
    }
    // Chrome hidden → any movement should reveal it immediately.
    if (!_visible || (_locked && !_lockChromeVisible)) {
      _lastHoverWake = DateTime.now();
      _wakeChrome();
      return;
    }
    // Visible already: only re-arm the timer periodically, not per motion event.
    final last = _lastHoverWake;
    final now = DateTime.now();
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastHoverWake = now;
    if (_locked) {
      _armLockHideTimer();
    } else {
      _armHideTimer();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!_desktop || _locked) return;
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    unawaited(_nudgeVolume(dy < 0 ? _volumeStep : -_volumeStep));
  }

  Future<void> _nudgeVolume(double delta) async {
    final playback = context.read<PlaybackProvider>();
    final level = await playback.nudgeVolume(delta);
    _showVolumeHint(level <= 0 ? context.l10n.muted : '${level.round()}%');
  }

  Future<void> _toggleMute() async {
    final playback = context.read<PlaybackProvider>();
    await playback.toggleMute();
    _showVolumeHint(
      playback.isMuted ? context.l10n.muted : '${playback.volume.round()}%',
    );
  }

  void _showVolumeHint(String text) {
    _showOsd(
      text,
      icon: text == context.l10n.muted
          ? Icons.volume_off_rounded
          : Icons.volume_up_rounded,
    );
  }

  void _showOsd(String text, {required IconData icon}) {
    if (!mounted) return;
    setState(() {
      _volumeHint = text;
      _osdIcon = icon;
    });
    _volumeHintTimer?.cancel();
    _volumeHintTimer = Timer(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      setState(() {
        _volumeHint = null;
        _osdIcon = null;
      });
    });
  }

  /// Percent seek (`0`–`9`); ignored for live wall-clock scrubbing.
  Future<void> _seekToFraction(double fraction) async {
    if (_locked) return;
    final playback = context.read<PlaybackProvider>();
    if (playback.canLiveDvr) return;
    final duration = playback.duration;
    if (duration.inMilliseconds <= 0) return;
    _clearSeekBurst();
    await playback.seekTo(
      Duration(
        milliseconds: (duration.inMilliseconds * fraction.clamp(0.0, 1.0))
            .round(),
      ),
    );
  }

  void _exitCinemaOrLeave() {
    final playback = context.read<PlaybackProvider>();
    if (playback.shouldAbandonSessionOnLeave) {
      (widget.onMinimize ?? widget.onClose)?.call();
      return;
    }
    if (playback.cinemaMode) {
      widget.onToggleCinema?.call();
      return;
    }
    (widget.onMinimize ?? widget.onClose)?.call();
  }

  static const _digitKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  void _onKeyboardFocusChange() {
    if (!_keyboardFocus.hasFocus && _spaceDown) {
      _onSpaceKeyUp();
    }
  }

  void _onSpaceKeyDown() {
    if (_spaceDown) return;
    _spaceDown = true;
    _spaceDeferToggle = false;
    if (_locked) return;
    final playback = context.read<PlaybackProvider>();
    if (!desktopSpaceHoldBoostEnabled(
      locked: _locked,
      atLiveEdge: playback.isAtLiveEdge,
    )) {
      _wakeChrome();
      unawaited(_togglePlay());
      return;
    }
    _spaceDeferToggle = true;
    _spaceHoldTimer?.cancel();
    _spaceHoldTimer = Timer(_holdBoostDelay, () {
      if (!mounted || !_spaceDown || !_spaceDeferToggle) return;
      _spaceDeferToggle = false;
      _beginHoldBoost(playIfPaused: true, source: _HoldBoostSource.space);
    });
  }

  void _onSpaceKeyUp() {
    if (!_spaceDown) return;
    _spaceDown = false;
    _spaceHoldTimer?.cancel();
    _spaceHoldTimer = null;
    if (_holdBoostSources.contains(_HoldBoostSource.space)) {
      _releaseHoldBoostSource(_HoldBoostSource.space);
      return;
    }
    if (!_spaceDeferToggle) return;
    _spaceDeferToggle = false;
    _wakeChrome();
    unawaited(_togglePlay());
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_desktop) return KeyEventResult.ignored;
    if (desktopPlayerKeyHasModifier(event)) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        _onSpaceKeyDown();
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (event is KeyUpEvent) {
        _onSpaceKeyUp();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final repeat = event is KeyRepeatEvent;
    if (event is! KeyDownEvent && !repeat) return KeyEventResult.ignored;

    // Seek / volume may repeat while held; everything else fires once.
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      _wakeChrome();
      unawaited(_seekBy(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyL) {
      _wakeChrome();
      unawaited(_seekBy(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(_nudgeVolume(_volumeStep));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_nudgeVolume(-_volumeStep));
      return KeyEventResult.handled;
    }
    if (repeat) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.keyK ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _wakeChrome();
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      unawaited(_toggleMute());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11) {
      widget.onToggleCinema?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _exitCinemaOrLeave();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyP) {
      unawaited(context.read<PlaybackProvider>().enterPip());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      widget.onCaptionSettings?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      unawaited(_openSettings());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash ||
        key == LogicalKeyboardKey.question ||
        key == LogicalKeyboardKey.f1) {
      unawaited(_showShortcutsSheet());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.period || key == LogicalKeyboardKey.greater) {
      _stepSpeed(1);
      _wakeChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.comma || key == LogicalKeyboardKey.less) {
      _stepSpeed(-1);
      _wakeChrome();
      return KeyEventResult.handled;
    }
    final digit = _digitKeys.indexOf(key);
    if (digit >= 0) {
      _wakeChrome();
      unawaited(_seekToFraction(digit / 10));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Controller mapping while the player is open.
  ///
  /// Mirrors the keyboard set so muscle memory carries over: A play/pause,
  /// B leave, Y fullscreen, X mute, D-pad seek and volume, shoulders step
  /// speed, triggers jump a minute, Start opens tracks.
  bool _handleGamepad(GamepadAction action) {
    if (!mounted) return false;
    switch (action) {
      case GamepadAction.activate:
        _wakeChrome();
        unawaited(_togglePlay());
      case GamepadAction.back:
      case GamepadAction.view:
        _exitCinemaOrLeave();
      case GamepadAction.tertiary:
        widget.onToggleCinema?.call();
      case GamepadAction.secondary:
        unawaited(_toggleMute());
      case GamepadAction.left:
        _wakeChrome();
        unawaited(_seekBy(const Duration(seconds: -10)));
      case GamepadAction.right:
        _wakeChrome();
        unawaited(_seekBy(const Duration(seconds: 10)));
      case GamepadAction.up:
        unawaited(_nudgeVolume(_volumeStep));
      case GamepadAction.down:
        unawaited(_nudgeVolume(-_volumeStep));
      case GamepadAction.shoulderLeft:
        _stepSpeed(-1);
        _wakeChrome();
      case GamepadAction.shoulderRight:
        _stepSpeed(1);
        _wakeChrome();
      case GamepadAction.triggerLeft:
        _wakeChrome();
        unawaited(_seekBy(const Duration(seconds: -60)));
      case GamepadAction.triggerRight:
        _wakeChrome();
        unawaited(_seekBy(const Duration(seconds: 60)));
      case GamepadAction.menu:
        unawaited(_openSettings());
    }
    return true;
  }

  /// Desktop click on the picture = play/pause (chrome toggling is a touch
  /// idiom). Clicks on the control bars are absorbed by [_absorbChromeHits].
  ///
  /// Do not register [GestureDetector.onDoubleTap] here: Flutter delays
  /// [onTap] until the double-click timeout when both are set, which is why
  /// picture-click pause lagged the transport button. A second click inside
  /// [kDesktopPictureDoubleClickWindow] reverts that toggle and goes
  /// fullscreen instead.
  void _handleDesktopTap() {
    if (_suppressTapAfterBoost) {
      _suppressTapAfterBoost = false;
      return;
    }
    if (_locked) {
      setState(() => _lockChromeVisible = !_lockChromeVisible);
      _armLockHideTimer();
      return;
    }
    final now = DateTime.now();
    final last = _lastPictureClickAt;
    _lastPictureClickAt = now;
    if (isDesktopPictureDoubleClick(now: now, lastClickAt: last)) {
      unawaited(_togglePlay(force: true));
      _playPauseFlashTimer?.cancel();
      if (_playPauseFlashPlaying != null) {
        setState(() => _playPauseFlashPlaying = null);
      }
      widget.onToggleCinema?.call();
      return;
    }
    _wakeChrome();
    final playback = context.read<PlaybackProvider>();
    _flashPlayPause(playing: !playback.playing);
    unawaited(_togglePlay());
  }

  Future<void> _showShortcutsSheet() async {
    _hideTimer?.cancel();
    if (!_visible && mounted) setState(() => _visible = true);
    final l10n = context.l10n;
    final rows = <(String, String)>[
      ('Space / K', '${l10n.play} · ${l10n.pause}'),
      ('Hold Space', l10n.holdSpaceFor2x),
      ('← →  /  J L', l10n.seekBackForward),
      ('↑ ↓', l10n.volume),
      ('M', l10n.mute),
      ('F  /  Esc', '${l10n.fullscreen} · ${l10n.exitFullscreen}'),
      ('P', l10n.pictureInPicture),
      (', .', l10n.playbackSpeed),
      ('S', l10n.audioAndSubtitles),
      ('C', l10n.captionStyle),
      ('0–9', l10n.jumpToPercent),
      ('? / F1', l10n.keyboardShortcuts),
    ];
    await _showPlayerSheet<void>(
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  l10n.keyboardShortcuts,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 12),
              for (final (keys, label) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 116,
                        child: Text(
                          keys,
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          label,
                          style: const TextStyle(color: AppColors.text),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    _armHideTimer();
  }

  Future<void> _showDesktopContextMenu(Offset globalPosition) async {
    if (_locked) return;
    _wakeChrome();
    final l10n = context.l10n;
    final playback = context.read<PlaybackProvider>();
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final playing = playback.playing;
    final selected = await showMenu<String>(
      context: context,
      color: AppColors.surface,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'play',
          child: Row(
            children: [
              Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 18,
                color: AppColors.text,
              ),
              const SizedBox(width: 10),
              Text(playing ? l10n.pause : l10n.play),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'cinema',
          child: Row(
            children: [
              Icon(
                playback.cinemaMode
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                size: 18,
                color: AppColors.text,
              ),
              const SizedBox(width: 10),
              Text(playback.cinemaMode ? l10n.exitFullscreen : l10n.fullscreen),
            ],
          ),
        ),
        if (!playback.cinemaMode && widget.onToggleBrowsePanel != null)
          PopupMenuItem(
            value: 'browse',
            child: Row(
              children: [
                Icon(
                  playback.browsePanelCollapsed
                      ? Icons.view_sidebar_rounded
                      : Icons.view_sidebar_outlined,
                  size: 18,
                  color: AppColors.text,
                ),
                const SizedBox(width: 10),
                Text(
                  playback.browsePanelCollapsed
                      ? l10n.showBrowsePanel
                      : l10n.hideBrowsePanel,
                ),
              ],
            ),
          ),
        if (playback.canEnterPip)
          PopupMenuItem(
            value: 'pip',
            child: Row(
              children: [
                const Icon(
                  Icons.picture_in_picture_alt_rounded,
                  size: 18,
                  color: AppColors.text,
                ),
                const SizedBox(width: 10),
                Text(l10n.pictureInPicture),
              ],
            ),
          ),
        if (AppCapabilities.multiView && widget.item.isLive)
          PopupMenuItem(
            value: 'multiview',
            child: Row(
              children: [
                Icon(
                  context.read<MultiViewProvider>().isActive
                      ? Icons.view_agenda_rounded
                      : Icons.view_column_rounded,
                  size: 18,
                  color: AppColors.text,
                ),
                const SizedBox(width: 10),
                Text(
                  context.read<MultiViewProvider>().isActive
                      ? l10n.multiViewExit
                      : l10n.multiViewEnter,
                ),
              ],
            ),
          ),
        if (AppCapabilities.multiView &&
            context.read<MultiViewProvider>().isActive)
          PopupMenuItem(
            value: 'multiview_audio',
            child: Row(
              children: [
                const Icon(
                  Icons.swap_horiz_rounded,
                  size: 18,
                  color: AppColors.text,
                ),
                const SizedBox(width: 10),
                Text(l10n.multiViewSwapAudio),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'speed',
          child: Row(
            children: [
              const Icon(Icons.speed_rounded, size: 18, color: AppColors.text),
              const SizedBox(width: 10),
              Text(
                '${l10n.playbackSpeed} (${formatPlaybackRateLabel(_selectedRate)})',
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          child: Row(
            children: [
              const Icon(Icons.tune_rounded, size: 18, color: AppColors.text),
              const SizedBox(width: 10),
              Text(l10n.audioAndSubtitles),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'captions',
          child: Row(
            children: [
              const Icon(
                Icons.closed_caption_rounded,
                size: 18,
                color: AppColors.text,
              ),
              const SizedBox(width: 10),
              Text(l10n.captionStyle),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'shortcuts',
          child: Row(
            children: [
              const Icon(
                Icons.keyboard_rounded,
                size: 18,
                color: AppColors.text,
              ),
              const SizedBox(width: 10),
              Text(l10n.keyboardShortcuts),
            ],
          ),
        ),
      ],
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case 'play':
        await _togglePlay();
      case 'cinema':
        widget.onToggleCinema?.call();
      case 'browse':
        widget.onToggleBrowsePanel?.call();
      case 'pip':
        await _enterPip();
      case 'multiview':
        await openMultiViewFromContext(context);
      case 'multiview_audio':
        await context.read<MultiViewProvider>().swapAudio();
      case 'speed':
        await _pickSpeed();
      case 'settings':
        await _openSettings();
      case 'captions':
        widget.onCaptionSettings?.call();
      case 'shortcuts':
        await _showShortcutsSheet();
    }
  }

  void _handleTap() {
    if (_suppressTapAfterBoost) {
      _suppressTapAfterBoost = false;
      return;
    }
    if (_locked) {
      setState(() => _lockChromeVisible = !_lockChromeVisible);
      if (_lockChromeVisible) _armLockHideTimer();
      return;
    }
    // Immediate onTap (no onDoubleTap recognizer). First skip is two taps
    // on the same side; follow-ups skip without waiting out a double-tap
    // timeout. Desktop picture-click pause lives in [_handleDesktopTap].
    final side = _sideFor(_tapDown);
    final now = DateTime.now();
    switch (playerSeekTapAction(
      side: side,
      burstSide: _seekBurstSide,
      pendingSide: _pendingSeekTapSide,
      pendingAt: _pendingSeekTapAt,
      now: now,
    )) {
      case PlayerSeekTapAction.seek:
        _cancelPendingChromeFromTap();
        _pendingSeekTapSide = side;
        _pendingSeekTapAt = now;
        unawaited(_nudgeSeek(side));
      case PlayerSeekTapAction.toggleChromeNow:
        _cancelPendingChromeFromTap();
        _pendingSeekTapSide = null;
        _pendingSeekTapAt = null;
        if (_seekBurstSide != null || _seekHint != null) {
          _clearSeekBurst(commitPending: true);
        }
        _toggleChrome();
      case PlayerSeekTapAction.scheduleChrome:
        _pendingSeekTapSide = side;
        _pendingSeekTapAt = now;
        _armPendingChromeFromTap();
    }
  }

  void _setLocked(bool locked) {
    setState(() {
      _locked = locked;
      if (locked) {
        _visible = false;
        _lockChromeVisible = true;
      } else {
        _lockChromeVisible = false;
        _visible = true;
      }
    });
    unawaited(_syncLockOrientation(locked));
    if (locked) {
      _armLockHideTimer();
    } else {
      _armHideTimer();
    }
  }

  Future<void> _syncLockOrientation(bool locked) async {
    if (locked) {
      final portrait =
          MediaQuery.orientationOf(context) == Orientation.portrait;
      await SystemChrome.setPreferredOrientations(
        portrait
            ? const [DeviceOrientation.portraitUp]
            : const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ],
      );
      return;
    }
    await _restorePlayerOrientations();
  }

  Future<void> _restorePlayerOrientations() {
    // Match expanded-player immersive defaults (portrait + landscape).
    return SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
  }

  void _setRate(double rate) {
    _baseRate = rate;
    setState(() => _selectedRate = rate);
    unawaited(widget.player.setRate(rate));
  }

  void _cycleSpeed() => _stepSpeed(1);

  void _stepSpeed(int direction) {
    final cycle = context.read<LibraryProvider>().cyclePlaybackSpeeds;
    _setRate(
      stepPlaybackSpeed(
        current: _selectedRate,
        direction: direction,
        cycle: cycle,
      ),
    );
    _armHideTimer();
  }

  Future<void> _enterPip() async {
    final playback = context.read<PlaybackProvider>();
    final ok = await playback.enterPip();
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.pictureInPictureFailed)),
    );
  }

  Future<void> _openSettings() async {
    if (_locked) return;
    _hideTimer?.cancel();
    if (!_visible && mounted) setState(() => _visible = true);
    await showPlayerOverlaySheet<void>(
      context: context,
      builder: (sheetContext) => PlayerSettingsPanel(
        item: widget.item,
        desktop: _desktop,
        hostContext: context,
        onLock: () => _setLocked(true),
        onCaptionSettings: widget.onCaptionSettings,
        onShortcuts: _desktop
            ? () {
                unawaited(_showShortcutsSheet());
              }
            : null,
      ),
    );
    if (mounted) _armHideTimer();
  }

  void _toggleVodRemaining() {
    setState(() => _showRemaining = !_showRemaining);
    _armHideTimer();
  }

  Future<void> _toggleLiveScrubMode() async {
    final library = context.read<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    if (!playback.canLiveDvr || playback.currentProgram == null) return;
    final next = library.liveScrubMode == LiveScrubMode.timeline
        ? LiveScrubMode.program
        : LiveScrubMode.timeline;
    await library.setLiveScrubMode(next);
    _armHideTimer();
  }

  Future<void> _startOver() async {
    final playback = context.read<PlaybackProvider>();
    final ok = await playback.startOverCurrentProgram();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.startOverUnavailable)),
      );
    }
    _armHideTimer();
  }

  Future<void> _openNearbyPrograms() async {
    if (_locked) return;
    final playback = context.read<PlaybackProvider>();
    final channel = playback.liveChannel;
    if (channel == null) return;

    _hideTimer?.cancel();
    final library = context.read<LibraryProvider>();
    unawaited(library.fetchChannelGuide(channel));

    await _showPlayerSheet<void>(
      builder: (context) {
        return _NearbyProgramsSheet(
          channel: channel,
          formatWindow: _fmtProgramWindow,
          formatDay: _fmtDayLabel,
          onSelect: (program) async {
            Navigator.pop(context);
            await _playGuideProgram(channel, program);
          },
        );
      },
    );
    if (mounted) _armHideTimer();
  }

  Future<void> _playGuideProgram(MediaItem channel, EpgProgram program) async {
    final playback = context.read<PlaybackProvider>();
    final library = context.read<LibraryProvider>();
    final now = DateTime.now();

    if (program.isAiringAt(now)) {
      // NOW row → live edge. Start Over remains an explicit action.
      await playback.jumpToLive();
      return;
    }

    if (program.start.isAfter(now)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.startsAt(_fmtClock(program.start))),
        ),
      );
      return;
    }

    // Past programme — prefer DVR seek when catchup is available.
    if (playback.canLiveDvr) {
      await playback.seekLiveDvrTo(program.start);
      return;
    }

    final item = await library.catchupItemAsync(
      channel: channel,
      program: program,
    );
    if (item == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.catchupUnavailable)));
      return;
    }
    await playback.open(item, expand: true);
  }

  Future<void> _pickSpeed() async {
    final library = context.read<LibraryProvider>();
    final chosen = await showPlayerOverlaySheet<double>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              final cycle = library.cyclePlaybackSpeeds;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.playbackSpeed,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                          color: AppColors.textMuted,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Text(
                      context.l10n.playbackSpeedCycleHint,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final speed in kPlaybackSpeeds)
                          ListTile(
                            dense: true,
                            leading: Checkbox(
                              value: cycleContainsPlaybackSpeed(cycle, speed),
                              activeColor: AppColors.accent,
                              onChanged: (_) {
                                unawaited(
                                  library.setCyclePlaybackSpeeds(
                                    toggleCyclePlaybackSpeed(cycle, speed),
                                  ),
                                );
                                setSheetState(() {});
                              },
                            ),
                            title: Text(formatPlaybackRateLabel(speed)),
                            trailing: playbackRatesEqual(speed, _selectedRate)
                                ? const Icon(
                                    Icons.check,
                                    color: AppColors.accent,
                                  )
                                : null,
                            onTap: () => Navigator.pop(context, speed),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
    if (chosen != null) _setRate(chosen);
    _armHideTimer();
  }

  String _fmt(Duration d) => formatPlayerClock(d, padMinutes: false);

  String _fmtClock(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Day label for multi-day catchup lists (Today · Sun 9 Aug / Wed 6 Aug).
  String _fmtDayLabel(DateTime dt, {DateTime? relativeTo}) {
    final local = dt.toLocal();
    final now = (relativeTo ?? DateTime.now()).toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final stamped =
        '${weekdays[local.weekday - 1]} ${local.day} ${months[local.month - 1]}';
    if (diff == 0) {
      return context.l10n.todayStamp(stamped);
    }
    if (diff == -1) {
      return context.l10n.yesterdayStamp(stamped);
    }
    if (diff == 1) {
      return context.l10n.tomorrowStamp(stamped);
    }
    return stamped;
  }

  String _fmtProgramWindow(DateTime start, DateTime end) {
    final startDay = _fmtDayLabel(start);
    final startT = _fmtClock(start);
    final endT = _fmtClock(end);
    final s = start.toLocal();
    final e = end.toLocal();
    final sameDay = s.year == e.year && s.month == e.month && s.day == e.day;
    if (sameDay) return '$startDay · $startT–$endT';
    return '$startDay $startT – ${_fmtDayLabel(end)} $endT';
  }

  /// Clock with date when the wall time is not today (multi-day DVR scrub).
  String _fmtClockWithDay(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now().toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final clock = _fmtClock(dt);
    if (day == today) return clock;
    return '${_fmtDayLabel(dt)} $clock';
  }

  String _fmtDelay(Duration d) {
    if (d.inSeconds <= 0) return context.l10n.liveBadge;
    return '-${_fmt(d)}';
  }

  /// Delay behind live + programme title for the scrub/playhead target.
  ///
  /// Uses wall-clock [delay] (not scrub progress). A fractional near-live
  /// progress gate (e.g. 0.985 of a multi-hour window) hid small nudges like
  /// −10s even though we were already timeshifted.
  String _fmtDvrLabel(Duration delay, {EpgProgram? program}) {
    if (delay.inSeconds <= 0) {
      return program != null
          ? 'DVR · ${program.title}'
          : context.l10n.dvrScrubHint;
    }
    final wall = DateTime.now().subtract(delay);
    // Lead with -mm:ss so the delay stays visible even when title is long.
    final delayPart = '${_fmtDelay(delay)} (${_fmtClockWithDay(wall)})';
    if (program == null) return delayPart;
    return '${_fmtDelay(delay)} · ${program.title} (${_fmtClockWithDay(wall)})';
  }

  /// Programme scrub label: title + playhead wall-clock (and delay when timeshifted).
  ///
  /// [dragProgress] is 0…1 of the current programme (start → end).
  String _fmtProgramScrubLabel({
    required EpgProgram program,
    required DateTime wall,
    required bool atLive,
    Duration liveDelay = Duration.zero,
    double? dragProgress,
    double liveFraction = 1.0,
  }) {
    final DateTime clock;
    final totalMs = program.duration.inMilliseconds;
    if (dragProgress != null && totalMs > 0) {
      final absProg = dragProgress.clamp(0.0, liveFraction.clamp(0.0, 1.0));
      clock = program.start.add(
        Duration(milliseconds: (totalMs * absProg).round()),
      );
    } else {
      clock = wall;
    }
    final time = _fmtClockWithDay(clock);
    if (atLive || liveDelay.inSeconds <= 0) {
      return 'LIVE · ${program.title} · $time';
    }
    return '${_fmtDelay(liveDelay)} · ${program.title} · $time';
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    // The position stream notifies several times a second. Only rebuild this
    // outer shell for discrete state changes; everything that moves with the
    // playhead lives inside the StreamBuilders below.
    context.select<PlaybackProvider, int>(
      (p) => Object.hash(
        Object.hash(p.isInPip, p.canEnterPip),
        p.suggestLowerQuality,
        (p.liveChannel ?? p.item ?? widget.item).id,
        p.canLiveDvr,
        p.isAtLiveEdge,
        p.usesProgramScrubber,
        p.canStartOver,
        p.previousEpisode?.id,
        p.nextEpisode?.id,
        p.currentProgram?.start,
        p.nextProgram?.start,
        // Desktop volume chrome (phones use hardware keys).
        p.volume,
        p.isMuted,
        p.hasSleepTimer,
        p.sleepRemaining?.inMinutes,
        p.sleepTimerFired,
        p.playing,
        p.isLoading,
        p.error,
        p.shouldAbandonSessionOnLeave,
      ),
    );
    _ensureChromeWhileAbandoning(playback);
    final sessionItem = playback.item ?? widget.item;
    if (_segmentsItemId != sessionItem.id) {
      _segmentsItemId = sessionItem.id;
      _segments = null;
      _activeSegment = null;
      _autoSkipped = false;
      _showRemaining = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadSegments());
      });
    }
    final sessionError = playback.error ?? widget.error;
    // System PiP shows only the video texture — hide all Flutter chrome.
    if (playback.isInPip) {
      return const SizedBox.expand();
    }
    // Rebuild when scrub mode / catalog (quality families, source names)
    // change — but not for every download tick, EPG merge or sync status
    // update, which used to redraw the whole overlay mid-playback.
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.liveScrubMode,
        l.liveDbRevision,
        l.liveIndexRevision,
        l.catalog.length,
        l.epgRevision,
        l.mediaServerStreamQuality,
        l.cast.isCasting,
      ),
    );
    final library = context.read<LibraryProvider>();
    final canDvr = playback.canLiveDvr;
    final useProgramScrub = playback.usesProgramScrubber;
    final displayItem = playback.liveChannel ?? playback.item ?? widget.item;
    final liveForQuality =
        displayItem.isLive || displayItem.kind == MediaKind.catchup
        ? library.resolveLiveChannel(displayItem)
        : displayItem;
    final msQuality = playback.canPickMediaServerQuality
        ? playback.mediaServerStreamQuality
        : null;
    final multiQuality =
        msQuality != null ||
        ((displayItem.isLive || displayItem.kind == MediaKind.catchup) &&
            library.qualityVariantsFor(liveForQuality).length > 1);
    final qualitySourceLabel = msQuality != null
        ? library.sourceLabelFor(displayItem)
        : (multiQuality ? library.sourceLabelFor(liveForQuality) : null);
    final qualityLabel = msQuality != null
        ? msQuality.localizedLabel(context.l10n)
        : (multiQuality ? ChannelQuality.labelFor(liveForQuality) : null);
    final sleepLeft = playback.sleepRemaining;
    final sleepLabel = sleepLeft == null
        ? null
        : '${context.l10n.sleepTimer} · ${context.l10n.minutesLeft((sleepLeft.inSeconds / 60).ceil().clamp(1, 999))}';
    final topQualityLabel = () {
      final parts = <String>[
        if (qualityLabel != null && qualityLabel.trim().isNotEmpty)
          qualityLabel.trim(),
        if (sleepLabel != null) sleepLabel,
      ];
      return parts.isEmpty ? null : parts.join(' · ');
    }();
    final current = playback.currentProgram;
    final next = playback.nextProgram;
    final playing = playback.playing;
    final casting = library.cast.isCasting;
    final playingItem = playback.item ?? widget.item;
    final showEpgChrome =
        displayItem.isLive || displayItem.kind == MediaKind.catchup;
    final dvrChannel =
        playback.liveChannel ??
        (displayItem.isLive
            ? displayItem
            : library.liveChannelForCatchup(playingItem));
    final dvrProgram =
        current ??
        (playingItem.kind == MediaKind.catchup
            ? library.programForCatchup(playingItem)
            : null);
    final canDvrDownloadWithGuide =
        dvrChannel != null &&
        dvrProgram != null &&
        (library.liveSupportsCatchup(dvrChannel) || dvrProgram.hasArchive);
    final canDvrDownloadWithoutGuide =
        dvrChannel != null &&
        dvrProgram == null &&
        library.liveSupportsCatchup(dvrChannel);
    final canDvrDownload =
        canDvrDownloadWithGuide || canDvrDownloadWithoutGuide;
    final downloadItem =
        !canDvrDownload && isDownloadActionAvailable(playingItem)
        ? playingItem
        : null;

    final surface = Stack(
      fit: StackFit.expand,
      children: [
        // Behind chrome so onDoubleTap/onTap cannot steal IconButton presses
        // (chevron, settings, transport). Hidden chrome → IgnorePointer lets
        // taps fall through to this layer.
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              // Right/middle click must not arm hold-to-2x.
              if (_desktop && e.buttons != kPrimaryButton) return;
              _stripOrigin = e.localPosition;
              _onBoostPointerDown(e.localPosition);
            },
            onPointerMove: _onStripPointerMove,
            onPointerUp: (_) => _onBoostPointerUp(),
            onPointerCancel: (_) => _onBoostPointerUp(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (details) {
                _tapDown = details.localPosition;
                if (_desktop) _keyboardFocus.requestFocus();
              },
              // No onDoubleTap: it delays onTap and swallows skip chaining.
              // Phones skip in [_handleTap]; desktop pauses in [_handleDesktopTap].
              onTap: _desktop ? _handleDesktopTap : _handleTap,
              onSecondaryTapUp: _desktop
                  ? (details) => unawaited(
                      _showDesktopContextMenu(details.globalPosition),
                    )
                  : null,
            ),
          ),
        ),
        IgnorePointer(
          child: AnimatedOpacity(
            // Hold-boost must not revive this scrim — it dims the frame edges.
            opacity: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x99000000),
                    Color(0x00000000),
                    Color(0x00000000),
                    Color(0xB3000000),
                  ],
                  stops: [0, 0.28, 0.62, 1],
                ),
              ),
            ),
          ),
        ),

        if (_holdingBoost)
          const Align(alignment: Alignment(0, -0.55), child: _BoostBadge()),

        if (_playPauseFlashPlaying != null)
          IgnorePointer(
            child: Center(
              child: _PlayPauseFlash(
                key: ValueKey(_playPauseFlashEpoch),
                playing: _playPauseFlashPlaying!,
              ),
            ),
          ),

        if (_volumeHint != null)
          IgnorePointer(
            child: Align(
              alignment: const Alignment(0, -0.7),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _osdIcon ??
                          (_volumeHint == context.l10n.muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded),
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _volumeHint!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        if (_seekHint != null)
          IgnorePointer(
            child: Align(
              alignment: (_seekBurstSide ?? 1) < 0
                  ? const Alignment(-0.55, 0)
                  : const Alignment(0.55, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (_seekBurstSide ?? 1) < 0
                          ? Icons.replay_10_rounded
                          : Icons.forward_10_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _seekHint!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        if (sessionError != null)
          PlayerErrorOverlay(
            error: sessionError,
            onRetry: widget.onRetry,
            onBack: widget.onMinimize ?? widget.onClose,
          ),

        // Open / resolve / rebuffer chrome lives on PlayerScreen
        // (PlayerLoadingBadge — one continuous spinner; label only updates).
        // Painting another spinner here stacked a second anonymous indicator.

        // Soft tip — doesn't block the spinner / error chrome.
        if (playback.suggestLowerQuality)
          Positioned(
            left: 16,
            right: 16,
            bottom: 28,
            child: const Align(
              alignment: Alignment.bottomCenter,
              child: SlowLoadQualityPrompt(),
            ),
          ),

        AnimatedOpacity(
          opacity: _visible && !_locked ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: IgnorePointer(
            ignoring: !_visible || _locked,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _absorbChromeHits(
                    _TopBar(
                      item: displayItem,
                      nowPlaying: showEpgChrome ? current : null,
                      nextProgram: showEpgChrome ? next : null,
                      formatClock: showEpgChrome ? _fmtClock : null,
                      sourceLabel: qualitySourceLabel,
                      qualityLabel: topQualityLabel,
                      downloadItem: downloadItem,
                      onDvrDownload: canDvrDownload
                          ? () {
                              final resolved = library.resolveLiveChannel(
                                dvrChannel,
                              );
                              if (dvrProgram != null) {
                                unawaited(
                                  showDvrDownloadPadDialog(
                                    context: context,
                                    channel: resolved,
                                    program: dvrProgram,
                                  ),
                                );
                              } else {
                                unawaited(
                                  showCatchupRecordDialog(
                                    context: context,
                                    channel: resolved,
                                    initialStart:
                                        playingItem.kind == MediaKind.catchup
                                        ? LibraryProvider.catchupStartOf(
                                            playingItem,
                                          )
                                        : null,
                                    initialDurationMin:
                                        playingItem.kind == MediaKind.catchup
                                        ? playingItem.duration?.inMinutes
                                        : null,
                                    initialTitle:
                                        playingItem.kind == MediaKind.catchup
                                        ? playingItem.title
                                        : null,
                                  ),
                                );
                              }
                            }
                          : null,
                      onClose: () {
                        _hideTimer?.cancel();
                        (widget.onMinimize ?? widget.onClose)?.call();
                      },
                      onLock: _desktop ? null : () => _setLocked(true),
                      onShortcuts: _desktop
                          ? () {
                              unawaited(_showShortcutsSheet());
                            }
                          : null,
                      onPip: playback.canEnterPip
                          ? () => unawaited(_enterPip())
                          : null,
                      onSettings: _openSettings,
                      onCast: AppCapabilities.castToDevice
                          ? () {
                              unawaited(showCastDeviceSheet(context));
                            }
                          : null,
                      casting: casting,
                      onOpenGuide: showEpgChrome && current != null
                          ? () => unawaited(_openNearbyPrograms())
                          : null,
                    ),
                  ),
                ),
                if (!_desktop)
                  Center(
                    child: _absorbChromeHits(
                      _TransportCluster(
                        prominent: true,
                        playing: playing,
                        onPlayPause: _togglePlay,
                        onRewind: () => _seekBy(const Duration(seconds: -10)),
                        onForward: () => _seekBy(const Duration(seconds: 10)),
                        onPreviousEpisode: playback.previousEpisode != null
                            ? () {
                                unawaited(playback.playPreviousEpisode());
                                _armHideTimer();
                              }
                            : null,
                        onNextEpisode: playback.nextEpisode != null
                            ? () {
                                unawaited(playback.playNextEpisode());
                                _armHideTimer();
                              }
                            : null,
                      ),
                    ),
                  ),
                StreamBuilder<Duration>(
                  stream: widget.player.stream.position,
                  initialData: widget.player.state.position,
                  builder: (context, posSnap) {
                    return StreamBuilder<Duration>(
                      stream: widget.player.stream.duration,
                      initialData: widget.player.state.duration,
                      builder: (context, durSnap) {
                        return StreamBuilder<Duration>(
                          stream: widget.player.stream.buffer,
                          initialData: widget.player.state.buffer,
                          builder: (context, bufSnap) {
                            final position = posSnap.data ?? Duration.zero;
                            final duration = durSnap.data ?? Duration.zero;
                            final buffer = bufSnap.data ?? Duration.zero;
                            // Playhead-derived — recomputed per tick here so the
                            // outer shell can stay still between state changes.
                            final atLive = playback.isAtLiveEdge;
                            final wall = playback.playbackWallClock;
                            final vodProgress = duration.inMilliseconds == 0
                                ? 0.0
                                : position.inMilliseconds /
                                      duration.inMilliseconds;
                            final dvrProgress =
                                _dvrDragProgress ?? playback.liveDvrProgress;
                            final programProgress =
                                _dvrDragProgress ??
                                playback.liveProgramProgress ??
                                0.0;
                            final isLiveSurface = displayItem.isLive || canDvr;
                            final showEpgChrome =
                                displayItem.isLive ||
                                displayItem.kind == MediaKind.catchup;
                            // Timeline mode pins the live edge at 1.0.
                            // Programme mode maps start → end of the current
                            // show; the live edge sits partway along the bar.
                            final double progress;
                            if (useProgramScrub) {
                              progress = programProgress;
                            } else if (atLive && _dvrDragProgress == null) {
                              progress = 1.0;
                            } else if (canDvr) {
                              progress = dvrProgress;
                            } else {
                              progress = vodProgress;
                            }
                            // Classical lighter “loaded” segment ahead of the
                            // playhead. Only for VOD timelines — live/DVR scrub
                            // progress is window-mapped, not media duration.
                            final durationMs = duration.inMilliseconds;
                            final double? bufferedProgress;
                            if (!isLiveSurface &&
                                durationMs > 0 &&
                                buffer > position) {
                              bufferedProgress =
                                  (buffer.inMilliseconds / durationMs).clamp(
                                    0.0,
                                    1.0,
                                  );
                            } else {
                              bufferedProgress = null;
                            }
                            final canStartOver = playback.canStartOver;
                            final canToggleScrub = canDvr && current != null;
                            final String? scrubLabel;
                            if (useProgramScrub && current != null) {
                              final programAtLive =
                                  atLive && _dvrDragProgress == null;
                              final liveFrac =
                                  playback.liveProgramLiveFraction ?? 1.0;
                              Duration programDelay = playback.liveDelay;
                              if (_dvrDragProgress != null &&
                                  current.duration.inMilliseconds > 0) {
                                final absProg = _dvrDragProgress!.clamp(
                                  0.0,
                                  liveFrac,
                                );
                                final dragWall = current.start.add(
                                  Duration(
                                    milliseconds:
                                        (current.duration.inMilliseconds *
                                                absProg)
                                            .round(),
                                  ),
                                );
                                final behind = DateTime.now().difference(
                                  dragWall,
                                );
                                programDelay = behind.isNegative
                                    ? Duration.zero
                                    : behind;
                              }
                              scrubLabel = _fmtProgramScrubLabel(
                                program: current,
                                wall: wall,
                                atLive: programAtLive,
                                liveDelay: programDelay,
                                dragProgress: _dvrDragProgress,
                                liveFraction: liveFrac,
                              );
                            } else if (canDvr) {
                              // Prefer provider liveDelay when not dragging so
                              // ±10 nudges show immediately; drag uses scrub
                              // progress so the preview tracks the thumb.
                              final Duration dvrDelay;
                              if (_dvrDragProgress != null) {
                                final window = playback.liveDvrWindow;
                                dvrDelay = window.inMilliseconds <= 0
                                    ? Duration.zero
                                    : window *
                                          (1.0 -
                                              _dvrDragProgress!.clamp(
                                                0.0,
                                                1.0,
                                              ));
                              } else if (atLive) {
                                dvrDelay = Duration.zero;
                              } else {
                                dvrDelay = playback.liveDelay;
                              }
                              scrubLabel = _fmtDvrLabel(
                                dvrDelay,
                                program: current,
                              );
                            } else {
                              scrubLabel = null;
                            }

                            return Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _absorbChromeHits(
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (showEpgChrome && current != null)
                                      _BrowseAwareNowPlayingBanner(
                                        program: current,
                                        at: wall,
                                        atLiveEdge:
                                            atLive && _dvrDragProgress == null,
                                        formatClock: _fmtClock,
                                        canStartOver: canStartOver,
                                        onStartOver: canStartOver
                                            ? () => unawaited(_startOver())
                                            : null,
                                        onOpenGuide: () =>
                                            unawaited(_openNearbyPrograms()),
                                      ),
                                    _BottomBar(
                                      positionLabel:
                                          '${_fmt(position)} / ${_fmt(duration)}',
                                      elapsedLabel: formatVodLeftClock(
                                        position: position,
                                        duration: duration,
                                        showRemaining: _showRemaining,
                                      ),
                                      totalLabel: _fmt(duration),
                                      progress: progress,
                                      bufferedProgress: bufferedProgress,
                                      isLive: isLiveSurface,
                                      playing: playing,
                                      onPlayPause: _togglePlay,
                                      onRewind: () =>
                                          _seekBy(const Duration(seconds: -10)),
                                      onForward: () =>
                                          _seekBy(const Duration(seconds: 10)),
                                      inlineTransport: _desktop,
                                      canDvr: canDvr,
                                      atLiveEdge:
                                          atLive && _dvrDragProgress == null,
                                      useProgramScrub: useProgramScrub,
                                      delayLabel: scrubLabel,
                                      rate: _selectedRate,
                                      onToggleCinema: widget.onToggleCinema,
                                      onToggleBrowsePanel:
                                          widget.onToggleBrowsePanel,
                                      volume: _desktop ? playback.volume : null,
                                      onVolumeChanged: _desktop
                                          ? (value) {
                                              final hint = value <= 0
                                                  ? context.l10n.muted
                                                  : '${value.round()}%';
                                              unawaited(
                                                playback.setVolume(value),
                                              );
                                              _showVolumeHint(hint);
                                              _armHideTimer();
                                            }
                                          : null,
                                      onMuteToggle: _desktop
                                          ? () => unawaited(_toggleMute())
                                          : null,
                                      onSpeedTap:
                                          (!displayItem.isLive || canDvr)
                                          ? _cycleSpeed
                                          : null,
                                      onSpeedLongPress:
                                          (!displayItem.isLive || canDvr)
                                          ? () => unawaited(_pickSpeed())
                                          : null,
                                      onLabelTap: canToggleScrub
                                          ? () => unawaited(
                                              _toggleLiveScrubMode(),
                                            )
                                          : (!isLiveSurface
                                                ? _toggleVodRemaining
                                                : null),
                                      onSeek: (value) {
                                        if (canDvr) {
                                          unawaited(
                                            playback.seekLiveScrubProgress(
                                              value,
                                            ),
                                          );
                                        } else {
                                          final ms =
                                              (duration.inMilliseconds * value)
                                                  .round();
                                          unawaited(
                                            playback.seekTo(
                                              Duration(milliseconds: ms),
                                            ),
                                          );
                                        }
                                      },
                                      onSeekDragStart: _beginScrub,
                                      onSeekDrag: canDvr
                                          ? (value) {
                                              final max = useProgramScrub
                                                  ? (playback
                                                            .liveProgramLiveFraction ??
                                                        1.0)
                                                  : 1.0;
                                              setState(
                                                () => _dvrDragProgress = value
                                                    .clamp(0.0, max),
                                              );
                                            }
                                          : null,
                                      onSeekDragEnd: (value) {
                                        if (canDvr) {
                                          setState(
                                            () => _dvrDragProgress = null,
                                          );
                                          unawaited(
                                            playback.seekLiveScrubProgress(
                                              value,
                                            ),
                                          );
                                        }
                                        _endScrub();
                                      },
                                      onJumpToLive: canDvr
                                          ? () {
                                              unawaited(playback.jumpToLive());
                                              _armHideTimer();
                                            }
                                          : null,
                                      onPreviousEpisode:
                                          playback.previousEpisode != null
                                          ? () {
                                              unawaited(
                                                playback.playPreviousEpisode(),
                                              );
                                              _armHideTimer();
                                            }
                                          : null,
                                      onNextEpisode:
                                          playback.nextEpisode != null
                                          ? () {
                                              unawaited(
                                                playback.playNextEpisode(),
                                              );
                                              _armHideTimer();
                                            }
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ),

        // Stay visible while a skip window is active — do not fade with chrome.
        if (_activeSegment != null && !_locked)
          Positioned(
            right: 16,
            bottom:
                (_visible ? 110 : 36) + MediaQuery.paddingOf(context).bottom,
            child: FilledButton(
              onPressed: () => unawaited(_skipActiveSegment()),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
              ),
              child: Text(
                _skipLabel(_activeSegment!.type),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),

        if (_locked)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 12,
            right: 16,
            child: AnimatedOpacity(
              opacity: _lockChromeVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_lockChromeVisible,
                child: IconButton.filledTonal(
                  onPressed: () => _setLocked(false),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black45,
                    foregroundColor: Colors.white,
                  ),
                  tooltip: context.l10n.unlock,
                  icon: const Icon(Icons.lock_open_rounded),
                ),
              ),
            ),
          ),
      ],
    );

    if (!_desktop) return surface;

    // Desktop: keyboard target, hover-to-reveal chrome, wheel volume, and a
    // cursor that gets out of the way with the chrome.
    final hideCursor =
        !_visible &&
        !_lockChromeVisible &&
        sessionError == null &&
        playing &&
        !context.read<PlaybackProvider>().isLoading;
    final pip = context.select<PlaybackProvider, bool>((p) => p.isInPip);
    return DesktopPlayerKeyboard(
      focusNode: _keyboardFocus,
      onKeyEvent: _onKeyEvent,
      absorbKeys: !pip,
      child: MouseRegion(
        cursor: hideCursor ? SystemMouseCursors.none : MouseCursor.defer,
        onHover: _onMouseHover,
        child: Listener(onPointerSignal: _onPointerSignal, child: surface),
      ),
    );
  }
}

class _BoostBadge extends StatelessWidget {
  const _BoostBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fast_forward_rounded, color: Colors.white, size: 20),
          SizedBox(width: 8),
          Text(
            '2x',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 18,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Brief center play/pause confirmation (YouTube-style).
class _PlayPauseFlash extends StatefulWidget {
  const _PlayPauseFlash({super.key, required this.playing});

  /// True when playback is starting (show play); false when pausing.
  final bool playing;

  @override
  State<_PlayPauseFlash> createState() => _PlayPauseFlashState();
}

class _PlayPauseFlashState extends State<_PlayPauseFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 12),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 38),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _scale = Tween<double>(
      begin: 0.82,
      end: 1.18,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
          child: Padding(
            // Play arrow is optically left-heavy in a circle.
            padding: widget.playing
                ? const EdgeInsets.only(left: 4)
                : EdgeInsets.zero,
            child: Icon(
              widget.playing ? Icons.play_arrow_rounded : Icons.pause_rounded,
              color: Colors.white,
              size: 52,
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowseAwareNowPlayingBanner extends StatelessWidget {
  const _BrowseAwareNowPlayingBanner({
    required this.program,
    required this.at,
    required this.formatClock,
    this.atLiveEdge = true,
    this.canStartOver = false,
    this.onStartOver,
    this.onOpenGuide,
  });

  final EpgProgram program;
  final DateTime at;
  final String Function(DateTime) formatClock;
  final bool atLiveEdge;
  final bool canStartOver;
  final VoidCallback? onStartOver;
  final VoidCallback? onOpenGuide;

  @override
  Widget build(BuildContext context) {
    // Details live in the side panel — hide the on-video banner while it is open.
    final hide = context.select<PlaybackProvider, bool>(
      (p) => !p.cinemaMode && !p.browsePanelCollapsed,
    );
    if (hide) return const SizedBox.shrink();
    return _NowPlayingBanner(
      program: program,
      at: at,
      formatClock: formatClock,
      atLiveEdge: atLiveEdge,
      canStartOver: canStartOver,
      onStartOver: onStartOver,
      onOpenGuide: onOpenGuide,
    );
  }
}

class _NowPlayingBanner extends StatefulWidget {
  const _NowPlayingBanner({
    required this.program,
    required this.at,
    required this.formatClock,
    this.atLiveEdge = true,
    this.canStartOver = false,
    this.onStartOver,
    this.onOpenGuide,
  });

  final EpgProgram program;
  final DateTime at;
  final String Function(DateTime) formatClock;
  final bool atLiveEdge;
  final bool canStartOver;
  final VoidCallback? onStartOver;
  final VoidCallback? onOpenGuide;

  @override
  State<_NowPlayingBanner> createState() => _NowPlayingBannerState();
}

class _NowPlayingBannerState extends State<_NowPlayingBanner> {
  var _expanded = false;
  String? _programKey;

  String get _key =>
      '${widget.program.channelId}|${widget.program.start.toUtc().toIso8601String()}';

  @override
  void initState() {
    super.initState();
    _programKey = _key;
  }

  @override
  void didUpdateWidget(covariant _NowPlayingBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final key = _key;
    if (key != _programKey) {
      _programKey = key;
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final program = widget.program;
    final progress = program.progressAt(widget.at);
    final remaining = program.end.difference(widget.at);
    final remainingLabel = remaining.isNegative
        ? ''
        : context.l10n.minutesLeft(remaining.inMinutes.clamp(0, 999));
    final statusLabel = widget.atLiveEdge ? 'NOW' : 'DVR';
    final description = program.description?.trim();
    final hasDescription = description != null && description.isNotEmpty;

    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onOpenGuide,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.live,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          statusLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 10,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          program.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (widget.canStartOver &&
                          widget.onStartOver != null) ...[
                        const SizedBox(width: 4),
                        TextButton.icon(
                          onPressed: widget.onStartOver,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.restart_alt_rounded, size: 18),
                          label: Text(context.l10n.startOver),
                        ),
                      ],
                      if (hasDescription)
                        IconButton(
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          icon: Icon(
                            _expanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            color: Colors.white54,
                            size: 20,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.formatClock(program.start)}–${widget.formatClock(program.end)}'
                    '${remainingLabel.isEmpty ? '' : ' · $remainingLabel'}'
                    ' · Guide',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      minHeight: 3,
                      backgroundColor: Colors.white24,
                      color: AppColors.live,
                    ),
                  ),
                  if (_expanded && hasDescription) ...[
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.28,
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          description,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.item,
    this.nowPlaying,
    this.nextProgram,
    this.formatClock,
    this.sourceLabel,
    this.qualityLabel,
    this.downloadItem,
    this.onDvrDownload,
    this.onClose,
    this.onLock,
    this.onShortcuts,
    this.onPip,
    this.onSettings,
    this.onCast,
    this.casting = false,
    this.onOpenGuide,
  });

  final MediaItem item;
  final EpgProgram? nowPlaying;
  final EpgProgram? nextProgram;
  final String Function(DateTime)? formatClock;

  /// Playlist / provider name when multiple qualities are available.
  final String? sourceLabel;
  final String? qualityLabel;
  final MediaItem? downloadItem;
  final VoidCallback? onDvrDownload;
  final VoidCallback? onClose;
  final VoidCallback? onLock;
  final VoidCallback? onShortcuts;
  final VoidCallback? onPip;
  final VoidCallback? onSettings;
  final VoidCallback? onCast;
  final bool casting;
  final VoidCallback? onOpenGuide;

  @override
  Widget build(BuildContext context) {
    final cinemaMode = context.select<PlaybackProvider, bool>(
      (p) => p.cinemaMode,
    );
    final compact = context.select<PlaybackProvider, bool>(
      (p) => !p.cinemaMode && !p.browsePanelCollapsed,
    );
    final sourceMeta = [
      if (qualityLabel != null && qualityLabel!.trim().isNotEmpty)
        qualityLabel!.trim(),
      if (sourceLabel != null && sourceLabel!.trim().isNotEmpty)
        sourceLabel!.trim(),
    ].join(' · ');
    final subtitle = nowPlaying != null
        ? nowPlaying!.title
        : [
            if (item.subtitle != null && item.subtitle!.trim().isNotEmpty)
              item.subtitle!.trim(),
            if ((item.subtitle == null || item.subtitle!.trim().isEmpty) &&
                item.group != null &&
                item.group!.trim().isNotEmpty)
              item.group!.trim(),
            if (item.year != null) '${item.year}',
          ].join(' · ');
    final nextLabel = nextProgram == null || formatClock == null
        ? null
        : 'Next · ${nextProgram!.title} · ${formatClock!(nextProgram!.start)}';

    return SafeArea(
      top: !compact,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        child: Row(
          children: [
            IconButton(
              onPressed: onClose ?? () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
              color: Colors.white,
              tooltip: context.l10n.minimize,
            ),
            Expanded(
              child: InkWell(
                onTap: onOpenGuide,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (item.isLive || item.kind == MediaKind.catchup)
                            ? context
                                  .read<LibraryProvider>()
                                  .liveOrCatchupDisplayTitle(item)
                            : item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      if (sourceMeta.isNotEmpty)
                        Text(
                          sourceMeta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (!compact) ...[
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: nowPlaying != null
                                  ? Colors.white
                                  : Colors.white70,
                              fontSize: 12,
                              fontWeight: nowPlaying != null
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        if (nextLabel != null)
                          Text(
                            nextLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (onCast != null)
              IconButton(
                onPressed: onCast,
                icon: Icon(
                  casting ? Icons.cast_connected_rounded : Icons.cast_rounded,
                ),
                color: Colors.white,
                tooltip: context.l10n.castToDevice,
              ),
            // Download only outside immersive fullscreen.
            if (!cinemaMode && downloadItem != null)
              DownloadStatusButton(
                item: downloadItem!,
                foregroundColor: Colors.white,
              )
            else if (!cinemaMode && onDvrDownload != null)
              IconButton(
                onPressed: onDvrDownload,
                icon: const Icon(Icons.download_rounded),
                color: Colors.white,
                tooltip: context.l10n.downloadForOffline,
              ),
            if (onPip != null)
              IconButton(
                onPressed: onPip,
                icon: const Icon(Icons.picture_in_picture_alt_rounded),
                color: Colors.white,
                tooltip: context.l10n.pictureInPicture,
              ),
            if (onLock != null)
              IconButton(
                onPressed: onLock,
                icon: const Icon(Icons.lock_outline_rounded),
                color: Colors.white,
                tooltip: context.l10n.lockControls,
              ),
            if (onShortcuts != null)
              IconButton(
                onPressed: onShortcuts,
                icon: const Icon(Icons.keyboard_rounded),
                color: Colors.white,
                tooltip: context.l10n.keyboardShortcuts,
              ),
            IconButton(
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined),
              color: Colors.white,
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.positionLabel,
    required this.elapsedLabel,
    required this.totalLabel,
    required this.progress,
    this.bufferedProgress,
    required this.onSeek,
    required this.isLive,
    required this.playing,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    this.inlineTransport = true,
    this.canDvr = false,
    this.atLiveEdge = true,
    this.useProgramScrub = false,
    this.delayLabel,
    this.rate = 1.0,
    this.volume,
    this.onVolumeChanged,
    this.onMuteToggle,
    this.onSpeedTap,
    this.onSpeedLongPress,
    this.onToggleCinema,
    this.onToggleBrowsePanel,
    this.onLabelTap,
    this.onSeekDragStart,
    this.onSeekDrag,
    this.onSeekDragEnd,
    this.onJumpToLive,
    this.onPreviousEpisode,
    this.onNextEpisode,
  });

  final String positionLabel;

  /// Time played and total runtime, shown at either end of the scrub bar.
  final String elapsedLabel;
  final String totalLabel;
  final double progress;

  /// End of the demuxer buffer as a 0–1 fraction of duration, or null when
  /// there is nothing buffered ahead of the playhead (or for live/DVR).
  final double? bufferedProgress;
  final ValueChanged<double> onSeek;
  final bool isLive;
  final bool playing;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;

  /// When false (touch), play/±10 live in a centered overlay instead.
  final bool inlineTransport;
  final bool canDvr;
  final bool atLiveEdge;
  final bool useProgramScrub;
  final String? delayLabel;
  final double rate;

  /// Desktop software volume (0–100). Null hides the control (phones).
  final double? volume;
  final ValueChanged<double>? onVolumeChanged;
  final VoidCallback? onMuteToggle;
  final VoidCallback? onSpeedTap;
  final VoidCallback? onSpeedLongPress;
  final VoidCallback? onToggleCinema;
  final VoidCallback? onToggleBrowsePanel;
  final VoidCallback? onLabelTap;
  final VoidCallback? onSeekDragStart;
  final ValueChanged<double>? onSeekDrag;
  final ValueChanged<double>? onSeekDragEnd;
  final VoidCallback? onJumpToLive;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;

  @override
  Widget build(BuildContext context) {
    final cinemaMode = context.select<PlaybackProvider, bool>(
      (p) => p.cinemaMode,
    );
    final browsePanelCollapsed = context.select<PlaybackProvider, bool>(
      (p) => p.browsePanelCollapsed,
    );
    final scrubbable = !isLive || canDvr;
    final String label;
    if (canDvr) {
      // Prefer the formatted scrub label (includes programme title when known).
      label =
          delayLabel ??
          (useProgramScrub
              ? positionLabel
              : atLiveEdge
              ? context.l10n.dvrScrubHint
              : positionLabel);
    } else if (isLive) {
      label = context.l10n.liveBadge;
    } else {
      label = positionLabel;
    }
    // Live without DVR has nothing to scrub through, so the times row carries
    // the LIVE state instead of a clock.
    final showTimes = !isLive || canDvr;
    final accent = canDvr && !atLiveEdge ? AppColors.live : AppColors.accent;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 28,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  trackShape: const RectangularSliderTrackShape(),
                  thumbShape: _ScrubThumb(color: accent),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16,
                  ),
                  activeTrackColor: accent,
                  // Lighter segment between playhead and buffered end.
                  secondaryActiveTrackColor: Colors.white38,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: AppColors.accentSoft,
                ),
                child: Slider(
                  value: progress.clamp(0.0, 1.0),
                  secondaryTrackValue: bufferedProgress,
                  onChangeStart: !scrubbable || onSeekDragStart == null
                      ? null
                      : (_) => onSeekDragStart!(),
                  onChanged: !scrubbable
                      ? null
                      : (canDvr && onSeekDrag != null)
                      ? onSeekDrag
                      : onSeek,
                  onChangeEnd: !scrubbable || onSeekDragEnd == null
                      ? null
                      : onSeekDragEnd,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: MouseRegion(
                      cursor: onLabelTap != null
                          ? SystemMouseCursors.click
                          : MouseCursor.defer,
                      child: GestureDetector(
                        onTap: onLabelTap,
                        behavior: HitTestBehavior.opaque,
                        child: Text(
                          showTimes && !canDvr ? elapsedLabel : label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isLive && atLiveEdge
                                ? AppColors.live
                                : Colors.white70,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (showTimes && !canDvr) ...[
                    const SizedBox(width: 8),
                    Text(
                      totalLabel,
                      maxLines: 1,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                if (inlineTransport)
                  _TransportCluster(
                    playing: playing,
                    onPlayPause: onPlayPause,
                    onRewind: onRewind,
                    onForward: onForward,
                    onPreviousEpisode: onPreviousEpisode,
                    onNextEpisode: onNextEpisode,
                  ),
                const Spacer(),
                if (volume != null &&
                    onVolumeChanged != null &&
                    onMuteToggle != null)
                  _VolumeControl(
                    volume: volume!,
                    onChanged: onVolumeChanged!,
                    onMuteToggle: onMuteToggle!,
                  ),
                if (onSpeedTap != null)
                  _ChromeChip(
                    label: formatPlaybackRateLabel(rate),
                    onTap: onSpeedTap,
                    onLongPress: onSpeedLongPress,
                    highlighted: rate != 1.0,
                    tooltip: context.l10n.playbackSpeed,
                  ),
                if (onToggleBrowsePanel != null && !cinemaMode) ...[
                  const SizedBox(width: 2),
                  _TransportButton(
                    icon: browsePanelCollapsed
                        ? Icons.view_sidebar_rounded
                        : Icons.view_sidebar_outlined,
                    tooltip: browsePanelCollapsed
                        ? context.l10n.showBrowsePanel
                        : context.l10n.hideBrowsePanel,
                    onPressed: onToggleBrowsePanel,
                  ),
                ],
                if (onToggleCinema != null) ...[
                  const SizedBox(width: 2),
                  _TransportButton(
                    icon: cinemaMode
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    tooltip: cinemaMode
                        ? context.l10n.exitFullscreen
                        : context.l10n.fullscreen,
                    onPressed: onToggleCinema,
                  ),
                ],
                if (canDvr) ...[
                  const SizedBox(width: 6),
                  _ChromeChip(
                    label: context.l10n.liveBadge,
                    onTap: atLiveEdge ? null : onJumpToLive,
                    background: atLiveEdge ? AppColors.live : null,
                    highlighted: atLiveEdge,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Soft dark halo so white glyphs stay readable on bright frames.
const List<Shadow> _onVideoGlyphShadow = [
  Shadow(color: Color(0x73000000), blurRadius: 8),
  Shadow(color: Color(0x40000000), blurRadius: 2, offset: Offset(0, 1)),
];

/// Play / ±10 / optional episode skips — bottom-left on desktop, centered on touch.
class _TransportCluster extends StatelessWidget {
  const _TransportCluster({
    required this.playing,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    this.onPreviousEpisode,
    this.onNextEpisode,
    this.prominent = false,
  });

  final bool playing;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;

  /// Centered touch overlay: larger targets, gaps, and a light glyph shadow.
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    // Keep both skip slots when either adjacent episode exists so the cluster
    // does not jump, and the missing side stays visible but greyed out.
    final showEpisodeSkips = onPreviousEpisode != null || onNextEpisode != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: _gapFor(
            constraints.maxWidth,
            showEpisodeSkips: showEpisodeSkips,
          ),
          children: [
            if (showEpisodeSkips)
              _TransportButton(
                icon: Icons.skip_previous_rounded,
                tooltip: context.l10n.previousEpisode,
                onPressed: onPreviousEpisode,
                prominent: prominent,
              ),
            _TransportButton(
              icon: Icons.replay_10_rounded,
              tooltip: context.l10n.rewind10Seconds,
              onPressed: onRewind,
              prominent: prominent,
            ),
            _PlayButton(
              playing: playing,
              onPressed: onPlayPause,
              prominent: prominent,
            ),
            _TransportButton(
              icon: Icons.forward_10_rounded,
              tooltip: context.l10n.forward10Seconds,
              onPressed: onForward,
              prominent: prominent,
            ),
            if (showEpisodeSkips)
              _TransportButton(
                icon: Icons.skip_next_rounded,
                tooltip: context.l10n.nextEpisode,
                onPressed: onNextEpisode,
                prominent: prominent,
              ),
          ],
        );
      },
    );
  }

  /// Keep 32dp gaps when they fit; shrink on narrow phones so prev/next
  /// episode targets are not clipped by the overlay Stack.
  double _gapFor(double maxWidth, {required bool showEpisodeSkips}) {
    if (!prominent) return 0;
    const play = 72.0;
    const side = 56.0;
    const ideal = 32.0;
    const minGap = 8.0;
    const inset = 24.0;
    final extras = showEpisodeSkips ? 2 : 0;
    final buttons = 3 + extras;
    final glyphs = play + side * (buttons - 1);
    if (!maxWidth.isFinite || maxWidth <= glyphs) return minGap;
    final room = maxWidth - inset - glyphs;
    return (room / (buttons - 1)).clamp(minGap, ideal);
  }
}

/// Desktop mute + slider — phones keep using hardware volume keys.
class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.volume,
    required this.onChanged,
    required this.onMuteToggle,
  });

  final double volume;
  final ValueChanged<double> onChanged;
  final VoidCallback onMuteToggle;

  @override
  Widget build(BuildContext context) {
    final muted = volume <= 0;
    final icon = muted
        ? Icons.volume_off_rounded
        : volume < 50
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TransportButton(
          icon: icon,
          tooltip: muted ? context.l10n.volume : context.l10n.mute,
          onPressed: onMuteToggle,
        ),
        SizedBox(
          width: 110,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              trackShape: const RectangularSliderTrackShape(),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: AppColors.accentSoft,
            ),
            child: Slider(
              value: volume.clamp(0.0, 100.0),
              min: 0,
              max: 100,
              label: muted ? context.l10n.muted : '${volume.round()}%',
              onChanged: onChanged,
            ),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// Secondary transport control: 44dp target around a 26px glyph.
/// Centered touch overlay uses [prominent] (56dp / 34px) plus a light shadow.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.prominent = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final size = prominent ? 56.0 : 44.0;
    return IconButton(
      onPressed: onPressed,
      icon: Icon(
        icon,
        color: onPressed != null ? Colors.white : Colors.white38,
        shadows: prominent ? _onVideoGlyphShadow : null,
      ),
      iconSize: prominent ? 34 : 26,
      color: Colors.white,
      disabledColor: Colors.white38,
      tooltip: tooltip,
      visualDensity: prominent ? VisualDensity.standard : VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(minWidth: size, minHeight: size),
    );
  }
}

/// The site draws this at 24px. Touch needs a large disc, so it is scaled up
/// rather than padded out — a 24px disc inside a 48dp target reads as a
/// mis-tap waiting to happen. The centered overlay goes further (72dp).
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.onPressed,
    this.prominent = false,
  });

  final bool playing;
  final VoidCallback onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final disc = prominent ? 72.0 : 48.0;
    return Semantics(
      button: true,
      label: playing ? context.l10n.pause : context.l10n.play,
      onTap: onPressed,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: prominent
              ? const [BoxShadow(color: Color(0x59000000), blurRadius: 12)]
              : null,
        ),
        child: Material(
          color: Colors.white.withValues(alpha: 0.16),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            // Fire on press (not release) so pause feels instant. Do not also
            // wire [onTap]: InkWell invokes both for one finger press, which
            // resumed playback and then paused again when the finger lifted.
            // Screen readers use [Semantics.onTap] above instead.
            onTapDown: (_) => onPressed(),
            child: SizedBox(
              width: disc,
              height: disc,
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: prominent ? 40 : 28,
                color: Colors.white,
                shadows: prominent ? _onVideoGlyphShadow : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small square-ish chip at the right of the control row (`1×`, `LIVE`).
class _ChromeChip extends StatelessWidget {
  const _ChromeChip({
    required this.label,
    this.onTap,
    this.onLongPress,
    this.background,
    this.highlighted = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? background;
  final bool highlighted;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: background ?? Colors.white.withValues(alpha: 0.14),
          borderRadius: AppRadius.smAll,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: highlighted ? Colors.white : Colors.white70,
            fontWeight: FontWeight.w700,
            fontSize: 12,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip!, child: chip);
  }
}

/// White scrub head with an accent halo, as on the site's player mock.
class _ScrubThumb extends SliderComponentShape {
  const _ScrubThumb({required this.color});

  static const radius = 5.0;

  final Color color;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size.fromRadius(radius);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    // Live without DVR hands us a disabled slider; fade the head so the bar
    // doesn't invite a drag that will not happen.
    final enabled = enableAnimation.value;
    if (enabled > 0) {
      canvas.drawCircle(
        center,
        radius + 1.5,
        Paint()
          ..color = color.withValues(alpha: 0.9 * enabled)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = Color.lerp(Colors.white38, Colors.white, enabled)!,
    );
  }
}

/// Previous / now / next programmes for quick catchup from the player.
class _NearbyProgramsSheet extends StatelessWidget {
  const _NearbyProgramsSheet({
    required this.channel,
    required this.formatWindow,
    required this.formatDay,
    required this.onSelect,
  });

  final MediaItem channel;
  final String Function(DateTime start, DateTime end) formatWindow;
  final String Function(DateTime) formatDay;
  final Future<void> Function(EpgProgram program) onSelect;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final now = DateTime.now();
    final programs = library.nearbyPrograms(
      channel,
      at: now,
      before: library.liveSupportsCatchup(channel)
          ? ((library.resolveCatchupChannel(channel)?.catchupDays ?? 1).clamp(
                      1,
                      14,
                    ) *
                    6)
                .clamp(12, 48)
                .toInt()
          : 8,
      after: 4,
    );
    final loading = library.isGuideLoading(channel);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.62;

    return SafeArea(
      child: SizedBox(
        height: maxHeight,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          library.liveOrCatchupDisplayTitle(channel),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.l10n.tapPastProgrammeCatchUp,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (loading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: programs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          loading
                              ? context.l10n.loadingGuide
                              : context.l10n.noGuideEntriesYet,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: _programTiles(context, programs, now),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _programTiles(
    BuildContext context,
    List<EpgProgram> programs,
    DateTime now,
  ) {
    final library = context.read<LibraryProvider>();
    final children = <Widget>[];
    DateTime? lastDay;
    for (final program in programs) {
      final local = program.start.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (lastDay == null || day != lastDay) {
        lastDay = day;
        children.add(
          Padding(
            padding: EdgeInsets.fromLTRB(16, children.isEmpty ? 10 : 14, 16, 4),
            child: Text(
              formatDay(program.start),
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        );
      }

      final isNow = program.isAiringAt(now);
      final isPast = program.end.isBefore(now);
      final isFuture = program.start.isAfter(now);
      final canCatchup =
          isPast &&
          (library.liveSupportsCatchup(channel) || program.hasArchive);
      final label = isNow
          ? 'NOW'
          : isPast
          ? context.l10n.catchup
          : context.l10n.upcoming;

      children.add(
        ListTile(
          leading: Container(
            width: 64,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: isNow
                  ? AppColors.live.withValues(alpha: 0.2)
                  : AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isNow ? AppColors.live : AppColors.border,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: isNow ? AppColors.live : AppColors.textMuted,
                fontWeight: FontWeight.w800,
                fontSize: 10,
              ),
            ),
          ),
          title: Text(
            program.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.text,
              fontWeight: isNow ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '${formatWindow(program.start, program.end)}'
            '${program.duration.inMinutes > 0 ? ' · ${program.duration.inMinutes}m' : ''}',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          trailing: isNow
              ? const Icon(Icons.sensors_rounded, color: AppColors.live)
              : canCatchup
              ? const Icon(Icons.history_rounded, color: AppColors.accent)
              : isFuture
              ? const Icon(Icons.schedule_rounded, color: AppColors.textMuted)
              : null,
          onTap: () => onSelect(program),
        ),
      );
    }
    return children;
  }
}
