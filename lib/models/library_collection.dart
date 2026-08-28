/// User or TMDB-backed collection of titles.
class LibraryCollection {
  const LibraryCollection({
    required this.id,
    required this.name,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.tmdbCollectionId,
    this.mediaItemIds = const [],
    this.createdAt,
  });

  final String id;
  final String name;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final int? tmdbCollectionId;
  final List<String> mediaItemIds;
  final DateTime? createdAt;

  LibraryCollection copyWith({
    String? name,
    String? overview,
    String? posterUrl,
    String? backdropUrl,
    int? tmdbCollectionId,
    List<String>? mediaItemIds,
  }) {
    return LibraryCollection(
      id: id,
      name: name ?? this.name,
      overview: overview ?? this.overview,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      tmdbCollectionId: tmdbCollectionId ?? this.tmdbCollectionId,
      mediaItemIds: mediaItemIds ?? this.mediaItemIds,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'overview': overview,
        'posterUrl': posterUrl,
        'backdropUrl': backdropUrl,
        'tmdbCollectionId': tmdbCollectionId,
        'mediaItemIds': mediaItemIds,
        'createdAt': createdAt?.toIso8601String(),
      };

  factory LibraryCollection.fromJson(Map<String, dynamic> json) {
    return LibraryCollection(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      overview: json['overview'] as String?,
      posterUrl: json['posterUrl'] as String?,
      backdropUrl: json['backdropUrl'] as String?,
      tmdbCollectionId: (json['tmdbCollectionId'] as num?)?.toInt(),
      mediaItemIds:
          (json['mediaItemIds'] as List?)?.map((e) => '$e').toList() ??
              const [],
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.tryParse(json['createdAt'] as String),
    );
  }
}
