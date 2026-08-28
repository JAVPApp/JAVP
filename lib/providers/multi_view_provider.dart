import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/iptv/live_zap_number.dart';
import 'package:javp/services/playback/secondary_live_player.dart';
import 'package:javp/compat/media_kit_video.dart';

/// Which multi-view pane owns focus (controls / EPG / zapping).
enum MultiViewPane { primary, secondary }

/// Two-pane layout for the MVP (not a 4-pane mosaic).
enum MultiViewLayoutMode {
  /// Equal split (landscape) or stacked (narrow portrait).
  sideBySide,

  /// Primary fills the stage; secondary sits in a corner PiP.
  pip,
}

/// Dual live playback: primary stays on [PlaybackProvider], secondary is local.
///
/// Focus owns zap/EPG/controls. Audio is independent so you can watch one pane
/// while hearing the other — [swapAudio] flips with one action.
class MultiViewProvider extends ChangeNotifier {
  MultiViewProvider();

  final SecondaryLivePlayer _secondary = SecondaryLivePlayer();

  PlaybackProvider? _playback;
  VoidCallback? _playbackListener;

  bool _active = false;
  MultiViewPane _focused = MultiViewPane.primary;
  MultiViewPane _audio = MultiViewPane.primary;
  MultiViewLayoutMode _layout = MultiViewLayoutMode.sideBySide;
  String? _error;

  /// Bumped on each [enter]/[exit] so a late [SecondaryLivePlayer.open] cannot
  /// resurrect a stopped secondary session.
  int _sessionGen = 0;

  /// Last volume preference mirrored onto the secondary engine (avoids spam).
  double? _mirroredSecondaryVolume;

  bool get isSupported => AppCapabilities.multiView;
  bool get isActive => _active && _secondary.hasSession;
  MultiViewPane get focusedPane => _focused;
  MultiViewPane get audioPane => _audio;
  MultiViewLayoutMode get layoutMode => _layout;
  MediaItem? get secondaryChannel => _secondary.channel;
  VideoController? get secondaryController => _secondary.controller;
  String? get error => _error ?? _secondary.error;
  int get secondaryRevision => _secondary.revision;

  /// Bind to the app's [PlaybackProvider] so primary stop ends multi-view.
  void attachPlayback(PlaybackProvider playback) {
    if (identical(_playback, playback)) return;
    _detachPlayback();
    _playback = playback;
    _playbackListener = _onPlaybackChanged;
    playback.addListener(_playbackListener!);
  }

  void _detachPlayback() {
    final playback = _playback;
    final listener = _playbackListener;
    if (playback != null && listener != null) {
      playback.removeListener(listener);
    }
    _playback = null;
    _playbackListener = null;
  }

  void _onPlaybackChanged() {
    final playback = _playback;
    if (playback == null) return;
    if (!playback.hasSession && _active) {
      unawaited(exit());
      return;
    }
    // Keep primary silence + secondary level in sync when volume preference
    // changes while secondary owns audio. Skip position/buffer notify spam.
    if (_active && _audio == MultiViewPane.secondary) {
      unawaited(playback.setEngineSilenced(true));
      final vol = playback.volume;
      if (_mirroredSecondaryVolume != vol) {
        _mirroredSecondaryVolume = vol;
        unawaited(_secondary.setVolume(vol));
      }
    }
  }

  Future<void> enter({
    required MediaItem secondary,
    required LibraryProvider library,
    required PlaybackProvider playback,
    MultiViewLayoutMode? layout,
  }) async {
    if (!isSupported) {
      _error = 'Multi-view is not available on this device';
      notifyListeners();
      return;
    }
    if (!playback.hasSession || !(playback.item?.isLive ?? false)) {
      _error = 'Start a live channel before opening multi-view';
      notifyListeners();
      return;
    }
    attachPlayback(playback);
    final channel = library.resolveLiveChannel(secondary);
    if (channel.id == playback.item?.id ||
        (channel.streamId != null &&
            channel.streamId == playback.liveChannel?.streamId &&
            channel.sourceId == playback.liveChannel?.sourceId)) {
      _error = 'Pick a different channel for the second pane';
      notifyListeners();
      return;
    }
    if (channel.playUrl.trim().isEmpty) {
      _error = 'That channel has no playable URL';
      notifyListeners();
      return;
    }

    _error = null;
    if (layout != null) _layout = layout;
    _focused = MultiViewPane.primary;
    _audio = MultiViewPane.primary;
    final gen = ++_sessionGen;
    _active = true;
    notifyListeners();

    final watch = Stopwatch()..start();
    try {
      await _secondary.open(channel, volume: 0);
      if (gen != _sessionGen || !_active) {
        await _secondary.dispose();
        return;
      }
      await playback.setEngineSilenced(false);
      notifyListeners();
      JavpLog.i(
        'multiview',
        'enter in ${watch.elapsedMilliseconds}ms layout=${_layout.name}',
      );
    } catch (e) {
      if (gen != _sessionGen) return;
      _error = e.toString();
      _active = false;
      await _secondary.dispose();
      JavpLog.w(
        'multiview',
        'enter failed after ${watch.elapsedMilliseconds}ms',
        error: e,
      );
      notifyListeners();
    }
  }

  Future<void> exit() async {
    final playback = _playback;
    _sessionGen++;
    _active = false;
    _focused = MultiViewPane.primary;
    _audio = MultiViewPane.primary;
    _error = null;
    final watch = Stopwatch()..start();
    // Release the second libmpv handle — keeping it warm after exit costs RAM
    // on TV sticks for a rare re-enter path.
    await _secondary.dispose();
    if (playback != null) {
      await playback.setEngineSilenced(false);
    }
    JavpLog.slow(
      'multiview',
      'exit in ${watch.elapsedMilliseconds}ms',
      watch.elapsedMilliseconds,
    );
    notifyListeners();
  }

  /// Pause secondary when the app backgrounds (primary is handled separately).
  Future<void> onAppBackgrounded() async {
    if (!_active) return;
    await _secondary.pause();
  }

  /// Resume secondary after a background pause while multi-view is still on.
  Future<void> onAppForegrounded() async {
    if (!_active) return;
    await _secondary.play();
  }

  void setFocusedPane(MultiViewPane pane) {
    if (!_active || _focused == pane) return;
    _focused = pane;
    notifyListeners();
  }

  void toggleFocusedPane() {
    setFocusedPane(
      _focused == MultiViewPane.primary
          ? MultiViewPane.secondary
          : MultiViewPane.primary,
    );
  }

  Future<void> swapAudio() async {
    if (!_active) return;
    final playback = _playback;
    if (playback == null) return;
    final next = _audio == MultiViewPane.primary
        ? MultiViewPane.secondary
        : MultiViewPane.primary;
    _audio = next;
    if (next == MultiViewPane.secondary) {
      await playback.setEngineSilenced(true);
      // If the remembered preference is muted, open secondary at a usable level
      // once; later mute gestures apply 0 via [_onPlaybackChanged].
      final vol = playback.volume <= 0 ? 100.0 : playback.volume;
      _mirroredSecondaryVolume = vol;
      await _secondary.setVolume(vol);
    } else {
      _mirroredSecondaryVolume = null;
      await _secondary.setVolume(0);
      await playback.setEngineSilenced(false);
    }
    notifyListeners();
  }

  void setLayoutMode(MultiViewLayoutMode mode) {
    if (_layout == mode) return;
    _layout = mode;
    notifyListeners();
  }

  void toggleLayoutMode() {
    setLayoutMode(
      _layout == MultiViewLayoutMode.sideBySide
          ? MultiViewLayoutMode.pip
          : MultiViewLayoutMode.sideBySide,
    );
  }

  bool _sameLiveChannel(MediaItem? a, MediaItem? b) {
    if (a == null || b == null) return false;
    if (a.id == b.id) return true;
    return a.streamId != null &&
        a.streamId == b.streamId &&
        a.sourceId == b.sourceId;
  }

  /// Zap the focused pane. Primary uses [PlaybackProvider]; secondary retunes.
  Future<bool> zapFocused(
    int delta, {
    required LibraryProvider library,
    required PlaybackProvider playback,
  }) async {
    if (!_active || delta == 0) return false;
    final list = playback.liveZapList;
    if (list.isEmpty) return false;
    if (_focused == MultiViewPane.primary) {
      final next = liveZapRelativeIndexSkipping(
        length: list.length,
        currentIndex: playback.liveZapIndex,
        delta: delta,
        skip: (i) => _sameLiveChannel(list[i], _secondary.channel),
      );
      if (next == null) return false;
      await playback.open(
        library.resolveLiveChannel(list[next]),
        expand: false,
      );
      return true;
    }
    final current = _secondary.channel;
    final idx = current == null
        ? -1
        : list.indexWhere((c) => _sameLiveChannel(c, current));
    final next = liveZapRelativeIndexSkipping(
      length: list.length,
      currentIndex: idx,
      delta: delta,
      skip: (i) => _sameLiveChannel(list[i], playback.item),
    );
    if (next == null) return false;
    return retuneSecondary(list[next], library: library);
  }

  /// Digit / channel-number entry for the focused pane.
  Future<bool> zapFocusedByIndex(
    int oneBasedIndex, {
    required LibraryProvider library,
    required PlaybackProvider playback,
  }) async {
    if (!_active) return false;
    final channel = playback.liveZapChannelForNumber(oneBasedIndex);
    if (channel == null) return false;
    if (_focused == MultiViewPane.secondary) {
      if (_sameLiveChannel(channel, playback.item)) return false;
      return retuneSecondary(channel, library: library);
    }
    if (_sameLiveChannel(channel, _secondary.channel)) return false;
    await playback.open(library.resolveLiveChannel(channel), expand: false);
    return true;
  }

  Future<bool> retuneSecondary(
    MediaItem channel, {
    required LibraryProvider library,
  }) async {
    if (!_active) return false;
    final resolved = library.resolveLiveChannel(channel);
    if (resolved.playUrl.trim().isEmpty) return false;
    final primary = _playback?.item;
    if (primary != null &&
        (resolved.id == primary.id ||
            (resolved.streamId != null &&
                resolved.streamId == primary.streamId &&
                resolved.sourceId == primary.sourceId))) {
      return false;
    }
    try {
      final vol = _audio == MultiViewPane.secondary
          ? (_playback?.volume ?? 100)
          : 0.0;
      await _secondary.open(resolved, volume: vol <= 0 ? 100 : vol);
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _detachPlayback();
    unawaited(_secondary.dispose());
    super.dispose();
  }
}
