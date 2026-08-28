class EpgProgram {
  const EpgProgram({
    required this.channelId,
    required this.title,
    required this.start,
    required this.end,
    this.description,
    this.imageUrl,
    this.catchupId,
    this.hasArchive = false,
  });

  final String channelId;
  final String title;
  final DateTime start;
  final DateTime end;
  final String? description;
  /// Optional programme artwork (XMLTV `<icon>` / Xtream cover fields).
  final String? imageUrl;
  final String? catchupId;
  final bool hasArchive;

  Duration get duration => end.difference(start);

  bool isAiringAt(DateTime moment) =>
      !moment.isBefore(start) && moment.isBefore(end);

  /// Local `HH:mm`.
  static String clockOf(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// Local start–end clocks (`20:00–21:30`).
  String get timeWindow => '${clockOf(start)}–${clockOf(end)}';

  double progressAt(DateTime moment) {
    if (!isAiringAt(moment) || duration.inMilliseconds == 0) return 0;
    final elapsed = moment.difference(start).inMilliseconds;
    return (elapsed / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Stable id for reminders: media item + start + title.
  static String reminderKey({
    required String mediaItemId,
    required EpgProgram program,
  }) {
    return '$mediaItemId|'
        '${program.start.toUtc().millisecondsSinceEpoch}|'
        '${program.title}';
  }

  Map<String, dynamic> toJson() => {
        'channelId': channelId,
        'title': title,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        if (description != null) 'description': description,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (catchupId != null) 'catchupId': catchupId,
        'hasArchive': hasArchive,
      };

  factory EpgProgram.fromJson(Map<String, dynamic> json) {
    return EpgProgram(
      channelId: json['channelId'] as String? ?? '',
      title: json['title'] as String? ?? 'Program',
      start: DateTime.parse(json['start'] as String).toUtc(),
      end: DateTime.parse(json['end'] as String).toUtc(),
      description: json['description'] as String?,
      imageUrl: json['imageUrl'] as String?,
      catchupId: json['catchupId'] as String?,
      hasArchive: json['hasArchive'] as bool? ?? false,
    );
  }
}
