class TmdbCredentials {
  const TmdbCredentials({this.apiKey = ''});

  /// TMDB v3 API key (BYO).
  final String apiKey;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {'apiKey': apiKey};

  factory TmdbCredentials.fromJson(Map<String, dynamic> json) {
    return TmdbCredentials(apiKey: json['apiKey'] as String? ?? '');
  }
}
