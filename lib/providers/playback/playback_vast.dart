part of '../playback_provider.dart';

class _PendingAfterAds {
  const _PendingAfterAds({
    required this.item,
    required this.start,
    required this.seekResumeProgress,
    required this.epoch,
    this.resumePosition,
    this.thenComplete = false,
  });

  final MediaItem item;
  final Duration? start;
  final double? seekResumeProgress;
  final int epoch;
  final Duration? resumePosition;
  final bool thenComplete;
}

extension PlaybackVast on PlaybackProvider {
  bool get isPlayingAd => _currentAd != null;

  Duration? get adDuration =>
      _currentAd?.duration ?? (_duration > Duration.zero ? _duration : null);

  Duration? get adRemaining {
    if (!isPlayingAd) return null;
    final total = adDuration;
    if (total == null || total <= Duration.zero) return null;
    final left = total - _position;
    return left.isNegative ? Duration.zero : left;
  }

  bool get canSkipAd {
    final ad = _currentAd;
    if (ad == null) return false;
    final skip = ad.skipOffset;
    if (skip == null) return false;
    return _position >= skip;
  }

  String? get adClickThroughUrl => _currentAd?.clickThroughUrl;

  List<VastIcon> get adIcons => _currentAd?.icons ?? const [];

  VastCompanion? get adCompanion {
    final ads = _currentAd?.companions ?? const [];
    for (final c in ads) {
      final url = c.staticUrl;
      if (url != null && url.isNotEmpty) return c;
    }
    return null;
  }

  Future<void> skipAd() async {
    if (!canSkipAd) return;
    await _finishCurrentAd(skipped: true);
  }

  Future<void> openAdClickThrough() async {
    final ad = _currentAd;
    final url = ad?.clickThroughUrl;
    if (ad == null || url == null || url.isEmpty) return;
    _pingUrls(ad.clickTracking);
    await ExternalBrowser.open(url);
  }

  Future<void> openAdIcon(VastIcon icon) async {
    _pingUrls(icon.clickTracking);
    final url = icon.clickThroughUrl;
    if (url == null || url.isEmpty) return;
    await ExternalBrowser.open(url);
  }

  Future<void> openAdCompanion(VastCompanion companion) async {
    _pingUrls(companion.clickTracking);
    final url = companion.clickThroughUrl;
    if (url == null || url.isEmpty) return;
    await ExternalBrowser.open(url);
  }

  bool _shouldPlayAds(MediaItem item) {
    if (item.isLive || item.kind == MediaKind.catchup) return false;
    if (item.origin == MediaOrigin.localFile) return false;
    if (library.offlinePlayPathFor(item) != null) return false;
    // Catalog / M3U DRM hints fail in _preparePlayable — skip prerolls.
    if (headersIndicateDrm(item.httpHeaders)) return false;
    return library.vastUrlFor(item) != null;
  }

  /// Starts a VAST break when the source/item has a tag. Returns true when
  /// an ad is now playing (content opens after the break).
  Future<bool> _maybeStartVast({
    required MediaItem playItem,
    required Duration? start,
    required double? seekResumeProgress,
    required int epoch,
  }) async {
    if (!_shouldPlayAds(playItem)) return false;
    final tag = library.vastUrlFor(playItem);
    if (tag == null) return false;
    VastSchedule schedule;
    try {
      schedule = await _vast.fetchSchedule(
        tag,
        macros: _vastMacrosForContent(playItem),
      );
    } catch (e) {
      JavpLog.w('vast', 'schedule fetch failed', error: e);
      return false;
    }
    if (_isStaleOpen(epoch)) return false;
    _vastSchedule = schedule;
    _playedMidrollIndexes.clear();
    _postrollsPlayed = false;
    _lastContentPosition = start ?? Duration.zero;
    if (schedule.prerolls.isEmpty) return false;
    _pendingAfterAds = _PendingAfterAds(
      item: playItem,
      start: start,
      seekResumeProgress: seekResumeProgress,
      epoch: epoch,
    );
    final ok = await _beginAdPod(schedule.prerolls);
    if (!ok) {
      _pendingAfterAds = null;
      return false;
    }
    JavpLog.i('vast', 'preroll start url=${_currentAd!.mediaUrl}');
    return true;
  }

  Future<bool> _beginAdPod(List<VastLinearAd> ads) async {
    for (var i = 0; i < ads.length; i++) {
      _adQueue = ads.sublist(i);
      _currentAd = ads[i];
      _adEventsFired.clear();
      _adViewableSince = null;
      _adViewableResolved = false;
      _iconViewFired.clear();
      _notifySession();
      try {
        await _openAdCreative(_currentAd!);
        return true;
      } catch (e) {
        JavpLog.w('vast', 'ad open failed', error: e);
        _pingUrls(_currentAd?.errorUrls ?? const [], errorCode: '405');
      }
    }
    _clearAdCreative();
    return false;
  }

  Future<void> _openAdCreative(VastLinearAd ad) async {
    await _openMedia(Media(ad.mediaUrl), play: true);
    _pingAdEvent('loaded');
    await _applyAdCaptions(ad);
  }

  Future<void> _applyAdCaptions(VastLinearAd ad) async {
    if (!AppCapabilities.usesMediaKit) return;
    final player = _player;
    if (player == null) return;
    VastCaption? cap;
    for (final c in ad.captions) {
      if (c.url.isNotEmpty) {
        cap = c;
        break;
      }
    }
    if (cap == null) return;
    try {
      await player.setSubtitleTrack(
        SubtitleTrack.uri(cap.url, language: cap.language, title: 'Ad'),
      );
    } catch (_) {}
  }

  Future<void> _finishCurrentAd({required bool skipped}) async {
    final ad = _currentAd;
    if (ad == null) return;
    if (skipped) {
      _pingAdEvent('skip');
    } else {
      _pingAdEvent('complete');
    }
    if (!_adViewableResolved) {
      _resolveViewable(undetermined: true);
    }
    final rest = _adQueue.length > 1
        ? _adQueue.sublist(1)
        : const <VastLinearAd>[];
    if (rest.isNotEmpty) {
      final ok = await _beginAdPod(rest);
      if (ok) return;
    }
    final pending = _pendingAfterAds;
    _clearAdBreak();
    _midrollInFlight = false;
    if (pending == null) return;
    if (_isStaleOpen(pending.epoch)) return;
    if (pending.thenComplete) {
      await _onVodCompleted(pending.item);
      return;
    }
    await _openPendingContent(pending);
  }

  Future<void> _openPendingContent(_PendingAfterAds pending) async {
    final epoch = pending.epoch;
    _opening = true;
    _notifySession();
    try {
      final prepared = await _preparePlayable(pending.item);
      if (_isStaleOpen(epoch)) return;
      _item = prepared.item;
      final start = pending.resumePosition ?? pending.start;
      _lastContentPosition = start ?? Duration.zero;
      await _openMedia(
        Media(
          prepared.playUrl,
          start: start,
          httpHeaders: _headersForPlayUrl(
            prepared.playUrl,
            prepared.item.httpHeaders,
          ),
        ),
        play: true,
      );
      if (_isStaleOpen(epoch)) return;
      _startPlexLiveKeepalive(prepared.item, prepared.playUrl);
      await _applyCatalogTracks(prepared.item);
      await _maybeApplyLanguagePreferences(force: true);
      if (pending.seekResumeProgress != null) {
        await _ensureResumedToProgress(
          pending.seekResumeProgress!,
          preferred: pending.start,
        );
      } else if (pending.resumePosition != null) {
        await _seekWhenReady(pending.resumePosition!);
      }
      unawaited(_refreshAdjacentEpisodes());
    } catch (e) {
      if (_isStaleOpen(epoch)) return;
      if (e is UnsupportedDrmException && e.playUrl != null) {
        // Preroll left _activePlayUrl on the ad creative; hand the content
        // URL to Open in external player.
        _activePlayUrl = e.playUrl;
      }
      _error = surfacePlayerError(e);
      JavpLog.w('play', 'open after ad break failed', error: e);
    } finally {
      if (!_isStaleOpen(epoch)) {
        _opening = false;
        _notifySession();
      }
    }
  }

  void _clearAdCreative() {
    _adQueue = const [];
    _currentAd = null;
    _adEventsFired.clear();
    _adViewableSince = null;
    _adViewableResolved = false;
    _iconViewFired.clear();
  }

  void _clearAdBreak() {
    _clearAdCreative();
    _pendingAfterAds = null;
  }

  void _clearVastSession() {
    _clearAdBreak();
    _vastSchedule = null;
    _playedMidrollIndexes.clear();
    _midrollInFlight = false;
    _postrollsPlayed = false;
    _lastContentPosition = Duration.zero;
  }

  void _maybeStartMidroll(Duration position, Duration duration) {
    if (_midrollInFlight || _currentAd != null) return;
    final schedule = _vastSchedule;
    if (schedule == null || schedule.midrolls.isEmpty) return;
    for (var i = 0; i < schedule.midrolls.length; i++) {
      if (_playedMidrollIndexes.contains(i)) continue;
      final brk = schedule.midrolls[i];
      if (!_crossedBreak(brk.offset, position, duration)) continue;
      _playedMidrollIndexes.add(i);
      unawaited(_startMidroll(brk));
      return;
    }
  }

  bool _crossedBreak(
    VastBreakOffset offset,
    Duration position,
    Duration duration,
  ) {
    Duration? cue;
    if (offset.time != null) {
      cue = offset.time;
    } else if (offset.percent != null && duration > Duration.zero) {
      cue = Duration(
        milliseconds: (duration.inMilliseconds * offset.percent! / 100).round(),
      );
    }
    if (cue == null) return false;
    return _lastContentPosition < cue && position >= cue;
  }

  Future<void> _startMidroll(VastTimedBreak brk) async {
    final item = _item;
    if (item == null || brk.ads.isEmpty) return;
    _midrollInFlight = true;
    _pendingAfterAds = _PendingAfterAds(
      item: item,
      start: _position,
      seekResumeProgress: null,
      epoch: _openEpoch,
      resumePosition: _position,
    );
    final ok = await _beginAdPod(brk.ads);
    if (!ok) {
      _midrollInFlight = false;
      _pendingAfterAds = null;
    } else {
      JavpLog.i('vast', 'midroll start url=${_currentAd!.mediaUrl}');
    }
  }

  void _fireAdProgress(Duration position, Duration duration) {
    final ad = _currentAd;
    if (ad == null) return;
    final total = ad.duration ?? (duration > Duration.zero ? duration : null);
    if (position > Duration.zero && !_adEventsFired.contains('start')) {
      _pingUrls(ad.impressions);
      _pingAdEvent('start');
      _pingAdEvent('creativeView');
      final companion = adCompanion;
      if (companion != null) {
        _pingUrls(companion.creativeView);
      }
      if (_expanded && !_minimized) {
        _adViewableSince = DateTime.now();
      }
    }
    if (_adViewableSince != null &&
        !_adViewableResolved &&
        _enginePlaying &&
        _expanded &&
        !_minimized &&
        DateTime.now().difference(_adViewableSince!) >=
            const Duration(seconds: 2)) {
      _resolveViewable();
    }
    _fireIconViews(position);
    if (total == null || total <= Duration.zero) return;
    final progress = position.inMilliseconds / total.inMilliseconds;
    if (progress >= 0.25) _pingAdEvent('firstQuartile');
    if (progress >= 0.5) _pingAdEvent('midpoint');
    if (progress >= 0.75) _pingAdEvent('thirdQuartile');
    for (var i = 0; i < ad.progressCues.length; i++) {
      final cue = ad.progressCues[i];
      var at = cue.offset;
      if (at == null && cue.percent != null) {
        at = Duration(
          milliseconds: (total.inMilliseconds * cue.percent! / 100).round(),
        );
      }
      if (at == null || position < at) continue;
      final key = '_progress_$i';
      if (!_adEventsFired.add(key)) continue;
      _pingUrls(cue.urls);
    }
    final skip = ad.skipOffset;
    if (skip != null &&
        position >= skip &&
        !_adEventsFired.contains('_skipReady')) {
      _adEventsFired.add('_skipReady');
      _notifySession();
    }
  }

  void _fireIconViews(Duration position) {
    final ad = _currentAd;
    if (ad == null) return;
    for (final icon in ad.icons) {
      final key = icon.staticUrl;
      if (_iconViewFired.contains(key)) continue;
      final start = icon.offset ?? Duration.zero;
      if (position < start) continue;
      if (icon.duration != null && position > start + icon.duration!) {
        continue;
      }
      _iconViewFired.add(key);
      _pingUrls(icon.viewTracking);
    }
  }

  void _pingAdEvent(String event) {
    final ad = _currentAd;
    if (ad == null) return;
    if (!_adEventsFired.add(event)) return;
    _pingUrls(ad.tracking[event] ?? const []);
  }

  void _pingUrls(Iterable<String> urls, {String? errorCode, String? reason}) {
    _vast.pingAll(
      urls,
      playhead: _position,
      errorCode: errorCode,
      reason: reason,
      macros: _vastMacros(errorCode: errorCode, reason: reason),
    );
  }

  void _resolveViewable({bool leftEarly = false, bool undetermined = false}) {
    final ad = _currentAd;
    if (ad == null || _adViewableResolved) return;
    _adViewableResolved = true;
    if (undetermined) {
      _pingUrls(ad.viewUndetermined);
      return;
    }
    if (leftEarly) {
      _pingUrls(ad.notViewable);
      return;
    }
    _pingUrls(ad.viewable);
  }

  VastMacroContext _vastMacros({String? errorCode, String? reason}) {
    return _vastMacrosForContent(_item).copyWith(
      errorCode: errorCode,
      reason: reason,
      adPlayhead: isPlayingAd ? _position : Duration.zero,
      assetUri: _currentAd?.mediaUrl ?? '',
      mediaMime: _currentAd?.mediaMime ?? 'video/mp4',
      universalAdId: _currentAd?.universalAdId ?? '',
    );
  }

  VastMacroContext _vastMacrosForContent(MediaItem? item) {
    return VastMacroContext.now(
      userAgent: 'JAVP',
      contentPlayhead: isPlayingAd
          ? (_pendingAfterAds?.resumePosition ?? _lastContentPosition)
          : _position,
      contentUri: item?.playUrl ?? _activePlayUrl ?? '',
      contentId: item?.id ?? '',
      playerState: VastMacros.playerState(
        muted: isMuted,
        fullscreen: _cinemaMode && _expanded && !_minimized,
        playing: _enginePlaying,
      ),
    );
  }
}
