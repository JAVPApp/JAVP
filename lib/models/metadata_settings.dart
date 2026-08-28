/// Which external API enriches posters / plots / cast on thin catalogs.
enum MetadataProviderId {
  off,
  simkl,
  trakt,
  tmdb,
}

/// User preferences for metadata enrichment and non-secret tracker intent.
///
/// OAuth tokens stay in profile-scoped secure storage. File-based profile
/// sync (folder / WebDAV / Drive JSON) never writes them — only
/// [wantSimklLink] / [wantTraktLink] / [wantSerializdLink] /
/// [wantBetaseriesLink] so other devices can prompt to sign in.
/// A future JAVP cloud account would store the tokens.
class MetadataSettings {
  const MetadataSettings({
    this.provider = MetadataProviderId.simkl,
    this.enrichMediaServers = false,
    this.wantSimklLink = false,
    this.wantTraktLink = false,
    this.wantSerializdLink = false,
    this.wantBetaseriesLink = false,
    this.simklScrobbleEnabled = true,
    this.serializdScrobbleEnabled = true,
  });

  static const defaults = MetadataSettings();

  final MetadataProviderId provider;

  /// When false (default), Jellyfin / Emby / Plex keep server metadata.
  final bool enrichMediaServers;

  /// Profile used SIMKL on some device — other devices should prompt to link.
  final bool wantSimklLink;

  /// Profile used Trakt on some device — other devices should prompt to link.
  final bool wantTraktLink;

  /// Profile used Serializd on some device — other devices should prompt to link.
  final bool wantSerializdLink;

  /// Profile used BetaSeries on some device — other devices should prompt to link.
  final bool wantBetaseriesLink;

  /// When false, Watching sync may still run but scrobble is skipped.
  final bool simklScrobbleEnabled;

  /// When false, Serializd list sync may still run but episode log is skipped.
  final bool serializdScrobbleEnabled;

  MetadataSettings copyWith({
    MetadataProviderId? provider,
    bool? enrichMediaServers,
    bool? wantSimklLink,
    bool? wantTraktLink,
    bool? wantSerializdLink,
    bool? wantBetaseriesLink,
    bool? simklScrobbleEnabled,
    bool? serializdScrobbleEnabled,
  }) {
    return MetadataSettings(
      provider: provider ?? this.provider,
      enrichMediaServers: enrichMediaServers ?? this.enrichMediaServers,
      wantSimklLink: wantSimklLink ?? this.wantSimklLink,
      wantTraktLink: wantTraktLink ?? this.wantTraktLink,
      wantSerializdLink: wantSerializdLink ?? this.wantSerializdLink,
      wantBetaseriesLink: wantBetaseriesLink ?? this.wantBetaseriesLink,
      simklScrobbleEnabled: simklScrobbleEnabled ?? this.simklScrobbleEnabled,
      serializdScrobbleEnabled:
          serializdScrobbleEnabled ?? this.serializdScrobbleEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'provider': provider.name,
        'enrichMediaServers': enrichMediaServers,
        'wantSimklLink': wantSimklLink,
        'wantTraktLink': wantTraktLink,
        'wantSerializdLink': wantSerializdLink,
        'wantBetaseriesLink': wantBetaseriesLink,
        'simklScrobbleEnabled': simklScrobbleEnabled,
        'serializdScrobbleEnabled': serializdScrobbleEnabled,
      };

  factory MetadataSettings.fromJson(Map<String, dynamic> json) {
    final name = json['provider'] as String?;
    final provider = MetadataProviderId.values.firstWhere(
      (p) => p.name == name,
      orElse: () => MetadataProviderId.simkl,
    );
    return MetadataSettings(
      provider: provider,
      enrichMediaServers:
          json['enrichMediaServers'] as bool? ?? defaults.enrichMediaServers,
      wantSimklLink: json['wantSimklLink'] as bool? ?? defaults.wantSimklLink,
      wantTraktLink: json['wantTraktLink'] as bool? ?? defaults.wantTraktLink,
      wantSerializdLink:
          json['wantSerializdLink'] as bool? ?? defaults.wantSerializdLink,
      wantBetaseriesLink:
          json['wantBetaseriesLink'] as bool? ?? defaults.wantBetaseriesLink,
      simklScrobbleEnabled: json['simklScrobbleEnabled'] as bool? ??
          defaults.simklScrobbleEnabled,
      serializdScrobbleEnabled: json['serializdScrobbleEnabled'] as bool? ??
          defaults.serializdScrobbleEnabled,
    );
  }
}
