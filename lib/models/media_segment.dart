enum MediaSegmentType { intro, recap, credits, preview }

/// Skip window for intro / recap / credits / preview.
class MediaSegment {
  const MediaSegment({
    required this.type,
    required this.start,
    this.end,
    this.source = 'unknown',
    this.confidence,
  });

  final MediaSegmentType type;
  final Duration start;
  /// Null end means "to end of media" (typical for credits).
  final Duration? end;
  final String source;
  final double? confidence;

  bool contains(Duration position) {
    if (position < start) return false;
    if (end == null) return true;
    return position < end!;
  }

  Duration get skipTo => end ?? start;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'startMs': start.inMilliseconds,
        'endMs': end?.inMilliseconds,
        'source': source,
        'confidence': confidence,
      };

  factory MediaSegment.fromJson(Map<String, dynamic> json) {
    return MediaSegment(
      type: MediaSegmentType.values.byName(json['type'] as String),
      start: Duration(milliseconds: (json['startMs'] as num?)?.toInt() ?? 0),
      end: json['endMs'] == null
          ? null
          : Duration(milliseconds: (json['endMs'] as num).toInt()),
      source: json['source'] as String? ?? 'unknown',
      confidence: (json['confidence'] as num?)?.toDouble(),
    );
  }
}

class MediaSegmentBundle {
  const MediaSegmentBundle({
    required this.key,
    this.segments = const [],
    this.fetchedAt,
  });

  /// Cache key, e.g. `imdb:tt0903747:s1e1` or `tmdb:1396:s1e1`.
  final String key;
  final List<MediaSegment> segments;
  final DateTime? fetchedAt;

  MediaSegment? activeAt(Duration position) {
    for (final type in MediaSegmentType.values) {
      final match = segments.where((s) => s.type == type && s.contains(position));
      if (match.isNotEmpty) return match.first;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'segments': segments.map((s) => s.toJson()).toList(),
        'fetchedAt': fetchedAt?.toIso8601String(),
      };

  factory MediaSegmentBundle.fromJson(Map<String, dynamic> json) {
    return MediaSegmentBundle(
      key: json['key'] as String,
      segments: (json['segments'] as List?)
              ?.whereType<Map>()
              .map((e) => MediaSegment.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
      fetchedAt: json['fetchedAt'] == null
          ? null
          : DateTime.tryParse(json['fetchedAt'] as String),
    );
  }
}
