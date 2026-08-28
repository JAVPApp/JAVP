import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';

enum TorrentPrivacyTipResult {
  continueAnyway,
  openSettings,
}

/// One-time tip recommending a VPN or proxy before torrent traffic starts.
Future<TorrentPrivacyTipResult> showTorrentPrivacyTipDialog(
  BuildContext context,
) async {
  final result = await showDialog<TorrentPrivacyTipResult>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    builder: (context) {
      final l10n = context.l10n;
      return AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.torrentVpnTipTitle),
        content: Text(
          l10n.torrentVpnTipMessage,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          AppActionButton(
            variant: AppActionButtonVariant.text,
            onPressed: () => Navigator.pop(
              context,
              TorrentPrivacyTipResult.continueAnyway,
            ),
            label: l10n.torrentVpnTipContinue,
          ),
          AppActionButton(
            onPressed: () => Navigator.pop(
              context,
              TorrentPrivacyTipResult.openSettings,
            ),
            label: l10n.torrentVpnTipOpenNetwork,
          ),
        ],
      );
    },
  );
  return result ?? TorrentPrivacyTipResult.continueAnyway;
}
