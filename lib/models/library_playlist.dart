/// Ordered user playlist of [MediaItem] ids.
class LibraryPlaylist {
  const LibraryPlaylist({
    required this.id,
    required this.name,
    this.mediaItemIds = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final List<String> mediaItemIds;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  LibraryPlaylist copyWith({
    String? name,
    List<String>? mediaItemIds,
    DateTime? updatedAt,
  }) {
    return LibraryPlaylist(
      id: id,
      name: name ?? this.name,
      mediaItemIds: mediaItemIds ?? this.mediaItemIds,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mediaItemIds': mediaItemIds,
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  factory LibraryPlaylist.fromJson(Map<String, dynamic> json) {
    return LibraryPlaylist(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      mediaItemIds:
          (json['mediaItemIds'] as List?)?.map((e) => '$e').toList() ??
              const [],
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.tryParse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.tryParse(json['updatedAt'] as String),
    );
  }
}
