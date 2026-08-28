import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/proxy_settings.dart';

/// Compact, credential-free snapshot of enabled IPTV / catalog sources and the
/// feature flags that affect sync and recommendations.
///
/// Safe for [JavpLog]: never includes passwords, tokens, usernames, hosts, or
/// playlist/API URLs (those may embed `user:pass@` or query secrets).
String buildSourcesFeatureSummary({
  required List<IptvSource> sources,
  required ProxySettings proxy,
  required bool simklLinked,
  required bool traktLinked,
  required bool serializdLinked,
  required bool betaseriesLinked,
  required bool letterboxdLinked,
  required bool tmdbConfigured,
  bool? parentalPin,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final kindCounts = <String, int>{};
  var on = 0;
  var off = 0;
  var epgOn = 0;
  var xtreamVodOff = 0;
  var channels = 0;
  var vod = 0;
  final syncAge = <String, int>{
    'never': 0,
    'lt1h': 0,
    'lt1d': 0,
    'lt7d': 0,
    'older': 0,
  };

  for (final s in sources) {
    final kind = s.type.name;
    kindCounts[kind] = (kindCounts[kind] ?? 0) + 1;
    if (s.enabled) {
      on++;
    } else {
      off++;
    }
    if (s.enabled &&
        (s.type == IptvSourceType.xmltv ||
            (s.type.canAttachEpg && s.epgEnabled))) {
      epgOn++;
    }
    if (s.type == IptvSourceType.xtream && !s.vodEnabled) {
      xtreamVodOff++;
    }
    if (s.enabled) {
      channels += s.channelCount;
      vod += s.vodCount;
    }
    final bucket = _syncAgeBucket(s.lastSyncedAt, clock);
    syncAge[bucket] = (syncAge[bucket] ?? 0) + 1;
  }

  final kinds = kindCounts.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final kindsPart = kinds.isEmpty
      ? '-'
      : kinds.map((e) => '${e.key}:${e.value}').join(',');

  final agePart = syncAge.entries
      .where((e) => e.value > 0)
      .map((e) => '${e.key}:${e.value}')
      .join(',');

  final trackers = <String>[
    if (simklLinked) 'simkl',
    if (traktLinked) 'trakt',
    if (serializdLinked) 'serializd',
    if (betaseriesLinked) 'betaseries',
    if (letterboxdLinked) 'letterboxd',
    if (tmdbConfigured) 'tmdb',
  ];

  final pin = parentalPin == null
      ? 'unknown'
      : (parentalPin ? 'true' : 'false');

  return 'n=${sources.length} on=$on off=$off '
      'kinds=$kindsPart epgOn=$epgOn xtreamVodOff=$xtreamVodOff '
      'channels=$channels vod=$vod '
      'syncAge=${agePart.isEmpty ? '-' : agePart} '
      'proxy=${_proxySummary(proxy)} '
      'trackers=${trackers.isEmpty ? '-' : trackers.join(',')} '
      'parentalPin=$pin';
}

String _syncAgeBucket(DateTime? lastSyncedAt, DateTime now) {
  if (lastSyncedAt == null) return 'never';
  final age = now.difference(lastSyncedAt);
  if (age < const Duration(hours: 1)) return 'lt1h';
  if (age < const Duration(days: 1)) return 'lt1d';
  if (age < const Duration(days: 7)) return 'lt7d';
  return 'older';
}

/// Type + active traffic scopes only — never host / user / password.
String _proxySummary(ProxySettings proxy) {
  if (!proxy.isActive) return 'off';
  final scopes = <String>[
    if (proxy.routeIptv) 'iptv',
    if (proxy.routeCatalogs) 'catalogs',
    if (proxy.routeMetadata) 'metadata',
    if (proxy.routeMediaServers) 'mediaServers',
    if (proxy.routeTorrents) 'torrents',
    if (proxy.routeDownloads) 'downloads',
  ];
  final scopePart = scopes.isEmpty ? 'none' : scopes.join('+');
  final fallbackPart = proxy.allowDirectFallback ? '+fallback' : '';
  return '${proxy.type.name}:$scopePart$fallbackPart';
}
