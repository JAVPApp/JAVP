import 'dart:math';

/// IAB VAST 4.2 §1.3 / Appendix C macros. Values in URLs are percent-encoded.
class VastMacros {
  VastMacros._();

  static const playerCapabilities =
      'skip,mute,autoplay,mautoplay,fullscreen,icon';
  static const vastVersions = '2,3,4,4.1,4.2';
  static const appBundle = 'com.javp.javp';
  static const clickType = '2'; // in-app browser / in-app web view
  static const apiFrameworks = ''; // no VPAID / SIMID / OMID
  static const omidPartner = '';

  static String cacheBuster() {
    final n = Random().nextInt(90000000) + 10000000;
    return n.toString().padLeft(8, '0');
  }

  static String timestamp() => DateTime.now().toUtc().toIso8601String();

  static String playhead(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  static String playerState({
    required bool muted,
    required bool fullscreen,
    required bool playing,
  }) {
    return [
      muted ? 'muted' : 'unmuted',
      fullscreen ? 'fullscreen' : 'normal',
      playing ? 'playing' : 'paused',
    ].join(',');
  }

  static String expand(String url, VastMacroContext ctx) {
    var out = url;
    void put(String name, String value) {
      final encoded = Uri.encodeComponent(value);
      out = out.replaceAllMapped(
        RegExp('\\[$name\\]', caseSensitive: false),
        (_) => encoded,
      );
    }

    put('CACHEBUSTING', ctx.cacheBuster);
    put('CACHEBUSTER', ctx.cacheBuster);
    put('RANDOM', ctx.cacheBuster);
    put('TIMESTAMP', ctx.timestamp);
    put('ERRORCODE', ctx.errorCode);
    put('REASON', ctx.reason);
    put('ADPLAYHEAD', playhead(ctx.adPlayhead));
    put('CONTENTPLAYHEAD', playhead(ctx.contentPlayhead));
    put('MEDIAPLAYHEAD', playhead(ctx.mediaPlayhead));
    put('ASSETURI', ctx.assetUri);
    put('CONTENTURI', ctx.contentUri);
    put('CONTENTID', ctx.contentId);
    put('PODSEQUENCE', ctx.podSequence.toString());
    put('ADTYPE', ctx.adType);
    put('UNIVERSALADID', ctx.universalAdId);
    put('IFA', ctx.ifa);
    put('IFATYPE', ctx.ifaType);
    put('LATLONG', ctx.latLong);
    put('DOMAIN', ctx.domain);
    put('PAGEURL', ctx.pageUrl);
    put('APPBUNDLE', ctx.appBundle);
    put('VASTVERSIONS', ctx.vastVersions);
    put('APIFRAMEWORKS', ctx.apiFrameworks);
    put('OMIDPARTNER', ctx.omidPartner);
    put('MEDIAMIME', ctx.mediaMime);
    put('PLAYERSIZE', ctx.playerSize);
    put('PLAYERSTATE', ctx.playerState);
    put('INVENTORYSTATE', ctx.inventoryState);
    put('PLAYERCAPABILITIES', ctx.playerCapabilities);
    put('CLICKTYPE', ctx.clickType);
    put('CLICKPOS', ctx.clickPos);
    put('CLIENTUA', ctx.clientUa);
    put('DEVICEUA', ctx.deviceUa);
    put('SERVERUA', ctx.serverUa);
    put('DEVICEIP', ctx.deviceIp);
    put('SERVERIP', ctx.serverIp);
    put('LIMITADTRACKING', ctx.limitAdTracking);
    put('REGULATIONS', ctx.regulations);
    out = out.replaceAllMapped(
      RegExp('%%CACHEBUSTER%%', caseSensitive: false),
      (_) => Uri.encodeComponent(ctx.cacheBuster),
    );
    return out;
  }
}

class VastMacroContext {
  const VastMacroContext({
    required this.cacheBuster,
    required this.timestamp,
    this.errorCode = '900',
    this.reason = '2',
    this.adPlayhead = Duration.zero,
    this.contentPlayhead = Duration.zero,
    this.mediaPlayhead = Duration.zero,
    this.assetUri = '',
    this.contentUri = '',
    this.contentId = '',
    this.podSequence = 1,
    this.adType = 'video',
    this.universalAdId = '',
    this.ifa = '',
    this.ifaType = '',
    this.latLong = '',
    this.domain = '',
    this.pageUrl = '0',
    this.appBundle = VastMacros.appBundle,
    this.vastVersions = VastMacros.vastVersions,
    this.apiFrameworks = VastMacros.apiFrameworks,
    this.omidPartner = VastMacros.omidPartner,
    this.mediaMime = 'video/mp4',
    this.playerSize = '1920x1080',
    this.playerState = 'unmuted,fullscreen,playing',
    this.inventoryState = '',
    this.playerCapabilities = VastMacros.playerCapabilities,
    this.clickType = VastMacros.clickType,
    this.clickPos = '',
    this.clientUa = '',
    this.deviceUa = '',
    this.serverUa = '',
    this.deviceIp = '',
    this.serverIp = '',
    this.limitAdTracking = '0',
    this.regulations = '',
  });

  final String cacheBuster;
  final String timestamp;
  final String errorCode;
  final String reason;
  final Duration adPlayhead;
  final Duration contentPlayhead;
  final Duration mediaPlayhead;
  final String assetUri;
  final String contentUri;
  final String contentId;
  final int podSequence;
  final String adType;
  final String universalAdId;
  final String ifa;
  final String ifaType;
  final String latLong;
  final String domain;
  final String pageUrl;
  final String appBundle;
  final String vastVersions;
  final String apiFrameworks;
  final String omidPartner;
  final String mediaMime;
  final String playerSize;
  final String playerState;
  final String inventoryState;
  final String playerCapabilities;
  final String clickType;
  final String clickPos;
  final String clientUa;
  final String deviceUa;
  final String serverUa;
  final String deviceIp;
  final String serverIp;
  final String limitAdTracking;
  final String regulations;

  VastMacroContext copyWith({
    String? errorCode,
    String? reason,
    Duration? adPlayhead,
    Duration? contentPlayhead,
    Duration? mediaPlayhead,
    String? assetUri,
    String? contentUri,
    String? contentId,
    int? podSequence,
    String? adType,
    String? universalAdId,
    String? mediaMime,
    String? playerSize,
    String? playerState,
    String? clickPos,
  }) {
    return VastMacroContext(
      cacheBuster: cacheBuster,
      timestamp: timestamp,
      errorCode: errorCode ?? this.errorCode,
      reason: reason ?? this.reason,
      adPlayhead: adPlayhead ?? this.adPlayhead,
      contentPlayhead: contentPlayhead ?? this.contentPlayhead,
      mediaPlayhead: mediaPlayhead ?? this.mediaPlayhead,
      assetUri: assetUri ?? this.assetUri,
      contentUri: contentUri ?? this.contentUri,
      contentId: contentId ?? this.contentId,
      podSequence: podSequence ?? this.podSequence,
      adType: adType ?? this.adType,
      universalAdId: universalAdId ?? this.universalAdId,
      ifa: ifa,
      ifaType: ifaType,
      latLong: latLong,
      domain: domain,
      pageUrl: pageUrl,
      appBundle: appBundle,
      vastVersions: vastVersions,
      apiFrameworks: apiFrameworks,
      omidPartner: omidPartner,
      mediaMime: mediaMime ?? this.mediaMime,
      playerSize: playerSize ?? this.playerSize,
      playerState: playerState ?? this.playerState,
      inventoryState: inventoryState,
      playerCapabilities: playerCapabilities,
      clickType: clickType,
      clickPos: clickPos ?? this.clickPos,
      clientUa: clientUa,
      deviceUa: deviceUa,
      serverUa: serverUa,
      deviceIp: deviceIp,
      serverIp: serverIp,
      limitAdTracking: limitAdTracking,
      regulations: regulations,
    );
  }

  static VastMacroContext now({
    String userAgent = '',
    Duration contentPlayhead = Duration.zero,
    String contentUri = '',
    String contentId = '',
    String playerSize = '1920x1080',
    String playerState = 'unmuted,fullscreen,playing',
  }) {
    return VastMacroContext(
      cacheBuster: VastMacros.cacheBuster(),
      timestamp: VastMacros.timestamp(),
      contentPlayhead: contentPlayhead,
      mediaPlayhead: contentPlayhead,
      contentUri: contentUri,
      contentId: contentId,
      playerSize: playerSize,
      playerState: playerState,
      clientUa: userAgent,
      deviceUa: userAgent,
    );
  }
}
