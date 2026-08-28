import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/services/pairing/tv_remote_ui_strings.dart';

/// Map app l10n → phone-remote HTML strings for the current host locale.
TvRemoteUiStrings tvRemoteUiStringsFor(
  AppLocalizations l10n, {
  String? localeTag,
}) {
  return TvRemoteUiStrings(
    localeTag: localeTag ?? 'en',
    title: l10n.phoneRemoteTitle,
    subtitle: l10n.phoneRemotePageSubtitle,
    tabSearch: l10n.search,
    tabChannel: l10n.channel,
    tabPaste: l10n.phoneRemoteTabPasteUrl,
    searchLabel: l10n.searchLibrary,
    searchHelp: l10n.phoneRemoteSearchHelp,
    searchHint: l10n.phoneRemoteSearchHint,
    searchSend: l10n.phoneRemoteSendToTv,
    channelLabel: l10n.phoneRemoteChannelLabel,
    channelHelp: l10n.phoneRemoteChannelHelp,
    channelHint: l10n.phoneRemoteChannelHint,
    channelSend: l10n.phoneRemoteTuneOnTv,
    pasteLabel: l10n.phoneRemotePasteLabel,
    pasteHelp: l10n.phoneRemotePasteHelp,
    pasteHint: l10n.phoneRemotePasteHint,
    pasteSend: l10n.phoneRemoteSendUrl,
    sending: l10n.phoneRemoteSending,
    sent: l10n.phoneRemoteSent,
    lastSentPrefix: l10n.phoneRemoteLastSent,
    sessionExpiredTitle: l10n.phoneRemoteSessionExpiredTitle,
    sessionExpiredBody: l10n.phoneRemoteSessionExpiredBody,
    errorFailed: l10n.phoneRemoteErrorFailed,
    errorSearchRequired: l10n.phoneRemoteErrorSearchRequired,
    errorChannelRequired: l10n.phoneRemoteErrorChannelRequired,
    errorChannelInvalid: l10n.phoneRemoteErrorChannelInvalid,
    errorUrlRequired: l10n.phoneRemoteErrorUrlRequired,
    errorUrlInvalid: l10n.phoneRemoteErrorUrlInvalid,
    errorBadToken: l10n.phoneRemoteErrorBadToken,
    errorInvalidJson: l10n.phoneRemoteErrorInvalidJson,
  );
}
