import 'package:javp/models/iptv_source.dart';

/// How the Sources editor represents EPG for a live list.
enum LiveEpgInput {
  /// Guide / now-playing skip EPG for this list.
  off,

  /// Playlist `url-tvg`, Xtream XMLTV, or the media-server programme guide.
  provider,

  /// Inline XMLTV URL or local file on this source.
  urlOrFile,

  /// Attached standalone [IptvSourceType.xmltv] source.
  attached,
}

/// Label for the "this list's own listings" dropdown row.
enum LiveEpgProviderKind {
  /// M3U `url-tvg` / playlist header.
  playlist,

  /// Xtream / Stalker provider XMLTV.
  iptvProvider,

  /// Plex / Jellyfin / Emby DVR programme guide.
  mediaServer,
}

LiveEpgProviderKind liveEpgProviderKindFor(IptvSourceType type) {
  if (type.isMediaServer) return LiveEpgProviderKind.mediaServer;
  if (type == IptvSourceType.m3u) return LiveEpgProviderKind.playlist;
  return LiveEpgProviderKind.iptvProvider;
}

/// Maps persisted source fields onto the unified EPG picker.
///
/// [LiveEpgInput.off] is only the Guide-disabled picker row. A stored
/// [epgUrl] / [epgSourceId] still belongs on the source — [liveEpgSaveFields]
/// must keep those values so a later edit does not wipe them.
LiveEpgInput liveEpgInputFromFields({
  required bool epgEnabled,
  String? epgSourceId,
  String? epgUrl,
}) {
  if (!epgEnabled) return LiveEpgInput.off;
  final attached = epgSourceId?.trim();
  if (attached != null && attached.isNotEmpty) return LiveEpgInput.attached;
  final url = epgUrl?.trim();
  if (url != null && url.isNotEmpty) return LiveEpgInput.urlOrFile;
  return LiveEpgInput.provider;
}

/// Values written back to [IptvSource] from [LiveEpgInput].
///
/// Empty [epgSourceId] / [epgUrl] mean "clear" for source-update APIs that
/// treat `''` as unset. [LiveEpgInput.off] is the exception: it writes
/// `epgEnabled: false` and keeps the URL / attachment passed in.
class LiveEpgSaveFields {
  const LiveEpgSaveFields({
    required this.epgEnabled,
    required this.epgSourceId,
    required this.epgUrl,
  });

  final bool epgEnabled;
  final String epgSourceId;
  final String epgUrl;

  /// Inline URL for add APIs (`null` when empty).
  String? get epgUrlOrNull {
    final trimmed = epgUrl.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Attached XMLTV id for add APIs (`null` when empty).
  String? get epgSourceIdOrNull {
    final trimmed = epgSourceId.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

LiveEpgSaveFields liveEpgSaveFields({
  required LiveEpgInput input,
  String? attachedSourceId,
  String? urlOrFile,
}) {
  switch (input) {
    case LiveEpgInput.off:
      // None disables Guide only. Keep URL / attachment so re-enabling or a
      // later edit of an already-off source does not drop them.
      return LiveEpgSaveFields(
        epgEnabled: false,
        epgSourceId: attachedSourceId ?? '',
        epgUrl: urlOrFile ?? '',
      );
    case LiveEpgInput.provider:
      return const LiveEpgSaveFields(
        epgEnabled: true,
        epgSourceId: '',
        epgUrl: '',
      );
    case LiveEpgInput.urlOrFile:
      return LiveEpgSaveFields(
        epgEnabled: true,
        epgSourceId: '',
        epgUrl: urlOrFile ?? '',
      );
    case LiveEpgInput.attached:
      return LiveEpgSaveFields(
        epgEnabled: true,
        epgSourceId: attachedSourceId ?? '',
        epgUrl: '',
      );
  }
}

/// XMLTV URL stored on [source] or via [attachedXmltvUrl].
///
/// Does not include playlist `url-tvg` or media-server provider APIs — those
/// apply when this returns null.
String? xmltvUrlForLiveSource(IptvSource source, {String? attachedXmltvUrl}) {
  final attachedId = source.epgSourceId?.trim();
  if (attachedId != null && attachedId.isNotEmpty) {
    final url = attachedXmltvUrl?.trim();
    if (url != null && url.isNotEmpty) return url;
  }
  final inline = source.epgUrl?.trim();
  if (inline == null || inline.isEmpty) return null;
  return inline;
}
