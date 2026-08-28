import 'dart:ui' show PlatformDispatcher;

import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/iptv_locale_hints.dart';

/// Shared title cleaning / year guessing / merge helpers for enrichers.
class MetadataMatch {
  MetadataMatch._();

  /// Extract a 4-digit year from subtitle / title when present.
  static int? guessYear(MediaItem item) {
    if (item.year != null) return item.year;
    final hay = '${item.subtitle ?? ''} ${item.title}';
    final match = RegExp(r'\b(19|20)\d{2}\b').firstMatch(hay);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  static String cleanTitle(String title) {
    var t = title.trim();
    // IPTV panels use uppercase LANG| / LANG: markers (FR|, US|). Require
    // ALL CAPS so real titles like "It: Chapter Two" are not stripped (it is
    // also the ISO code for Italian).
    t = t.replaceFirst(RegExp(r'^[A-Z]{2,3}\s*[|:：\-–—]\s*'), '');
    t = t.replaceAll(RegExp(r'\[.*?\]|\(.*?\)'), ' ');
    t = t.replaceAll(
      RegExp(
        r'\b(1080p|720p|2160p|4k|uhd|hdr|hevc|x264|x265|bluray|web-?dl|hdtv)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    t = t.replaceAll(RegExp(r'[._]+'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  static final _onaOvaToken = RegExp(r'\b(?:ona|ova)\b');

  static bool looksLikeAnime(MediaItem item) {
    if (item.anilistId != null) return true;
    final id = item.id.toLowerCase();
    // Catalog ids such as `anilist-147105` — do not fold [id] into the
    // ona/ova haystack (`national` / `seasonal` would false-positive).
    if (id.contains('anilist-') || id.contains('anilist:')) return true;
    final hay = [
      ...item.genres,
      ...item.tags,
      item.group ?? '',
      item.subtitle ?? '',
    ].join(' ').toLowerCase();
    return hay.contains('anime') || _onaOvaToken.hasMatch(hay);
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  /// BCP-47 tag for metadata APIs (`fr-FR`, `en`, …).
  static String languageTag() {
    final loc = IptvLocaleHints.normalize(PlatformDispatcher.instance.locale);
    final country = loc.countryCode;
    if (country != null && country.isNotEmpty) {
      return '${loc.languageCode}-$country';
    }
    return loc.languageCode;
  }

  /// ISO 639-1 language code (`fr`, `en`) for APIs that do not take a region.
  static String languageCode() => IptvLocaleHints.normalize(
    PlatformDispatcher.instance.locale,
  ).languageCode.toLowerCase();

  /// Cast that is empty or only crew credits (director / creator).
  static bool isThinCast(List<CastMember> cast) {
    if (cast.isEmpty) return true;
    const crew = {'director', 'creator'};
    return cast.every((c) {
      final role = (c.character ?? '').trim().toLowerCase();
      return crew.contains(role);
    });
  }

  /// Apply enricher artwork/ids onto a shelf row without changing playUrl.
  /// Provider non-null presentation fields win over the catalog row.
  static MediaItem mergeOntoItem(MediaItem item, MediaDetails details) {
    return item.copyWith(
      detailsId: details.id,
      tmdbId: details.tmdbId ?? item.tmdbId,
      simklId: _nonEmpty(details.simklId) ?? item.simklId,
      traktId: _nonEmpty(details.traktId) ?? item.traktId,
      imdbId: details.imdbId ?? item.imdbId,
      tvdbId: details.tvdbId ?? item.tvdbId,
      anilistId: details.anilistId ?? item.anilistId,
      plot: _nonEmpty(details.plot) ?? item.plot,
      posterUrl: _nonEmpty(details.posterUrl) ?? item.posterUrl,
      backdropUrl: _nonEmpty(details.backdropUrl) ?? item.backdropUrl,
      thumbnailUrl: _nonEmpty(details.posterUrl) ?? item.thumbnailUrl,
      genres: details.genres.isNotEmpty ? details.genres : item.genres,
      rating: details.rating ?? item.rating,
      year: details.year ?? item.year,
      originalTitle: _nonEmpty(details.originalTitle) ?? item.originalTitle,
      contentRating: _nonEmpty(details.contentRating) ?? item.contentRating,
      studio: _nonEmpty(details.studio) ?? item.studio,
      releaseDate: _nonEmpty(details.releaseDate) ?? item.releaseDate,
      trailerUrl: _nonEmpty(details.youtubeTrailerUrl) ?? item.trailerUrl,
      subtitle: () {
        final built = [
          if (details.year != null) '${details.year}',
          if (details.genres.isNotEmpty) details.genres.take(2).join(', '),
        ].join(' · ');
        return built.isNotEmpty ? built : item.subtitle;
      }(),
    );
  }

  /// Overlay provider presentation onto base details; keep playback season trees.
  static MediaDetails overlayPresentation(
    MediaDetails base,
    MediaDetails provider,
  ) {
    return MediaDetails(
      id: provider.id.isNotEmpty ? provider.id : base.id,
      title: provider.title.isNotEmpty ? provider.title : base.title,
      mediaItemId: base.mediaItemId ?? provider.mediaItemId,
      tmdbId: provider.tmdbId ?? base.tmdbId,
      simklId: _nonEmpty(provider.simklId) ?? base.simklId,
      traktId: _nonEmpty(provider.traktId) ?? base.traktId,
      anilistId: provider.anilistId ?? base.anilistId,
      imdbId: provider.imdbId ?? base.imdbId,
      tvdbId: provider.tvdbId ?? base.tvdbId,
      plot: _nonEmpty(provider.plot) ?? base.plot,
      posterUrl: _nonEmpty(provider.posterUrl) ?? base.posterUrl,
      backdropUrl: _nonEmpty(provider.backdropUrl) ?? base.backdropUrl,
      genres: provider.genres.isNotEmpty ? provider.genres : base.genres,
      rating: provider.rating ?? base.rating,
      year: provider.year ?? base.year,
      runtime: provider.runtime ?? base.runtime,
      cast: provider.cast.isNotEmpty ? provider.cast : base.cast,
      trailerUrl: provider.trailerUrl ?? base.trailerUrl,
      trailerKey: provider.trailerKey ?? base.trailerKey,
      collectionId: provider.collectionId ?? base.collectionId,
      collectionName: provider.collectionName ?? base.collectionName,
      seasons: base.seasons.isNotEmpty ? base.seasons : provider.seasons,
      seasonNumber: base.seasonNumber ?? provider.seasonNumber,
      episodeNumber: base.episodeNumber ?? provider.episodeNumber,
      tags: provider.tags.isNotEmpty ? provider.tags : base.tags,
      contentRating: _nonEmpty(provider.contentRating) ?? base.contentRating,
      studio: _nonEmpty(provider.studio) ?? base.studio,
      originalTitle: _nonEmpty(provider.originalTitle) ?? base.originalTitle,
      releaseDate: _nonEmpty(provider.releaseDate) ?? base.releaseDate,
      updatedAt: DateTime.now(),
    );
  }

  /// Keep [base] presentation; fill only blank holes from [extra] (TMDB supplement).
  static MediaDetails fillMissing(MediaDetails base, MediaDetails extra) {
    return MediaDetails(
      id: base.id.isNotEmpty ? base.id : extra.id,
      title: base.title.isNotEmpty ? base.title : extra.title,
      mediaItemId: base.mediaItemId ?? extra.mediaItemId,
      tmdbId: base.tmdbId ?? extra.tmdbId,
      simklId: _nonEmpty(base.simklId) ?? extra.simklId,
      traktId: _nonEmpty(base.traktId) ?? extra.traktId,
      anilistId: base.anilistId ?? extra.anilistId,
      imdbId: _nonEmpty(base.imdbId) ?? extra.imdbId,
      tvdbId: base.tvdbId ?? extra.tvdbId,
      plot: _nonEmpty(base.plot) ?? extra.plot,
      posterUrl: _nonEmpty(base.posterUrl) ?? extra.posterUrl,
      backdropUrl: _nonEmpty(base.backdropUrl) ?? extra.backdropUrl,
      genres: base.genres.isNotEmpty ? base.genres : extra.genres,
      rating: base.rating ?? extra.rating,
      year: base.year ?? extra.year,
      runtime: base.runtime ?? extra.runtime,
      cast: isThinCast(base.cast) && extra.cast.isNotEmpty
          ? extra.cast
          : base.cast,
      trailerUrl: base.trailerUrl ?? extra.trailerUrl,
      trailerKey: _nonEmpty(base.trailerKey) ?? extra.trailerKey,
      collectionId: base.collectionId ?? extra.collectionId,
      collectionName: _nonEmpty(base.collectionName) ?? extra.collectionName,
      // TMDB TV shells have season stubs with empty episode lists — do not
      // install those as a fake playback tree when base has no seasons yet.
      seasons: base.seasons.isNotEmpty
          ? base.seasons
          : (extra.seasons.any((s) => s.episodes.isNotEmpty)
                ? extra.seasons
                : base.seasons),
      seasonNumber: base.seasonNumber ?? extra.seasonNumber,
      episodeNumber: base.episodeNumber ?? extra.episodeNumber,
      tags: base.tags.isNotEmpty ? base.tags : extra.tags,
      contentRating: _nonEmpty(base.contentRating) ?? extra.contentRating,
      studio: _nonEmpty(base.studio) ?? extra.studio,
      originalTitle: _nonEmpty(base.originalTitle) ?? extra.originalTitle,
      releaseDate: _nonEmpty(base.releaseDate) ?? extra.releaseDate,
      updatedAt: DateTime.now(),
    );
  }

  /// Whether this origin is a "thin" catalog (enriched by default).
  ///
  /// Local files are excluded — Open-with / imports keep the filename, not a
  /// guessed TMDB match.
  static bool isThinCatalogOrigin(MediaOrigin origin) {
    return origin != MediaOrigin.jellyfin &&
        origin != MediaOrigin.emby &&
        origin != MediaOrigin.plex &&
        origin != MediaOrigin.localFile;
  }

  static bool shouldEnrich({
    required MediaOrigin origin,
    required bool enrichMediaServers,
  }) {
    if (origin == MediaOrigin.localFile) return false;
    if (isThinCatalogOrigin(origin)) return true;
    return enrichMediaServers;
  }
}
