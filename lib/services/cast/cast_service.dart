import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/playback_speeds.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/services/cast/airplay/airplay_client.dart';
import 'package:javp/services/cast/airplay/airplay_discovery.dart';
import 'package:javp/services/cast/cast_hls_proxy.dart';
import 'package:javp/services/cast/cast_ladder.dart';
import 'package:javp/services/cast/cast_mime.dart';
import 'package:javp/services/cast/cast_protocol.dart';
import 'package:javp/services/cast/dlna/dlna_avtransport.dart';
import 'package:javp/services/cast/dlna/dlna_discovery.dart';
import 'package:javp/services/cast/lan_multicast.dart';

export 'package:javp/services/cast/cast_mime.dart'
    show isHttpCastableUrl, isLanCastableUrl;
export 'package:javp/services/cast/cast_protocol.dart';

/// Unified sender: Google Cast, DLNA, and AirPlay share one session.
class CastService extends ChangeNotifier {
  CastService({
    DlnaDiscovery? dlnaDiscovery,
    DlnaAvTransport? dlnaTransport,
    AirPlayDiscovery? airPlayDiscovery,
    AirPlayClient? airPlayClient,
  }) : _dlnaDiscovery = dlnaDiscovery ?? DlnaDiscovery(),
       _dlna = dlnaTransport ?? DlnaAvTransport(),
       _airPlayDiscovery = airPlayDiscovery ?? AirPlayDiscovery(),
       _airPlay = airPlayClient ?? AirPlayClient() {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static const _channel = MethodChannel('javp/chromecast');

  final DlnaDiscovery _dlnaDiscovery;
  final DlnaAvTransport _dlna;
  final AirPlayDiscovery _airPlayDiscovery;
  final AirPlayClient _airPlay;
  final CastHlsProxy _hlsProxy = CastHlsProxy();

  bool _casting = false;
  CastProtocol? _activeProtocol;
  CastTarget? _activeTarget;
  String? _deviceName;
  String? _lastError;
  bool _discovering = false;
  int _discoverDepth = 0;
  bool _disposed = false;
  List<CastTarget> _castDevices = const [];
  bool _remotePlaying = false;
  bool _remoteBuffering = false;
  Duration _remotePosition = Duration.zero;
  Duration _remoteDuration = Duration.zero;
  int _remoteVideoWidth = 0;
  int _remoteVideoHeight = 0;
  double _remoteVolume = 1;
  bool _remoteMuted = false;
  double _remotePlaybackRate = 1;
  bool _directPlayRisk = false;
  CastFailureKind? _lastFailureKind;
  List<CastLoadMode> _lastAttemptedModes = const [];
  DateTime? _ignoreRemotePlayingUntil;
  CastTarget? _preferredTarget;

  bool get isCasting => _casting;
  CastProtocol? get activeProtocol => _activeProtocol;
  CastTarget? get activeTarget => _activeTarget;
  String? get deviceName => _deviceName;
  String? get lastError => _lastError;
  bool get discovering => _discovering;

  /// Pause icon while PLAYING or BUFFERING — CAF spends a long time in
  /// BUFFERING on HLS, and treating that as paused made every tap send play().
  bool get remotePlaying => _remotePlaying || _remoteBuffering;
  bool get remoteBuffering => _remoteBuffering;
  bool get directPlayRisk => _directPlayRisk;
  CastFailureKind? get lastFailureKind => _lastFailureKind;
  List<CastLoadMode> get lastAttemptedModes => _lastAttemptedModes;
  CastTarget? get preferredTarget => _preferredTarget;
  Duration get remotePosition => _remotePosition;
  Duration get remoteDuration => _remoteDuration;

  /// Chromecast receiver volume, 0–1. 0 when muted.
  double get remoteVolume => _remoteMuted ? 0 : _remoteVolume;
  bool get remoteMuted => _remoteMuted;
  double get remotePlaybackRate => _remotePlaybackRate;

  List<CastTarget> get devices {
    final out = <CastTarget>[
      ..._castDevices,
      for (final r in _dlnaDiscovery.renderers)
        CastTarget(protocol: CastProtocol.dlna, id: r.usn, name: r.name),
      for (final d in _airPlayDiscovery.devices)
        CastTarget(protocol: CastProtocol.airplay, id: d.id, name: d.name),
    ];
    out.sort((a, b) {
      final p = a.protocol.index.compareTo(b.protocol.index);
      if (p != 0) return p;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  static bool isCastableUrl(String url) => isHttpCastableUrl(url);

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onSessionStarted':
        if (_activeProtocol == CastProtocol.dlna ||
            _activeProtocol == CastProtocol.airplay) {
          // Exclusive session: native Cast won — drop LAN session.
          unawaited(_stopLanOnly());
        }
        _activeProtocol = CastProtocol.chromecast;
        _casting = true;
        _deviceName = call.arguments as String?;
        _activeTarget = CastTarget(
          protocol: CastProtocol.chromecast,
          id: _activeTarget?.protocol == CastProtocol.chromecast
              ? (_activeTarget?.id ?? '')
              : '',
          name: _deviceName ?? 'Chromecast',
        );
        if (!_disposed) notifyListeners();
        return true;
      case 'onSessionEnded':
        if (_activeProtocol == CastProtocol.chromecast) {
          _casting = false;
          _activeProtocol = null;
          _activeTarget = null;
          _deviceName = null;
          _remotePlaying = false;
          _remoteBuffering = false;
          _remotePlaybackRate = 1;
          if (!_disposed) notifyListeners();
        }
        return true;
      case 'onMediaStatus':
        final args = call.arguments;
        if (args is Map) {
          final playing = args['playing'] == true;
          final buffering = args['buffering'] == true;
          final ignorePlaying =
              _ignoreRemotePlayingUntil != null &&
              DateTime.now().isBefore(_ignoreRemotePlayingUntil!);
          if (ignorePlaying && (playing || buffering)) {
            // Keep the optimistic paused UI until CAF catches up.
          } else {
            _remotePlaying = playing;
            _remoteBuffering = buffering;
          }
          final pos = args['positionMs'];
          final dur = args['durationMs'];
          if (pos is num) {
            _remotePosition = Duration(milliseconds: pos.toInt());
          }
          if (dur is num && dur > 0) {
            _remoteDuration = Duration(milliseconds: dur.toInt());
          }
          final rate = args['playbackRate'];
          if (rate is num && rate > 0) {
            _remotePlaybackRate = rate.toDouble();
          }
          final vw = args['videoWidth'];
          final vh = args['videoHeight'];
          if (vw is num) _remoteVideoWidth = vw.toInt();
          if (vh is num) _remoteVideoHeight = vh.toInt();
          if (!_disposed) notifyListeners();
        }
        return true;
      case 'onCastDevices':
        _castDevices = _parseCastDevices(call.arguments);
        if (!_disposed) notifyListeners();
        return true;
      case 'onLoadFailed':
        _lastError = friendlyCastReceiverError(
          call.arguments as String? ?? 'Cast load failed',
        );
        // Session may still be up with a blank TV — keep casting state so Stop works.
        if (!_disposed) notifyListeners();
        return true;
      case 'onVolume':
        _applyVolume(call.arguments);
        return true;
      default:
        return false;
    }
  }

  static List<CastTarget> _parseCastDevices(Object? raw) {
    if (raw is! List) return const [];
    final out = <CastTarget>[];
    for (final row in raw) {
      if (row is! Map) continue;
      final id = row['id']?.toString() ?? '';
      final name = row['name']?.toString() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      out.add(
        CastTarget(protocol: CastProtocol.chromecast, id: id, name: name),
      );
    }
    return out;
  }

  Future<void> startDiscovery() async {
    if (_disposed) return;
    _discoverDepth++;
    if (_discovering) return;
    _discovering = true;
    notifyListeners();
    await LanMulticastLock.acquire();
    if (_disposed) return;
    if (AppCapabilities.chromecast) {
      try {
        // Native startDiscovery waits for CastContext and returns the first pass.
        final listed = await _channel.invokeMethod<List<dynamic>>(
          'startDiscovery',
        );
        if (listed != null) {
          _castDevices = _parseCastDevices(listed);
        }
      } catch (_) {}
    }
    if (AppCapabilities.lanCast) {
      await _dlnaDiscovery.start(
        onChanged: () {
          if (!_disposed) notifyListeners();
        },
      );
      await _airPlayDiscovery.start(
        onChanged: () {
          if (!_disposed) notifyListeners();
        },
      );
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> stopDiscovery() async {
    _discoverDepth = (_discoverDepth - 1).clamp(0, 1000);
    if (_discoverDepth > 0) return;
    _discovering = false;
    if (AppCapabilities.chromecast) {
      try {
        await _channel.invokeMethod<void>('stopDiscovery');
      } catch (_) {}
    }
    _dlnaDiscovery.stop();
    _airPlayDiscovery.stop();
    await LanMulticastLock.release();
    if (!_disposed) notifyListeners();
  }

  Future<bool> castMedia({
    required String url,
    required String title,
    String? subtitle,
    String? posterUrl,
    Duration position = Duration.zero,
    Duration? duration,
    bool live = false,
    String? fileName,
    String? transcodeUrl,
    String? codecHint,
    CastTarget? target,
  }) async {
    if (!isCastableUrl(url)) {
      _lastError = 'This stream cannot be cast (need an HTTP URL)';
      notifyListeners();
      return false;
    }
    final media = CastMediaRequest(
      url: url,
      title: title,
      subtitle: subtitle,
      posterUrl: posterUrl,
      position: position,
      duration: duration,
      live: live,
      fileName: fileName,
      transcodeUrl: transcodeUrl,
      codecHint: codecHint,
    );
    final picked =
        target ??
        (_activeTarget != null && _casting ? _activeTarget : null) ??
        _preferredTarget;
    if (picked == null) {
      return _loadChromecast(media, routeId: null);
    }
    return _loadOnto(picked, media);
  }

  Future<bool> _loadOnto(CastTarget target, CastMediaRequest media) async {
    if (_casting &&
        _activeProtocol != null &&
        _activeProtocol != target.protocol) {
      await stop();
    }
    switch (target.protocol) {
      case CastProtocol.chromecast:
        return _loadChromecast(media, routeId: target.id);
      case CastProtocol.dlna:
        return _loadDlna(target, media);
      case CastProtocol.airplay:
        return _loadAirPlay(target, media);
    }
  }

  Future<bool> _loadChromecast(
    CastMediaRequest media, {
    String? routeId,
  }) async {
    if (!AppCapabilities.chromecast) {
      _lastError = 'Google Cast is only available on Android.';
      notifyListeners();
      return false;
    }
    try {
      _lastFailureKind = null;
      _lastAttemptedModes = const [];
      final probeType = await _contentTypeFor(media);
      final codecRisk = classifyCastCodecRisk(
        '${media.fileName ?? ''} ${media.codecHint ?? ''}',
        media.url,
        probeType,
      );
      _directPlayRisk = codecRisk != CastCodecRisk.none;
      _remoteVideoWidth = 0;
      _remoteVideoHeight = 0;

      final modes = castLoadLadder(
        url: media.url,
        transcodeUrl: media.transcodeUrl,
      );
      final tried = <CastLoadMode>[];
      String? lastRaw;

      for (final mode in modes) {
        _lastError = null;
        final attempt = _mediaForLoadMode(media, mode);
        final url = mode == CastLoadMode.direct
            ? attempt.url
            : await _publishLanUrl(
                attempt.url,
                fileName: attempt.fileName,
                live: attempt.live,
                force: true,
              );
        if (url == null) {
          lastRaw = looksLikeLoopbackUrl(attempt.url)
              ? 'Phone has no Wi‑Fi address to share this stream with Chromecast.'
              : 'Could not prepare this stream for Cast.';
          continue;
        }
        final contentType = await _contentTypeFor(attempt);
        final isHls = contentType.toLowerCase().contains('mpegurl');
        final isMpegTs =
            contentType.toLowerCase().contains('mp2t') ||
            looksLikeMpegTsUrl(attempt.url);
        final hlsSeg = isHls ? (_hlsProxy.lastHlsSegmentFormat ?? 'ts') : null;
        final ok = await _channel.invokeMethod<bool>('loadMedia', {
          'url': url,
          'contentType': contentType,
          'title': attempt.title,
          'subtitle': attempt.subtitle,
          'posterUrl': attempt.posterUrl,
          'positionMs': attempt.position.inMilliseconds,
          'live': attempt.live,
          'deferSeek':
              looksLikeLoopbackUrl(attempt.url) || isHls || isMpegTs,
          ?'hlsSegmentFormat': hlsSeg,
          if (routeId != null && routeId.isNotEmpty) 'routeId': routeId,
        });
        if (ok != true) {
          _lastError = 'Could not connect to a Google Cast device.';
          _lastFailureKind = CastFailureKind.connect;
          notifyListeners();
          return false;
        }
        tried.add(mode);
        _lastAttemptedModes = List.unmodifiable(tried);
        _setChromecastSession(routeId);
        notifyListeners();

        final started = await _receiverStartedPlaying(
          timeout: Duration(
            seconds: media.live
                ? 16
                : mode == CastLoadMode.direct
                ? 6
                : 10,
          ),
        );
        if (started) {
          _lastError = null;
          _lastFailureKind = null;
          notifyListeners();
          return true;
        }
        lastRaw = _lastError ?? 'idle';
      }

      _lastAttemptedModes = List.unmodifiable(tried);
      _lastFailureKind = classifyCastFailure(
        codecRisk: codecRisk,
        tried: tried,
        rawError: lastRaw,
      );
      _lastError = kCastUnsupportedOnDevice;
      await _idleChromecastSession();
      notifyListeners();
      return false;
    } on MissingPluginException {
      _lastError =
          'Chromecast requires the Android Cast SDK bridge (channel javp/chromecast).';
      _lastFailureKind = CastFailureKind.connect;
      notifyListeners();
      return false;
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  CastMediaRequest _mediaForLoadMode(CastMediaRequest media, CastLoadMode mode) {
    if (mode != CastLoadMode.serverTranscode) return media;
    return CastMediaRequest(
      url: media.transcodeUrl!,
      title: media.title,
      subtitle: media.subtitle,
      posterUrl: media.posterUrl,
      position: media.position,
      duration: media.duration,
      live: media.live,
    );
  }

  void _setChromecastSession(String? routeId) {
    _casting = true;
    _activeProtocol = CastProtocol.chromecast;
    _lastError = null;
    if (routeId != null && routeId.isNotEmpty) {
      final known = _castDevices.where((d) => d.id == routeId);
      _activeTarget = known.isEmpty
          ? CastTarget(
              protocol: CastProtocol.chromecast,
              id: routeId,
              name: _deviceName ?? 'Chromecast',
            )
          : known.first;
      _deviceName = _activeTarget?.name;
    }
    _preferredTarget = _activeTarget ?? _preferredTarget;
  }

  /// Drop an idle Cast splash without clearing the preferred device or error.
  Future<void> _idleChromecastSession() async {
    await _stopChromecastQuietly();
    _casting = false;
    _activeProtocol = null;
    _activeTarget = null;
    _deviceName = null;
    _remotePlaying = false;
    _remoteBuffering = false;
    _ignoreRemotePlayingUntil = null;
  }

  Future<bool> _receiverStartedPlaying({
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_lastError != null) return false;
      if (_remotePlaying || _remoteBuffering) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return _remotePlaying || _remoteBuffering;
  }

  Future<bool> _loadDlna(CastTarget target, CastMediaRequest media) async {
    final renderer = _dlnaDiscovery.renderers
        .where((r) => r.usn == target.id)
        .firstOrNull;
    if (renderer == null) {
      _lastError = 'That DLNA device is no longer on the network.';
      notifyListeners();
      return false;
    }
    try {
      await _stopChromecastQuietly();
      await _airPlayStopQuietly();
      final published = await _mediaForLan(media);
      await _dlna.load(renderer, published);
      _setActive(target);
      return true;
    } catch (e) {
      _lastError = 'DLNA failed: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> _loadAirPlay(CastTarget target, CastMediaRequest media) async {
    final device = _airPlayDiscovery.devices
        .where((d) => d.id == target.id)
        .firstOrNull;
    if (device == null) {
      _lastError = 'That AirPlay device is no longer on the network.';
      notifyListeners();
      return false;
    }
    try {
      await _stopChromecastQuietly();
      await _dlnaStopQuietly();
      final published = await _mediaForLan(media);
      await _airPlay.load(device, published);
      _setActive(target);
      return true;
    } catch (e) {
      _lastError = 'AirPlay failed: $e';
      notifyListeners();
      return false;
    }
  }

  /// Re-export loopback / HLS / public HTTP on Wi‑Fi. LAN progressive HTTP
  /// stays on the origin.
  Future<String?> _publishLanUrl(
    String url, {
    String? fileName,
    bool live = false,
    bool force = false,
  }) async {
    final proxied = await _hlsProxy.startFor(
      url,
      fileName: fileName,
      live: live,
      force: force,
    );
    if (looksLikeLoopbackUrl(url)) {
      if (proxied == null || proxied.isEmpty || looksLikeLoopbackUrl(proxied)) {
        return null;
      }
      return proxied;
    }
    if (proxied != null && proxied.isNotEmpty) return proxied;
    return url;
  }

  Future<String> _contentTypeFor(CastMediaRequest media) async {
    if (looksLikeMpegTsUrl(media.url) ||
        looksLikeMpegTsUrl(media.fileName ?? '')) {
      // Chromecast cannot LOAD raw MPEG-TS; the proxy wraps it as HLS.
      return 'application/x-mpegURL';
    }
    if (media.fileName != null && media.fileName!.contains('.')) {
      return guessCastContentType(media.fileName!);
    }
    if (looksLikeLoopbackUrl(media.url)) {
      final probed = await probeHttpContentType(media.url);
      if (probed != null && probed.isNotEmpty) return probed;
    }
    if (media.live) {
      final guessed = guessCastContentType(media.url);
      if (guessed.contains('mpegurl') || guessed.contains('mp2t')) {
        return guessed.contains('mp2t') ? 'application/x-mpegURL' : guessed;
      }
      final probed = await probeHttpContentType(media.url);
      if (probed != null && probed.isNotEmpty) {
        if (probed.toLowerCase().contains('mp2t')) {
          return 'application/x-mpegURL';
        }
        return probed;
      }
      // Xtream live paths without a suffix are almost always HLS.
      return 'application/x-mpegURL';
    }
    return guessCastContentType(media.url);
  }

  Future<CastMediaRequest> _mediaForLan(CastMediaRequest media) async {
    final url = await _publishLanUrl(
      media.url,
      fileName: media.fileName,
      live: media.live,
    );
    if (url == null) {
      throw StateError('Phone has no Wi‑Fi address to share this stream.');
    }
    if (url == media.url) return media;
    return CastMediaRequest(
      url: url,
      title: media.title,
      subtitle: media.subtitle,
      posterUrl: media.posterUrl,
      position: media.position,
      duration: media.duration,
      live: media.live,
      fileName: media.fileName,
    );
  }

  /// LOAD can succeed then idle. Codec guesses are explained via
  /// [lastFailureKind] — playing audio with a black picture is still "started".
  Future<String?> waitForPlaybackOrError({
    Duration? timeout,
    bool live = false,
  }) async {
    if (_lastFailureKind != null && !_casting) {
      if (_lastFailureKind == CastFailureKind.connect) {
        return _lastError ?? 'Could not connect to a Google Cast device.';
      }
      return kCastUnsupportedOnDevice;
    }
    final deadline = DateTime.now().add(
      timeout ?? Duration(seconds: live ? 20 : 12),
    );
    while (DateTime.now().isBefore(deadline)) {
      if (_lastError != null) {
        return friendlyCastReceiverError(_lastError!);
      }
      if (_remotePlaying || _remoteBuffering) return null;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_lastError != null) {
      return friendlyCastReceiverError(_lastError!);
    }
    if (_remotePlaying || _remoteBuffering) return null;
    if (live && _casting) return null;
    return kCastUnsupportedOnDevice;
  }

  void setPreferredTarget(CastTarget target) {
    _preferredTarget = target;
    if (!_disposed) notifyListeners();
  }

  void _setActive(CastTarget target) {
    _casting = true;
    _activeProtocol = target.protocol;
    _activeTarget = target;
    _preferredTarget = target;
    _deviceName = target.name;
    _lastError = null;
    notifyListeners();
  }

  Future<void> play() async {
    if (!_casting) return;
    _ignoreRemotePlayingUntil = null;
    _remotePlaying = true;
    _remoteBuffering = false;
    if (!_disposed) notifyListeners();
    if (!AppCapabilities.chromecast) return;
    try {
      await _channel.invokeMethod<void>('play');
    } catch (_) {}
  }

  Future<void> pause() async {
    if (!_casting) return;
    _ignoreRemotePlayingUntil = DateTime.now().add(
      const Duration(milliseconds: 800),
    );
    _remotePlaying = false;
    _remoteBuffering = false;
    if (!_disposed) notifyListeners();
    if (!AppCapabilities.chromecast) return;
    try {
      await _channel.invokeMethod<void>('pause');
    } catch (_) {}
  }

  Future<void> playOrPause() async {
    if (_remotePlaying || _remoteBuffering) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration position) async {
    if (!AppCapabilities.chromecast || !_casting) return;
    _remotePosition = position;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('seek', {
        'positionMs': position.inMilliseconds,
      });
    } catch (_) {}
  }

  Future<void> refreshVolume() async {
    if (!AppCapabilities.chromecast || !_casting) return;
    try {
      final raw = await _channel.invokeMethod<dynamic>('getVolume');
      _applyVolume(raw);
    } catch (_) {}
  }

  Future<void> setRemoteVolume(double level) async {
    if (!AppCapabilities.chromecast || !_casting) return;
    final next = level.clamp(0.0, 1.0);
    _remoteVolume = next;
    _remoteMuted = next <= 0;
    if (!_disposed) notifyListeners();
    try {
      await _channel.invokeMethod<void>('setVolume', {'level': next});
    } catch (_) {}
  }

  Future<void> setPlaybackRate(double rate) async {
    if (!AppCapabilities.chromecast || !_casting) return;
    final next = rate.clamp(kCastPlaybackRateMin, kCastPlaybackRateMax);
    _remotePlaybackRate = next;
    if (!_disposed) notifyListeners();
    try {
      await _channel.invokeMethod<void>('setPlaybackRate', {'rate': next});
    } catch (_) {}
  }

  void _applyVolume(Object? raw) {
    if (raw is! Map) return;
    final level = raw['level'];
    if (level is num) _remoteVolume = level.toDouble().clamp(0.0, 1.0);
    _remoteMuted = raw['mute'] == true;
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() async {
    await _stopChromecastQuietly();
    await _dlnaStopQuietly();
    await _airPlayStopQuietly();
    await _hlsProxy.stop();
    _casting = false;
    _activeProtocol = null;
    _activeTarget = null;
    _deviceName = null;
    _remotePlaying = false;
    _remoteBuffering = false;
    _ignoreRemotePlayingUntil = null;
    _preferredTarget = null;
    notifyListeners();
  }

  Future<void> _stopLanOnly() async {
    await _dlnaStopQuietly();
    await _airPlayStopQuietly();
  }

  Future<void> _stopChromecastQuietly() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<void> _dlnaStopQuietly() async {
    final id = _activeProtocol == CastProtocol.dlna ? _activeTarget?.id : null;
    if (id == null) return;
    final renderer = _dlnaDiscovery.renderers
        .where((r) => r.usn == id)
        .firstOrNull;
    if (renderer == null) return;
    try {
      await _dlna.stop(renderer);
    } catch (_) {}
  }

  Future<void> _airPlayStopQuietly() async {
    final id = _activeProtocol == CastProtocol.airplay
        ? _activeTarget?.id
        : null;
    if (id == null) return;
    final device = _airPlayDiscovery.devices
        .where((d) => d.id == id)
        .firstOrNull;
    if (device == null) return;
    try {
      await _airPlay.stop(device);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _discoverDepth = 0;
    _dlnaDiscovery.stop();
    _airPlayDiscovery.stop();
    unawaited(LanMulticastLock.release());
    if (AppCapabilities.chromecast) {
      try {
        _channel.invokeMethod<void>('stopDiscovery');
      } catch (_) {}
    }
    _channel.setMethodCallHandler(null);
    unawaited(_hlsProxy.stop());
    super.dispose();
  }
}
