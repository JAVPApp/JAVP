/// How audio tracks are chosen when a stream opens.
enum AudioTrackMode {
  /// Leave the player's default / stream default (usually original).
  original,

  /// Prefer [TrackLanguageSettings.audioLanguage] (or last manual pick).
  preferred,
}

/// Subtitle / audio language preferences for playback.
///
/// Factory defaults match common streaming apps:
/// - audio = original (stream default) — does not force a dub
/// - subtitles = preferred/content/device language when audio isn’t that language
///   (e.g. Japanese original + French captions)
class TrackLanguageSettings {
  const TrackLanguageSettings({
    this.subtitleLanguage = 'auto',
    this.audioMode = AudioTrackMode.original,
    this.audioLanguage = 'auto',
    this.rememberLastSubtitlePick = true,
    this.rememberLastAudioPick = true,
  });

  /// Original audio + captions in the listener’s language when dialogue differs.
  static const defaults = TrackLanguageSettings();

  /// Preferred subtitle language.
  ///
  /// - `off` — never auto-enable subtitles
  /// - `auto` — prefer content/UI/device locale tracks (then English as track
  ///   fallback); enabled only when playing audio isn’t already in that
  ///   primary locale (English fallback must not suppress captions)
  /// - ISO code (`en`, `fr`, `ja`, …)
  final String subtitleLanguage;

  /// Defaults to [AudioTrackMode.original].
  final AudioTrackMode audioMode;

  /// Used when [audioMode] is [AudioTrackMode.preferred].
  /// Same codes as [subtitleLanguage] (`auto` or ISO).
  final String audioLanguage;

  /// When the user picks a subtitle in the player, update [subtitleLanguage].
  final bool rememberLastSubtitlePick;

  /// When the user picks an audio track, switch to preferred + store that lang.
  final bool rememberLastAudioPick;

  bool get subtitlesOff => subtitleLanguage == 'off';

  TrackLanguageSettings copyWith({
    String? subtitleLanguage,
    AudioTrackMode? audioMode,
    String? audioLanguage,
    bool? rememberLastSubtitlePick,
    bool? rememberLastAudioPick,
  }) {
    return TrackLanguageSettings(
      subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
      audioMode: audioMode ?? this.audioMode,
      audioLanguage: audioLanguage ?? this.audioLanguage,
      rememberLastSubtitlePick:
          rememberLastSubtitlePick ?? this.rememberLastSubtitlePick,
      rememberLastAudioPick:
          rememberLastAudioPick ?? this.rememberLastAudioPick,
    );
  }

  Map<String, dynamic> toJson() => {
        'subtitleLanguage': subtitleLanguage,
        'audioMode': audioMode.name,
        'audioLanguage': audioLanguage,
        'rememberLastSubtitlePick': rememberLastSubtitlePick,
        'rememberLastAudioPick': rememberLastAudioPick,
      };

  factory TrackLanguageSettings.fromJson(Map<String, dynamic> json) {
    final modeName = json['audioMode'] as String?;
    final mode = AudioTrackMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => AudioTrackMode.original,
    );
    return TrackLanguageSettings(
      subtitleLanguage: (json['subtitleLanguage'] as String?)?.trim().isNotEmpty ==
              true
          ? (json['subtitleLanguage'] as String).trim()
          : defaults.subtitleLanguage,
      audioMode: mode,
      audioLanguage:
          (json['audioLanguage'] as String?)?.trim().isNotEmpty == true
              ? (json['audioLanguage'] as String).trim()
              : defaults.audioLanguage,
      rememberLastSubtitlePick:
          json['rememberLastSubtitlePick'] as bool? ??
              defaults.rememberLastSubtitlePick,
      rememberLastAudioPick: json['rememberLastAudioPick'] as bool? ??
          defaults.rememberLastAudioPick,
    );
  }
}
