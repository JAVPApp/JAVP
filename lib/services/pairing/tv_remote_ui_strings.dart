/// Copy for the phone-browser remote page (injected into LAN HTML).
///
/// Built from [AppLocalizations] on the TV / desktop host so the phone page
/// matches the app language. English defaults keep unit tests dependency-light.
class TvRemoteUiStrings {
  const TvRemoteUiStrings({
    required this.localeTag,
    required this.title,
    required this.subtitle,
    required this.tabSearch,
    required this.tabChannel,
    required this.tabPaste,
    required this.searchLabel,
    required this.searchHelp,
    required this.searchHint,
    required this.searchSend,
    required this.channelLabel,
    required this.channelHelp,
    required this.channelHint,
    required this.channelSend,
    required this.pasteLabel,
    required this.pasteHelp,
    required this.pasteHint,
    required this.pasteSend,
    required this.sending,
    required this.sent,
    required this.lastSentPrefix,
    required this.sessionExpiredTitle,
    required this.sessionExpiredBody,
    required this.errorFailed,
    required this.errorSearchRequired,
    required this.errorChannelRequired,
    required this.errorChannelInvalid,
    required this.errorUrlRequired,
    required this.errorUrlInvalid,
    required this.errorBadToken,
    required this.errorInvalidJson,
  });

  final String localeTag;
  final String title;
  final String subtitle;
  final String tabSearch;
  final String tabChannel;
  final String tabPaste;
  final String searchLabel;
  final String searchHelp;
  final String searchHint;
  final String searchSend;
  final String channelLabel;
  final String channelHelp;
  final String channelHint;
  final String channelSend;
  final String pasteLabel;
  final String pasteHelp;
  final String pasteHint;
  final String pasteSend;
  final String sending;
  final String sent;

  /// Prefix before the echoed value, e.g. "Last sent".
  final String lastSentPrefix;
  final String sessionExpiredTitle;
  final String sessionExpiredBody;
  final String errorFailed;
  final String errorSearchRequired;
  final String errorChannelRequired;
  final String errorChannelInvalid;
  final String errorUrlRequired;
  final String errorUrlInvalid;
  final String errorBadToken;
  final String errorInvalidJson;

  static const english = TvRemoteUiStrings(
    localeTag: 'en',
    title: 'Phone remote',
    subtitle: 'Same Wi‑Fi as the TV. Text stays on your LAN.',
    tabSearch: 'Search',
    tabChannel: 'Channel',
    tabPaste: 'Paste URL',
    searchLabel: 'Search library',
    searchHelp: 'Find titles and channels in your library.',
    searchHint: 'Type a title or channel…',
    searchSend: 'Send to TV',
    channelLabel: 'Channel number',
    channelHelp: 'Jump to a Live channel by number.',
    channelHint: 'e.g. 42',
    channelSend: 'Tune on TV',
    pasteLabel: 'Stream or magnet URL',
    pasteHelp: 'Add a stream or magnet link to the TV.',
    pasteHint: 'https://…/stream.m3u8',
    pasteSend: 'Send URL',
    sending: 'Sending…',
    sent: 'Sent to TV.',
    lastSentPrefix: 'Last sent',
    sessionExpiredTitle: 'Session expired',
    sessionExpiredBody:
        'This remote code expired. Open phone remote on the TV and scan again.',
    errorFailed: 'Failed',
    errorSearchRequired: 'Search text required',
    errorChannelRequired: 'Channel number required',
    errorChannelInvalid: 'Channel number must be a positive integer',
    errorUrlRequired: 'URL required',
    errorUrlInvalid: 'URL must start with http(s):// or magnet:',
    errorBadToken: 'Invalid or expired token',
    errorInvalidJson: 'Invalid JSON',
  );

  String errorForCode(String code) {
    return switch (code) {
      'search_required' => errorSearchRequired,
      'channel_required' => errorChannelRequired,
      'channel_invalid' => errorChannelInvalid,
      'url_required' => errorUrlRequired,
      'url_invalid' => errorUrlInvalid,
      'bad_token' => errorBadToken,
      'invalid_json' => errorInvalidJson,
      _ => errorFailed,
    };
  }

  Map<String, String> toJsMap() => {
    'sending': sending,
    'sent': sent,
    'lastSentPrefix': lastSentPrefix,
    'errorFailed': errorFailed,
    'search_required': errorSearchRequired,
    'channel_required': errorChannelRequired,
    'channel_invalid': errorChannelInvalid,
    'url_required': errorUrlRequired,
    'url_invalid': errorUrlInvalid,
    'bad_token': errorBadToken,
    'invalid_json': errorInvalidJson,
  };
}

/// Parse failure with a stable [code] for localized phone UI.
class TvRemoteParseException implements Exception {
  const TvRemoteParseException(this.code);

  final String code;

  @override
  String toString() => 'TvRemoteParseException($code)';
}
