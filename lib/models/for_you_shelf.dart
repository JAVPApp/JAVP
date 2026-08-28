import 'package:javp/models/media_item.dart';

/// Named live recommendation shelf for TV / Home For you.
class ForYouShelf {
  const ForYouShelf({
    required this.id,
    required this.title,
    required this.channels,
    this.subtitle,
  });

  final String id;
  final String title;
  final String? subtitle;
  final List<MediaItem> channels;

  bool get isEmpty => channels.isEmpty;
  bool get isNotEmpty => channels.isNotEmpty;
}
