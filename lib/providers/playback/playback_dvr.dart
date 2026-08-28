part of '../playback_provider.dart';

extension PlaybackDvr on PlaybackProvider {
  /// Live channel (or DVR session from one) that supports archive scrubbing.
  ///
  /// True when Xtream/media-server catchup exists, or the live HLS playlist
  /// itself exposes a Clappr-sized rewind window.
  bool get canLiveDvr {
    final channel = liveChannel;
    if (channel == null) return false;
    if (library.liveSupportsCatchup(channel)) return true;
    return _nativeHlsDvrEnabled;
  }

  bool get isAtLiveEdge {
    if (_livePausedAt != null || _dvrStart != null) return false;
    final live =
        _item?.isLive == true ||
        (_liveChannel != null && _item?.kind != MediaKind.catchup);
    if (!live) return false;
    if (_nativeHlsDvrEnabled) {
      return hlsNativeDvrAtLiveEdge(
        position: _position,
        duration: _engineDuration,
      );
    }
    return true;
  }

  bool get canStartOver {
    final channel = liveChannel;
    final program = currentProgram;
    if (channel == null || program == null) return false;
    if (library.liveSupportsCatchup(channel) || program.hasArchive) {
      return true;
    }
    return _canUseNativeHlsDvrFor(program.start);
  }

  /// Clappr-style DVR on the live HLS mount (not an Xtream timeshift clip).
  bool get _nativeHlsDvrEnabled {
    if (_dvrStart != null) return false;
    final item = _item;
    if (item == null || !item.isLive) return false;
    return hlsNativeDvrEnabled(
      isLive: true,
      playUrl: item.playUrl,
      playableDuration: _engineDuration,
    );
  }

  bool _canUseNativeHlsDvrFor(DateTime target) {
    if (!_nativeHlsDvrEnabled) return false;
    return hlsNativeDvrContains(
      target: target,
      now: DateTime.now(),
      window: _engineDuration,
    );
  }

  /// How far behind the live edge we are while in DVR mode (or paused at live).
  Duration get liveDelay {
    if (!canLiveDvr) return Duration.zero;
    final absolute = _dvrPlayheadWallClock;
    if (absolute == null) return Duration.zero;
    final behind = DateTime.now().difference(absolute);
    return behind.isNegative ? Duration.zero : behind;
  }

  Duration get liveDvrWindow {
    final channel = liveChannel;
    if (channel == null) return Duration.zero;
    final days = library.resolveCatchupChannel(channel)?.catchupDays ?? 0;
    if (days > 0) {
      // Cap scrub window for usable scrubbing; full archive still via EPG.
      final hours = (days * 24).clamp(1, 24);
      return Duration(hours: hours);
    }
    if (_nativeHlsDvrEnabled) return _engineDuration;
    return Duration.zero;
  }

  /// 0 = oldest end of the DVR window, 1 = live edge.
  double get liveDvrProgress {
    if (!canLiveDvr) return 1;
    final absolute = _dvrPlayheadWallClock;
    if (absolute == null) return 1;
    final window = liveDvrWindow;
    if (window.inMilliseconds <= 0) return 1;
    final now = DateTime.now();
    final start = now.subtract(window);
    final clamped = absolute.isBefore(start)
        ? start
        : (absolute.isAfter(now) ? now : absolute);
    return (clamped.difference(start).inMilliseconds / window.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  /// Wall-clock time represented by the current playhead (live edge or DVR).
  DateTime get playbackWallClock {
    return _dvrPlayheadWallClock ?? DateTime.now();
  }

  /// Playhead as wall-clock while timeshifted or paused at the live edge.
  DateTime? get _dvrPlayheadWallClock {
    // Uses [_position], which is updated from the engine stream and eagerly on
    // in-clip seeks — engine `state.position` can lag a tick after scrub.
    if (_dvrStart != null) return _dvrStart!.add(_position);
    if (_livePausedAt != null) return _livePausedAt;
    if (_nativeHlsDvrEnabled) {
      final delay = hlsNativeDvrDelay(
        position: _position,
        duration: _engineDuration,
      );
      if (delay <= kLiveEdgeSeekMargin) return null;
      return DateTime.now().subtract(delay);
    }
    return null;
  }

  /// Preferred scrub mapping when an EPG programme is available.
  LiveScrubMode get liveScrubMode => library.liveScrubMode;

  /// Programme scrubber is active (preference + current EPG programme).
  bool get usesProgramScrubber =>
      liveScrubMode == LiveScrubMode.program && currentProgram != null;

  /// 0…1 within the current EPG programme (start → end).
  ///
  /// The live edge is [liveProgramLiveFraction] — scrubbing past it jumps to
  /// live. While watching live the thumb sits on that edge, not at 1.0 unless
  /// the show is over.
  double? get liveProgramProgress {
    final program = currentProgram;
    if (program == null || program.duration.inMilliseconds <= 0) return null;
    final wall = playbackWallClock;
    if (wall.isBefore(program.start)) return 0;
    if (!wall.isBefore(program.end)) return 1;
    return (wall.difference(program.start).inMilliseconds /
            program.duration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  /// How far through the programme the live edge currently is (0…1).
  double? get liveProgramLiveFraction {
    final program = currentProgram;
    if (program == null || program.duration.inMilliseconds <= 0) return null;
    final now = DateTime.now();
    if (now.isBefore(program.start)) return 0;
    if (!now.isBefore(program.end)) return 1;
    return now.difference(program.start).inMilliseconds /
        program.duration.inMilliseconds;
  }

  /// The overlay reads the current/next programme half a dozen times per build
  /// and rebuilds several times a second, so the EPG lookup is cached until the
  /// playhead crosses a second boundary or the guide changes underneath us.
  void _refreshProgramCache() {
    final channel = liveChannel;
    if (channel == null) {
      _programCacheKey = null;
      _cachedCurrentProgram = null;
      _cachedNextProgram = null;
      return;
    }
    final wall = playbackWallClock;
    final key =
        '${channel.id}@'
        '${wall.millisecondsSinceEpoch ~/ 1000}#'
        '${library.epgRevision}';
    if (key == _programCacheKey) return;
    _programCacheKey = key;
    _cachedCurrentProgram = library.programAt(channel, at: wall);
    _cachedNextProgram = library.nextProgramFor(channel, at: wall);
  }

  EpgProgram? get currentProgram {
    _refreshProgramCache();
    return _cachedCurrentProgram;
  }

  EpgProgram? get nextProgram {
    _refreshProgramCache();
    return _cachedNextProgram;
  }

  /// Scrub the live DVR timeline. `progress` is 0…1 within [now-window, now].
  Future<void> seekLiveDvrProgress(double progress) async {
    if (!canLiveDvr || _dvrBusy) return;
    final window = liveDvrWindow;
    if (window.inMilliseconds <= 0) return;

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped >= 0.985) {
      await jumpToLive();
      return;
    }

    final now = DateTime.now();
    final target = now.subtract(window * (1.0 - clamped));
    await seekLiveDvrTo(target);
  }

  /// Scrub within the current EPG programme.
  ///
  /// `progress` is 0…1 of the programme (start → end). Values at or past the
  /// live edge jump to live.
  Future<void> seekLiveProgramProgress(double progress) async {
    if (!canLiveDvr || _dvrBusy) return;
    final program = currentProgram;
    if (program == null || program.duration.inMilliseconds <= 0) return;

    final clamped = progress.clamp(0.0, 1.0);
    final liveFrac = liveProgramLiveFraction ?? 1.0;
    if (liveFrac <= 0) return;
    if (clamped >= liveFrac * 0.985) {
      await jumpToLive();
      return;
    }

    final absProgress = clamped.clamp(0.0, liveFrac);
    final target = program.start.add(
      Duration(
        milliseconds: (program.duration.inMilliseconds * absProgress).round(),
      ),
    );
    await seekLiveDvrTo(target);
  }

  /// Scrub using the active live scrub mode (timeline or programme).
  Future<void> seekLiveScrubProgress(double progress) async {
    if (usesProgramScrubber) {
      await seekLiveProgramProgress(progress);
    } else {
      await seekLiveDvrProgress(progress);
    }
  }

  /// Jump to an absolute wall-clock time inside the catchup window.
  Future<void> seekLiveDvrTo(DateTime target) async {
    if (!canLiveDvr || _dvrBusy) return;
    _clearLivePausedAt();
    final live = liveChannel!;
    final channel = library.resolveCatchupChannel(live) ?? live;
    final window = liveDvrWindow;
    final now = DateTime.now();
    final earliest = now.subtract(window);

    var safe = target;
    // Only treat near-now as live. Must stay below the ±10s seek step or
    // rewind from the live edge immediately snaps back to live.
    if (safe.isAfter(now.subtract(const Duration(seconds: 2)))) {
      await jumpToLive();
      return;
    }
    if (safe.isBefore(earliest)) safe = earliest;

    // Prefer Clappr-style in-playlist seeking when the live HLS window still
    // covers [safe]. Timeshift remount is only for older catchup.
    if (_canUseNativeHlsDvrFor(safe)) {
      await _seekNativeHlsDvrTo(safe);
      return;
    }
    if (_nativeHlsDvrEnabled && !library.liveSupportsCatchup(live)) {
      await _seekInClip(Duration.zero);
      return;
    }

    // Fine seek inside the already-open timeshift clip when the demuxer can
    // reach it. Progressive MPEG-TS cannot invent unbuffered data — reopen.
    if (_dvrStart != null && _item?.kind == MediaKind.catchup) {
      final local = safe.difference(_dvrStart!);
      if (_canSeekWithinOpenTimeshift(local)) {
        await _seekInClip(local);
        return;
      }
    }

    _dvrBusy = true;
    _error = null;
    _notifySession();
    try {
      // Continuous window from the target — not a tiny until-live slice.
      // −10s from live used to open a ~10s clip that immediately completed
      // and jumped back to live.
      final program = library.programAt(live, at: safe);
      final title = program != null
          ? '${program.title} (Catchup)'
          : '${live.title} (DVR)';
      final duration = _continuousTimeshiftDuration(start: safe);
      final clip = library.liveDvrItem(
        channel: channel,
        start: safe,
        duration: duration,
        title: title,
        allowWithoutCatchup: program?.hasArchive ?? false,
        clampToLive: false,
      );
      final start = clip != null
          ? (LibraryProvider.catchupStartOf(clip) ?? safe)
          : safe;
      final openDuration = clip?.duration ?? duration;
      final ok = await _openTimeshift(
        channel: channel,
        liveViewChannel: live,
        start: start,
        duration: openDuration.inSeconds <= 0
            ? kDvrTimeshiftMinWindow
            : openDuration,
        title: title,
        thumbnailUrl: program?.imageUrl ?? live.thumbnailUrl,
      );
      if (ok) {
        // Only needed when start was clamped earlier than [safe] (archive window).
        final intoClip = safe.difference(start);
        if (_canSeekWithinOpenTimeshift(intoClip) &&
            intoClip > const Duration(seconds: 2)) {
          await _seekInClip(intoClip);
        }
        unawaited(_persistDvrProgress());
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _dvrBusy = false;
      _notifySession();
    }
  }

  /// Forward window for interactive DVR — well past live, not until-live.
  Duration _continuousTimeshiftDuration({required DateTime start}) {
    return continuousTimeshiftDuration(start: start, now: DateTime.now());
  }

  /// Wall-clock resume point for a History / Continue watching catchup row.
  DateTime? _resumeWallClockForCatchup(MediaItem item) {
    final start =
        _parseCatchupStart(item) ?? LibraryProvider.catchupStartOf(item);
    final channel = _liveChannel;
    final program = (channel != null && start != null)
        ? library.programAt(channel, at: start)
        : (start != null ? library.programAt(item, at: start) : null);
    return catchupResumeWallClock(
      programStart: start,
      progress: item.progress,
      programDuration: program?.duration,
      fallbackDuration: item.duration,
    );
  }

  /// Timeshift clip ended — extend if still behind live, else join live.
  Future<void> _onTimeshiftCompleted() async {
    final start = _dvrStart;
    if (start == null || _liveChannel == null || _dvrBusy) return;
    // Buffer underrun / demuxer stall can look like EOF while the playhead is
    // still minutes behind live — never treat that as "caught up".
    if (_engineBuffering) {
      JavpLog.i(
        'playback',
        'timeshift completed while buffering — ignore false EOF',
      );
      return;
    }
    // Actual playhead, not the requested clip length. A 3h window that HLS
    // ended at the old live edge would look "ahead of now" and jump to live.
    final wall = start.add(_position);
    final behind = DateTime.now().difference(wall);
    if (shouldJoinLiveAfterTimeshift(behindLive: behind)) {
      await jumpToLive();
      return;
    }
    final now = DateTime.now();
    if (_lastTimeshiftExtendAt != null &&
        now.difference(_lastTimeshiftExtendAt!) < const Duration(seconds: 4)) {
      // Previous extend produced another instant EOF. Only join live when we
      // are actually near now — otherwise keep extending so buffering loops
      // do not skip the archive gap.
      if (behind <= const Duration(seconds: 15)) {
        await jumpToLive();
        return;
      }
      JavpLog.w(
        'playback',
        'timeshift extend loop behind=${behind.inSeconds}s — retry, not live',
      );
    }
    _lastTimeshiftExtendAt = now;
    await seekLiveDvrTo(wall);
  }

  /// Switch to another quality variant (same EPG) for this playback/session.
  ///
  /// Does **not** persist [LibraryProvider.preferredLiveQualities] — use
  /// [LibraryProvider.setPreferredLiveQuality] for an explicit remember.
  Future<void> switchLiveQuality(MediaItem variant) async {
    if (!variant.isLive) return;
    // Native HLS DVR keeps [_dvrStart] null while scrubbed behind live — still
    // restore that wall-clock after the quality remount.
    final resumeAt = isAtLiveEdge ? null : playbackWallClock;
    await library.setSessionLiveQuality(variant);
    await _runQualityRetune(() async {
      await open(variant, expand: isExpanded || !isMinimized, quiet: true);
      if (resumeAt != null) {
        _pendingNativeHlsLiveJoin = false;
        _nearLiveSeekGeneration++;
        if (canLiveDvr) {
          await seekLiveDvrTo(resumeAt);
        }
      }
    });
  }

  /// Delayed libmpv open failures (playing=true before TCP dies) — try siblings.
  void _maybeFallbackLiveQualityOnOpenError(MediaItem item, String message) {
    if (!item.isLive || _dvrStart != null) return;
    if (!_awaitingInitialPlayback) return;
    if (_liveQualityFallbackInFlight) return;
    if (!PlaybackProvider.isFatalStreamOpenFailure(message)) return;
    unawaited(
      _tryNextLiveQualitySibling(
        failed: item,
        expand: _expanded || !_minimized,
      ),
    );
  }

  void _markLiveVariantTried(MediaItem channel) {
    final streamId = channel.streamId?.trim() ?? '';
    if (streamId.isNotEmpty) _triedLiveStreamIds.add(streamId);
    _triedLiveStreamIds.add(channel.id);
  }

  /// Preferred/Auto feed failed — try the next HD/SD sibling without persisting
  /// a preferred quality. Returns true when a sibling open succeeded.
  ///
  /// Walks the ranked family here: nested [open] still awaits demux but does
  /// not re-enter this method while [_liveQualityFallbackInFlight] is set
  /// (that flag also blocks racing error-stream fallback).
  Future<bool> _tryNextLiveQualitySibling({
    required MediaItem failed,
    required bool expand,
  }) async {
    if (_liveQualityFallbackInFlight) return false;
    if (!failed.isLive || _dvrStart != null) return false;

    _markLiveVariantTried(failed);
    List<MediaItem> variants;
    try {
      variants = await library.qualityVariantsForAsync(failed);
    } catch (e) {
      JavpLog.w('play', 'live quality variants failed', error: e);
      return false;
    }
    if (variants.length <= 1) return false;
    final ranked = [...variants]..sort(ChannelQuality.compareVariants);

    _liveQualityFallbackInFlight = true;
    try {
      while (true) {
        final next = ChannelQuality.nextVariantAfter(
          ranked,
          triedStreamIds: _triedLiveStreamIds,
        );
        if (next == null) return false;

        JavpLog.w(
          'play',
          'live quality fallback '
              'from=${failed.streamId ?? failed.id} '
              'to=${next.streamId ?? next.id} '
              'tried=${_triedLiveStreamIds.length}/${ranked.length}',
        );
        try {
          await library.setSessionLiveQuality(next);
          _error = null;
          await open(next, expand: expand, quiet: true);
          if (_error == null || _error!.isEmpty) return true;
          _markLiveVariantTried(next);
        } catch (e) {
          JavpLog.w('play', 'live quality fallback open failed', error: e);
          _markLiveVariantTried(next);
        }
      }
    } finally {
      _liveQualityFallbackInFlight = false;
    }
  }

  /// Relative seek on the live DVR timeline (double-tap ±10s, etc.).
  Future<void> seekLiveDvrBy(Duration delta) async {
    if (!canLiveDvr) return;

    // Already inside a timeshift clip — nudge the playhead directly when the
    // target stays reachable. Avoids reopening (and stale wall-clock math).
    if (_dvrStart != null && _item?.kind == MediaKind.catchup) {
      // Trust [_position] (eagerly updated on scrub). Engine state can lag
      // behind after a seek-back and must not overwrite the cached playhead.
      final current = _position;
      final target = current + delta;
      if (_canSeekWithinOpenTimeshift(target)) {
        _clearLivePausedAt();
        await _seekInClip(target);
        return;
      }
      await seekLiveDvrTo(_dvrStart!.add(current).add(delta));
      return;
    }

    await seekLiveDvrTo(playbackWallClock.add(delta));
  }

  /// Seek inside the live HLS sliding window (oldest = 0, live ≈ duration).
  Future<void> _seekNativeHlsDvrTo(DateTime target) async {
    _clearLivePausedAt();
    final window = _engineDuration;
    // Duration often drops to 0 while buffering — that must not mean "live".
    if (window.inMilliseconds <= 0) {
      JavpLog.i(
        'playback',
        'native hls dvr seek deferred — duration unknown',
      );
      return;
    }
    final pos = hlsNativeDvrSeekPosition(
      target: target,
      now: DateTime.now(),
      window: window,
    );
    if (pos == null) {
      await jumpToLive();
      return;
    }
    await _seekInClip(pos);
  }

  /// Whether [local] (offset from [_dvrStart]) can be seeked in the open clip.
  ///
  /// HLS VOD timeshift has a full segment map — seek anywhere in duration.
  /// Progressive MPEG-TS only has what the demuxer has buffered; seeking far
  /// ahead stalls. In that case callers reopen a timeshift URL at the target.
  bool _canSeekWithinOpenTimeshift(Duration local) {
    if (local.isNegative) return false;
    final dur = _engineDuration;
    final url = (_item?.playUrl ?? '').toLowerCase();
    final hls = url.contains('.m3u8');

    if (hls) {
      if (dur.inMilliseconds <= 0) return true;
      return local <= dur - const Duration(seconds: 2);
    }

    // Progressive TS / timeshift.php — stay inside the demuxer cache.
    if (dur.inMilliseconds > 0 && local > dur - const Duration(seconds: 2)) {
      return false;
    }
    final buffer = _engineBuffer;
    final cached = buffer > _position ? buffer : _position;
    // Rewind and small forward nudges near the playhead.
    if (local <= _position + const Duration(seconds: 12)) return true;
    if (local <= cached + const Duration(seconds: 3)) return true;
    return false;
  }

  /// Seek near the end of a seekable live HLS window after joining live.
  ///
  /// True live with no reported duration is left alone. Failures that look
  /// like "not seekable" are treated as already-at-edge.
  ///
  /// [openEpoch] must match the session that requested the join; a later
  /// [open] bumps [_openEpoch] and abandons this loop so VOD/other live is
  /// not seeked to `duration - margin`.
  Future<void> _seekNearLiveEdge({int? openEpoch}) async {
    final joinEpoch = openEpoch ?? _openEpoch;
    final generation = ++_nearLiveSeekGeneration;
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (generation != _nearLiveSeekGeneration || _isStaleOpen(joinEpoch)) {
        return;
      }
      if (_item?.isLive != true || _dvrStart != null) return;
      final duration = _engineDuration;
      if (hlsNativeDvrAtLiveEdge(position: _position, duration: duration) &&
          liveEdgeSeekTarget(duration) != null) {
        return;
      }
      final target = liveEdgeSeekTarget(duration);
      if (target != null) {
        try {
          await _engineSeek(target);
          if (generation != _nearLiveSeekGeneration ||
              _isStaleOpen(joinEpoch) ||
              _item?.isLive != true ||
              _dvrStart != null) {
            return;
          }
          _position = target;
          _notifySession();
          return;
        } catch (e) {
          final msg = e.toString();
          if (PlaybackProvider.isBenignPlayerMessage(msg)) return;
          // Demuxer not ready yet — retry.
        }
      } else if (duration.inMilliseconds > 0) {
        // Window shorter than the margin — nothing useful to seek.
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  Future<void> jumpToLive() async {
    final channel = liveChannel;
    if (channel == null) return;
    _clearLivePausedAt();
    // Catch-up finished — do not keep >1x on the live mount.
    unawaited(_snapRateToRealtimeIfNeeded(reason: 'jump to live', force: true));
    _pendingNativeHlsLiveJoin = false;

    // Timeshift (or any other URL) must remount; same live URL still needs a
    // near-edge seek because force-seekable windows open at segment 0.
    final needsRemount = _dvrStart != null || _item?.playUrl != channel.playUrl;

    _dvrBusy = true;
    _error = null;
    _notifySession();
    try {
      _dvrStart = null;
      _lastTimeshiftExtendAt = null;
      _item = channel;

      if (needsRemount) {
        await _clearEngineBeforeLoad();
        // Channel rows store credential-stripped Xtream URLs — inject via
        // [_preparePlayable] like a normal live open (never `/live/id.ts`).
        final prepared = await _preparePlayable(channel);
        // Keep the live channel identity (stripped playUrl); engine got creds.
        _item = prepared.item.copyWith(playUrl: channel.playUrl);
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
      } else if (!_enginePlaying) {
        await _enginePlay();
      }

      await _seekNearLiveEdge();
      unawaited(library.recordWatch(channel));
    } catch (e) {
      _error = e.toString();
    } finally {
      _dvrBusy = false;
      _notifySession();
    }
  }

  /// Restart the currently airing EPG programme from its start (Start Over).
  Future<bool> startOverCurrentProgram() async {
    final channel = liveChannel;
    final program = currentProgram;
    if (channel == null || program == null) return false;
    if (!library.liveSupportsCatchup(channel) && !program.hasArchive) {
      if (!_canUseNativeHlsDvrFor(program.start)) return false;
    }
    await seekLiveDvrTo(program.start);
    return true;
  }

  void _clearLivePausedAt() {
    _livePausedAt = null;
    _livePauseTicker?.cancel();
    _livePauseTicker = null;
  }

  void _armLivePauseTicker() {
    _livePauseTicker?.cancel();
    _livePauseTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_livePausedAt == null) {
        _livePauseTicker?.cancel();
        _livePauseTicker = null;
        return;
      }
      _notifySession();
    });
  }

  /// Try common Xtream timeshift URL shapes until one actually opens.
  ///
  /// [channel] is the archive stream (may be a catchup sibling).
  /// [liveViewChannel] stays as the live-edge tune so Jump to Live does not
  /// permanently drop to a lower-quality catchup sibling.
  Future<bool> _openTimeshift({
    required MediaItem channel,
    required DateTime start,
    required Duration duration,
    required String title,
    String? thumbnailUrl,
    MediaItem? liveViewChannel,
  }) async {
    final archive = library.resolveCatchupChannel(channel) ?? channel;
    if (archive.origin.isMediaServer) {
      return _openMediaServerTimeshift(
        channel: archive,
        liveViewChannel: liveViewChannel ?? _liveChannel,
        start: start,
        duration: duration,
        title: title,
        thumbnailUrl: thumbnailUrl,
      );
    }

    final urls = library.timeshiftUrlsFor(
      channel: archive,
      start: start,
      duration: duration,
    );
    if (urls.isEmpty) {
      _error = 'Catchup / DVR is unavailable for this channel.';
      _notifySession();
      return false;
    }

    final timeshiftHeaders = _playbackHeaders(archive.httpHeaders);

    String? lastError;
    // Keep the candidate list short — each open is expensive on IPTV.
    // 9 covers m3u8+php+ts for the first three stamp variants.
    final attempts = urls.length > 9 ? urls.sublist(0, 9) : urls;
    for (var i = 0; i < attempts.length; i++) {
      final url = attempts[i];
      final last = i == attempts.length - 1;
      final hls = url.toLowerCase().contains('.m3u8');
      _error = null;
      _notifySession();
      try {
        await _engineStop();
        await _openMedia(Media(url, httpHeaders: timeshiftHeaders), play: true);
      } catch (e) {
        lastError = e.toString();
        continue;
      }
      // HLS playlists report duration before segments fetch — require real
      // playback/buffer so a 401'd segment map does not "succeed".
      final ok = await _awaitOpenOutcome(
        lenient: last && !hls,
        requireDemux: hls,
      );
      if (ok) {
        _dvrStart = start;
        _retainLiveChannelAfterTimeshift(
          archive: archive,
          liveViewChannel: liveViewChannel,
        );
        final art = thumbnailUrl?.trim();
        _item = MediaItem(
          id: 'dvr-${archive.streamId}-${start.millisecondsSinceEpoch}',
          title: title,
          playUrl: url,
          kind: MediaKind.catchup,
          origin: MediaOrigin.iptvXtream,
          subtitle: (liveViewChannel ?? _liveChannel ?? archive).title,
          thumbnailUrl: (art != null && art.isNotEmpty)
              ? art
              : archive.thumbnailUrl,
          group: archive.group,
          duration: duration > kDvrTimeshiftMaxWindow
              ? kDvrTimeshiftMaxWindow
              : duration,
          channelId: archive.channelId,
          streamId: archive.streamId,
          epgChannelId: archive.epgChannelId,
          catchupDays: archive.catchupDays,
          sourceId: archive.sourceId,
        );
        _notifySession();
        return true;
      }
      lastError = _error ?? 'Failed to open';
    }

    _error = lastError ?? 'Failed to open timeshift stream';
    _notifySession();
    return false;
  }

  /// Keep the live Auto/quality pick as [_liveChannel] when timeshift used a
  /// catchup sibling stream id.
  void _retainLiveChannelAfterTimeshift({
    required MediaItem archive,
    MediaItem? liveViewChannel,
  }) {
    final keep = liveViewChannel ?? _liveChannel;
    if (keep != null && keep.isLive) {
      _liveChannel = keep;
      return;
    }
    _liveChannel = archive.isLive ? archive : (_liveChannel ?? archive);
  }

  /// Plex / Jellyfin / Emby Start Over via live tune + transcoder offset.
  Future<bool> _openMediaServerTimeshift({
    required MediaItem channel,
    required DateTime start,
    required Duration duration,
    required String title,
    String? thumbnailUrl,
    MediaItem? liveViewChannel,
  }) async {
    final dvr = library.liveDvrItem(
      channel: channel,
      start: start,
      duration: duration,
      title: title,
      allowWithoutCatchup: true,
      clampToLive: true,
    );
    if (dvr == null || (dvr.serverItemId ?? '').trim().isEmpty) {
      _error = 'Catchup / DVR is unavailable for this channel.';
      _notifySession();
      return false;
    }

    _error = null;
    _notifySession();
    try {
      // Drop the prior live/tuner session before retuning with an offset.
      _endMediaServerLiveSession(stopped: true);
      await _engineStop();
      final prepared = await _preparePlayable(dvr);
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
      final ok = await _awaitOpenOutcome(lenient: true, requireDemux: true);
      if (!ok) {
        _error = _error ?? 'Failed to open timeshift stream';
        _notifySession();
        return false;
      }
      _dvrStart = start;
      _retainLiveChannelAfterTimeshift(
        archive: channel,
        liveViewChannel: liveViewChannel,
      );
      final art = thumbnailUrl?.trim();
      final clipDuration = duration > kDvrTimeshiftMaxWindow
          ? kDvrTimeshiftMaxWindow
          : duration;
      _item = MediaItem(
        id: dvr.id,
        title: title,
        playUrl: prepared.playUrl,
        kind: MediaKind.catchup,
        origin: channel.origin,
        subtitle: (liveViewChannel ?? _liveChannel ?? channel).title,
        thumbnailUrl: (art != null && art.isNotEmpty)
            ? art
            : channel.thumbnailUrl,
        group: channel.group,
        duration: clipDuration,
        channelId: channel.channelId,
        streamId: channel.streamId,
        epgChannelId: channel.epgChannelId,
        catchupDays: channel.catchupDays,
        sourceId: channel.sourceId,
        serverItemId: dvr.serverItemId,
        resolution: dvr.resolution,
        httpHeaders: prepared.item.httpHeaders,
        audioTracks: prepared.item.audioTracks,
        subtitles: prepared.item.subtitles,
      );
      _startPlexLiveKeepalive(_item!, prepared.playUrl);
      _notifySession();
      return true;
    } catch (e) {
      _error = e.toString();
      _notifySession();
      return false;
    }
  }

  Future<bool> _awaitOpenOutcome({
    bool lenient = false,
    bool requireDemux = false,
  }) async {
    final errorReady = Completer<String?>();
    final StreamSubscription<String> sub;
    if (AppCapabilities.usesVideoPlayerBackend) {
      final vp = _vp;
      if (vp == null) return false;
      sub = vp.errorStream.listen((msg) {
        if (msg.isEmpty || errorReady.isCompleted) return;
        errorReady.complete(msg);
      });
    } else {
      final player = _player;
      if (player == null) return false;
      sub = player.stream.error.listen((msg) {
        if (msg.isEmpty ||
            PlaybackProvider.isBenignPlayerMessage(msg) ||
            errorReady.isCompleted) {
          return;
        }
        errorReady.complete(msg);
      });
    }
    try {
      // MPEG-TS / HLS timeshift often needs a few seconds before demux starts.
      final deadline = DateTime.now().add(
        Duration(milliseconds: requireDemux ? 10000 : (lenient ? 8000 : 5000)),
      );
      while (DateTime.now().isBefore(deadline)) {
        if (errorReady.isCompleted) {
          _error = await errorReady.future;
          return false;
        }
        if (requireDemux) {
          // Duration alone is not enough — VOD playlists advertise it up front.
          if (_enginePlaying ||
              _engineBuffer > Duration.zero ||
              (_engineBuffering && _enginePosition > Duration.zero)) {
            return true;
          }
        } else if (_enginePlaying ||
            _engineBuffering ||
            _engineDuration > Duration.zero) {
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (lenient) {
        // Last candidate: keep slow IPTV opens that haven't hard-failed.
        return _error == null || _error!.isEmpty;
      }
      _error = 'Failed to open';
      return false;
    } finally {
      await sub.cancel();
    }
  }

  DateTime? _parseCatchupStart(MediaItem item) {
    final fromId = RegExp(r'^dvr-.+-(\d+)$').firstMatch(item.id);
    if (fromId != null) {
      final ms = int.tryParse(fromId.group(1)!);
      if (ms != null) {
        // Match [catchupStartOf] — local DateTime for the absolute epoch.
        return DateTime.fromMillisecondsSinceEpoch(ms);
      }
    }
    final serverId = item.serverItemId?.trim() ?? '';
    if (serverId.isNotEmpty) {
      final plex = PlexClient.parseLiveServerItemId(serverId);
      if (plex?.startAt != null) return plex!.startAt;
      final jf = JellyfinClient.parseLiveServerItemId(serverId);
      if (jf?.startAt != null) return jf!.startAt;
    }
    return _parseTimeshiftStart(item.playUrl);
  }

  /// Persist DVR/catchup against the EPG programme when known so Home shows
  /// the show title and can expire with the archive window.
  ///
  /// Uses [LibraryProvider.recordProgress] (cheap) — never [recordWatch] on
  /// the 5s tick (that loads tombstone prefs and scans catalog).
  Future<void> _persistDvrProgress({double? clipProgress}) async {
    final channel = liveChannel;
    final item = _item;
    if (channel == null || item == null || _dvrStart == null) return;

    final wall = playbackWallClock;
    final program = library.programAt(channel, at: wall);
    double progress = clipProgress ?? 0;
    if (clipProgress == null) {
      final duration = _engineDuration;
      if (duration.inMilliseconds > 0) {
        progress = _enginePosition.inMilliseconds / duration.inMilliseconds;
      }
    }

    if (program != null && program.duration.inMilliseconds > 0) {
      final within =
          wall.difference(program.start).inMilliseconds /
          program.duration.inMilliseconds;
      progress = within.clamp(0.0, 1.0);
      final historyItem = library.catchupHistoryItem(
        channel: channel,
        at: program.start,
        progress: progress,
      );
      if (historyItem != null) {
        await library.recordProgress(historyItem, progress);
        return;
      }
    }

    final fallback = library.catchupHistoryItem(
      channel: channel,
      at: _dvrStart!,
      progress: progress,
    );
    await library.recordProgress(
      fallback ??
          item.copyWith(
            title:
                item.title.contains('(DVR)') || item.title.contains('(Catchup)')
                ? item.title
                : '${channel.title} (DVR)',
          ),
      progress,
    );
  }

  /// Parse start from path `/timeshift/.../{stamp}/id.ts` or `?start=`.
  DateTime? _parseTimeshiftStart(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final queryStart = uri.queryParameters['start'];
    if (queryStart != null) {
      final parsed = _parseStamp(queryStart);
      if (parsed != null) return parsed;
    }
    final parts = uri.pathSegments;
    final idx = parts.indexOf('timeshift');
    if (idx < 0 || parts.length <= idx + 4) return null;
    return _parseStamp(parts[idx + 4]);
  }

  DateTime? _parseStamp(String stamp) {
    final raw = Uri.decodeComponent(stamp.trim());
    // YYYY-MM-DD:HH-MM or YYYY-MM-DD-HH-MM
    final dashed = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[:\-](\d{2})-(\d{2})$',
    ).firstMatch(raw);
    if (dashed != null) {
      return DateTime.utc(
        int.parse(dashed.group(1)!),
        int.parse(dashed.group(2)!),
        int.parse(dashed.group(3)!),
        int.parse(dashed.group(4)!),
        int.parse(dashed.group(5)!),
      );
    }
    // YYYY-MM-DD:HH:MM
    final colonTime = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2}):(\d{2}):(\d{2})$',
    ).firstMatch(raw);
    if (colonTime != null) {
      return DateTime.utc(
        int.parse(colonTime.group(1)!),
        int.parse(colonTime.group(2)!),
        int.parse(colonTime.group(3)!),
        int.parse(colonTime.group(4)!),
        int.parse(colonTime.group(5)!),
      );
    }
    // YYYY-MM-DD HH:MM:SS (EPG wall clock)
    final epg = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$',
    ).firstMatch(raw);
    if (epg != null) {
      return DateTime.utc(
        int.parse(epg.group(1)!),
        int.parse(epg.group(2)!),
        int.parse(epg.group(3)!),
        int.parse(epg.group(4)!),
        int.parse(epg.group(5)!),
        int.tryParse(epg.group(6) ?? '') ?? 0,
      );
    }
    // YYYYMMDDHHMMSS
    if (raw.length >= 14 && int.tryParse(raw.substring(0, 14)) != null) {
      return DateTime.utc(
        int.parse(raw.substring(0, 4)),
        int.parse(raw.substring(4, 6)),
        int.parse(raw.substring(6, 8)),
        int.parse(raw.substring(8, 10)),
        int.parse(raw.substring(10, 12)),
        int.parse(raw.substring(12, 14)),
      );
    }
    return null;
  }
}
