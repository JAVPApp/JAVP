import 'package:javp/models/media_item.dart';

/// Safe Discord Rich Presence artwork — never leaks media-server tokens.
///
/// Discord relays `large_image` / `small_image` to anyone viewing the profile.
/// Jellyfin/Emby posters embed `api_key` and Plex embeds `X-Plex-Token`, so
/// those catalog URLs must never be sent. Prefer:
/// 1. Already-public CDN URLs on the item (TMDB / Simkl / TVDB / …)
/// 2. The portal asset key `javp`
///
/// No server-side TMDB lookup: a tmdbId alone is not enough for a poster.
abstract final class DiscordPresenceArtwork {
  /// Portal / small-logo asset key (Discord Developer Portal → Art Assets).
  static const portalAssetKey = 'javp';

  /// Hosts whose HTTPS image URLs are safe to hand to Discord as-is.
  static const publicImageHosts = <String>{
    'image.tmdb.org',
    'www.themoviedb.org',
    'media.themoviedb.org',
    'simkl.in',
    'cdn.simkl.com',
    // SimklClient wraps posters/fanart through wsrv.nl for WebP/size.
    'wsrv.nl',
    'artworks.thetvdb.com',
    'thetvdb.com',
    'www.thetvdb.com',
  };

  /// Query keys that almost always mean a media-server (or other) secret.
  static const _secretQueryKeys = <String>{
    'api_key',
    'apikey',
    'apiKey',
    'X-Plex-Token',
    'x-plex-token',
    'access_token',
    'accessToken',
    'token',
    'auth',
    'Authorization',
  };

  /// Resolve artwork for a presence card.
  ///
  /// [hideTitle] also hides the poster (OP preference: “masquer le titre”).
  static DiscordPresenceArt resolve({
    required bool hasSession,
    MediaItem? item,
    bool hideTitle = false,
  }) {
    if (!hasSession || item == null || hideTitle) {
      return DiscordPresenceArt.portalOnly;
    }

    final direct = _firstSafeUrl([
      item.posterUrl,
      item.thumbnailUrl,
      item.backdropUrl,
    ]);
    if (direct != null) {
      return DiscordPresenceArt.poster(direct);
    }

    return DiscordPresenceArt.portalOnly;
  }

  /// True when [url] is HTTPS, on an allowlisted host, with no secret query.
  static bool isSafePublicImageUrl(String? url) {
    if (url == null) return false;
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return false;
    if (uri.scheme.toLowerCase() != 'https') return false;

    final host = uri.host.toLowerCase();
    if (host.isEmpty || !_isPublicHost(host)) return false;
    if (_looksLikeLanOrLocal(host)) return false;
    if (_hasSecretQuery(uri)) return false;
    return true;
  }

  static String? _firstSafeUrl(List<String?> candidates) {
    for (final c in candidates) {
      if (isSafePublicImageUrl(c)) return c!.trim();
    }
    return null;
  }

  static bool _isPublicHost(String host) {
    if (publicImageHosts.contains(host)) return true;
    // Allow one-level subdomains of known CDNs (e.g. images.simkl.in).
    for (final allowed in publicImageHosts) {
      if (host.endsWith('.$allowed')) return true;
    }
    return false;
  }

  static bool _looksLikeLanOrLocal(String host) {
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final parts = host.split('.');
    if (parts.length == 4 && parts.every((p) => int.tryParse(p) != null)) {
      final a = int.parse(parts[0]);
      final b = int.parse(parts[1]);
      if (a == 10) return true;
      if (a == 127) return true;
      if (a == 192 && b == 168) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
    }
    return false;
  }

  static bool _hasSecretQuery(Uri uri) {
    for (final key in uri.queryParameters.keys) {
      if (_secretQueryKeys.contains(key)) return true;
      final lower = key.toLowerCase();
      if (lower.contains('token') ||
          lower.contains('api_key') ||
          lower.contains('apikey')) {
        return true;
      }
    }
    return false;
  }
}

/// Artwork payload for [DiscordPresenceSnapshot] / IPC mapping.
class DiscordPresenceArt {
  const DiscordPresenceArt._({this.largeImageUrl, required this.showSmallLogo});

  /// Portal logo only (browsing, privacy, or no safe art).
  static const portalOnly = DiscordPresenceArt._(
    largeImageUrl: null,
    showSmallLogo: false,
  );

  /// Lunar-style: big poster URL + small JAVP logo.
  factory DiscordPresenceArt.poster(String url) {
    return DiscordPresenceArt._(largeImageUrl: url, showSmallLogo: true);
  }

  /// Public HTTPS image URL for Discord `large_image`, or null → portal key.
  final String? largeImageUrl;

  /// When true, set `small_image` to the portal JAVP logo.
  final bool showSmallLogo;

  @override
  bool operator ==(Object other) {
    return other is DiscordPresenceArt &&
        other.largeImageUrl == largeImageUrl &&
        other.showSmallLogo == showSmallLogo;
  }

  @override
  int get hashCode => Object.hash(largeImageUrl, showSmallLogo);

  @override
  String toString() =>
      'DiscordPresenceArt(url=$largeImageUrl small=$showSmallLogo)';
}
