import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/media_item.dart';

/// Map persisted English origin/open-with copy to the current UI locale.
///
/// Local files, pasted URLs, and Open-with items store English subtitles so
/// matching stays stable; chrome always goes through l10n.
String? localizePersistedSubtitle(AppLocalizations l10n, String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return raw;
  switch (value) {
    case 'Local file':
      return l10n.originLocalFile;
    case 'Direct URL':
      return l10n.originDirectUrl;
    case 'Opened magnet':
      return l10n.originOpenedMagnet;
    case 'Opened torrent':
      return l10n.originOpenedTorrent;
    case 'Radio':
      return l10n.radio;
    default:
      return raw;
  }
}

/// True when [label] is the “N sources” shelf chip (any UI locale).
bool isMultiSourceCountLabel(AppLocalizations l10n, String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return false;
  final sample = l10n.nSources(0);
  final idx = sample.indexOf('0');
  if (idx < 0) {
    return RegExp(r'^\d+\s+sources$').hasMatch(trimmed);
  }
  final prefix = sample.substring(0, idx);
  final suffix = sample.substring(idx + 1);
  if (!trimmed.startsWith(prefix) || !trimmed.endsWith(suffix)) {
    return false;
  }
  final mid = trimmed.substring(prefix.length, trimmed.length - suffix.length);
  return RegExp(r'^\d+$').hasMatch(mid);
}

String genericOriginLabel(AppLocalizations l10n, MediaOrigin origin) {
  return switch (origin) {
    MediaOrigin.localFile => l10n.originLocalFile,
    MediaOrigin.url => l10n.url,
    MediaOrigin.iptvM3u => 'M3U',
    MediaOrigin.iptvXtream => 'Xtream',
    MediaOrigin.iptvStalker => 'Stalker',
    MediaOrigin.customCatalog => l10n.originCustomCatalog,
    MediaOrigin.torrent => l10n.originTorrent,
    MediaOrigin.jellyfin => 'Jellyfin',
    MediaOrigin.emby => 'Emby',
    MediaOrigin.plex => 'Plex',
    MediaOrigin.download => l10n.originDownload,
  };
}
