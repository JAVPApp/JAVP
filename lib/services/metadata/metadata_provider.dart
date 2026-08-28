import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/metadata_settings.dart';

/// One search hit from any metadata API (SIMKL / Trakt / TMDB).
class MetadataSearchHit {
  const MetadataSearchHit({
    required this.id,
    required this.title,
    required this.mediaType,
    this.year,
    this.posterUrl,
    this.overview,
  });

  /// Provider-native id (TMDB int as string, SIMKL id, Trakt slug/id).
  final String id;
  final String title;

  /// `movie`, `tv`, or `anime`.
  final String mediaType;
  final int? year;
  final String? posterUrl;
  final String? overview;

  int? get idAsInt => int.tryParse(id);
}

/// Pluggable enricher used by [LibraryProvider.loadMediaDetails].
abstract class MetadataEnricher {
  MetadataProviderId get id;

  /// Enough credentials to call the API (bundled key and/or user config).
  bool get isAvailable;

  Future<MediaDetails?> enrich(
    MediaItem item, {
    String? forceType,
    String? forceExternalId,
  });

  Future<List<MetadataSearchHit>> search(String query, {String? type});
}
