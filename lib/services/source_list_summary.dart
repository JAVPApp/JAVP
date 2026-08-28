import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/iptv_source.dart';

/// Localized type name for a source row (no connection URL).
String sourceTypeLabel(AppLocalizations l10n, IptvSourceType type) {
  return switch (type) {
    IptvSourceType.m3u => l10n.m3uPlaylist,
    IptvSourceType.xtream => l10n.xtreamCodes,
    IptvSourceType.stalker => l10n.stalkerPortal,
    IptvSourceType.custom => l10n.customJsonCatalog,
    IptvSourceType.jellyfin => 'Jellyfin',
    IptvSourceType.emby => 'Emby',
    IptvSourceType.plex => 'Plex',
    IptvSourceType.xmltv => l10n.xmltvEpg,
  };
}

/// Collapsed Sources-row subtitle: type + what’s in the source (never a URL).
String sourceListSubtitle(
  AppLocalizations l10n,
  IptvSource source, {
  bool busy = false,
  String? status,
}) {
  final type = sourceTypeLabel(l10n, source.type);
  if (!source.enabled) {
    return '$type · ${l10n.sourceDisabled}';
  }
  final phase = status?.trim();
  if (phase != null && phase.isNotEmpty) {
    return '$type · $phase';
  }
  if (busy) {
    return '$type · ${l10n.syncingInBackground}';
  }
  final content = sourceContentCounts(l10n, source);
  if (content == null || content.isEmpty) {
    return source.lastSyncedAt == null ? '$type · ${l10n.notSyncedYet}' : type;
  }
  return '$type · $content';
}

/// Live / VOD / catalog counts for a source, or null when nothing is cached.
String? sourceContentCounts(AppLocalizations l10n, IptvSource source) {
  switch (source.type) {
    case IptvSourceType.xmltv:
      return null;
    case IptvSourceType.custom:
      if (source.vodCount > 0) return l10n.vodItemCount(source.vodCount);
      final remote = source.catalogItemCount;
      if (remote != null && remote > 0) return l10n.vodItemCount(remote);
      return null;
    default:
      final live = source.channelCount;
      final vod = source.vodCount;
      final parts = <String>[];
      if (source.type == IptvSourceType.xtream && !source.vodEnabled) {
        if (live > 0) {
          parts.add(live == 1 ? l10n.oneChannel : l10n.channelCount(live));
        }
        parts.add(l10n.vodOff);
      } else if (live > 0 && vod > 0) {
        parts.add(l10n.sourceLiveVodCount(live, vod));
      } else if (live > 0) {
        parts.add(live == 1 ? l10n.oneChannel : l10n.channelCount(live));
      } else if (vod > 0) {
        parts.add(l10n.vodItemCount(vod));
      }
      if (source.type.canAttachEpg && !source.epgEnabled) {
        parts.add(l10n.epgOff);
      }
      if (parts.isEmpty) return null;
      return parts.join(' · ');
  }
}
