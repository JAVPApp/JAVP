import 'package:javp/models/epg_program.dart';

class EpgReminder {
  const EpgReminder({
    required this.id,
    required this.mediaItemId,
    required this.channelTitle,
    required this.programTitle,
    required this.start,
    this.epgChannelId,
    this.description,
  });

  /// Stable key (see [EpgProgram.reminderKey]).
  final String id;
  final String mediaItemId;
  final String channelTitle;
  final String programTitle;
  final DateTime start;
  final String? epgChannelId;
  final String? description;

  /// Android/iOS notification id (31-bit positive).
  int get notificationId => id.hashCode & 0x7fffffff;

  bool get isPast => !start.isAfter(DateTime.now());

  factory EpgReminder.fromProgram({
    required String mediaItemId,
    required String channelTitle,
    required EpgProgram program,
  }) {
    return EpgReminder(
      id: EpgProgram.reminderKey(mediaItemId: mediaItemId, program: program),
      mediaItemId: mediaItemId,
      channelTitle: channelTitle,
      programTitle: program.title,
      start: program.start,
      epgChannelId: program.channelId,
      description: program.description,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'mediaItemId': mediaItemId,
        'channelTitle': channelTitle,
        'programTitle': programTitle,
        'start': start.toUtc().toIso8601String(),
        if (epgChannelId != null) 'epgChannelId': epgChannelId,
        if (description != null) 'description': description,
      };

  factory EpgReminder.fromJson(Map<String, dynamic> json) {
    return EpgReminder(
      id: json['id'] as String? ?? '',
      mediaItemId: json['mediaItemId'] as String? ?? '',
      channelTitle: json['channelTitle'] as String? ?? '',
      programTitle: json['programTitle'] as String? ?? '',
      start: DateTime.parse(json['start'] as String).toUtc(),
      epgChannelId: json['epgChannelId'] as String?,
      description: json['description'] as String?,
    );
  }
}
