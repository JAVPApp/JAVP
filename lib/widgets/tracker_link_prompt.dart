import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';

/// Soft first-run offer vs restore / profile “link on this device”.
enum TrackerLinkPromptKind {
  softSetup,
  linkOnDevice,
}

/// Shows the appropriate tracker dialog and navigates to integrations or home.
///
/// Returns `true` if the user chose to configure trackers.
Future<bool> offerTrackerLinkFlow(
  BuildContext context,
  LibraryProvider library, {
  required TrackerLinkPromptKind kind,
  bool respectDismiss = true,
}) async {
  if (kind == TrackerLinkPromptKind.linkOnDevice) {
    if (!library.needsTrackerDeviceLink) {
      if (context.mounted) context.go('/home');
      return false;
    }
    if (respectDismiss && await library.isTrackerLinkPromptDismissed()) {
      if (context.mounted) context.go('/home');
      return false;
    }
  } else {
    // Soft first-run: skip when already linked, or when a restore-style link
    // prompt is the right dialog instead.
    if (library.needsTrackerDeviceLink) {
      return offerTrackerLinkFlow(
        context,
        library,
        kind: TrackerLinkPromptKind.linkOnDevice,
        respectDismiss: respectDismiss,
      );
    }
    if (library.simkl.isAuthenticated ||
        library.trakt.isAuthenticated ||
        library.serializd.isAuthenticated ||
        library.betaseries.isAuthenticated) {
      await library.dismissSoftTrackerSetup();
      if (context.mounted) context.go('/home');
      return false;
    }
    // Too early on Skip-for-now / empty Home — wait until a media source
    // exists so the library can paint before this optional nag.
    if (library.sources.isEmpty) {
      if (context.mounted) context.go('/home');
      return false;
    }
    if (respectDismiss && await library.isSoftTrackerSetupDismissed()) {
      if (context.mounted) context.go('/home');
      return false;
    }
  }

  if (!context.mounted) return false;
  final configure = await showTrackerLinkPrompt(context, kind: kind);
  if (!context.mounted) return false;

  if (configure == true) {
    if (kind == TrackerLinkPromptKind.softSetup) {
      await library.dismissSoftTrackerSetup();
    }
    if (context.mounted) context.go('/settings/integrations');
    return true;
  }

  if (kind == TrackerLinkPromptKind.linkOnDevice) {
    await library.dismissTrackerLinkPrompt();
  } else {
    await library.dismissSoftTrackerSetup();
  }
  if (context.mounted) context.go('/home');
  return false;
}

/// Dialog only — caller handles navigation / dismiss persistence.
Future<bool?> showTrackerLinkPrompt(
  BuildContext context, {
  required TrackerLinkPromptKind kind,
}) {
  final l10n = context.l10n;
  final isLink = kind == TrackerLinkPromptKind.linkOnDevice;
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        title: Text(
          isLink ? l10n.linkTrackersOnDeviceTitle : l10n.setupTrackersTitle,
        ),
        content: Text(
          isLink ? l10n.linkTrackersOnDeviceBody : l10n.setupTrackersBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppColors.textMuted,
            height: 1.4,
          ),
        ),
        actions: [
          AppActionButton(
            variant: AppActionButtonVariant.text,
            onPressed: () => Navigator.of(ctx).pop(false),
            label: l10n.setupTrackersNotNow,
          ),
          AppActionButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            label: isLink
                ? l10n.linkTrackersOnDeviceAction
                : l10n.setupTrackersAction,
          ),
        ],
      );
    },
  );
}
