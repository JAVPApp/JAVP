import 'package:flutter/material.dart';
import 'package:javp/models/live_quality_mode.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Bottom sheet / dialog to pick a live SD/HD/4K variant for this playback.
///
/// Does not persist per-family prefs unless [remember] is true or the user
/// enables the in-sheet "Remember for this channel" switch.
Future<MediaItem?> showLiveQualityPicker({
  required BuildContext context,
  required MediaItem channel,
  String? title,
  bool remember = false,
}) async {
  final library = context.read<LibraryProvider>();
  final variants = await library.qualityVariantsForAsync(channel);
  if (variants.length <= 1) return null;
  if (!context.mounted) return null;

  final current = library.resolveLiveChannel(channel);
  final heading =
      title ??
      '${context.l10n.chooseQuality} · ${library.officialLiveTitle(channel)}';

  var rememberThisChannel = remember;
  final chosen = await showAppModal<MediaItem>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    heading,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    context.l10n.preferredQualityHint,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                  ),
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: Text(context.l10n.rememberForThisChannel),
                  value: rememberThisChannel,
                  activeThumbColor: AppColors.accent,
                  onChanged: (v) =>
                      setSheetState(() => rememberThisChannel = v),
                ),
                for (final variant in variants)
                  ListTile(
                    leading: Icon(
                      variant.supportsCatchup
                          ? Icons.history_rounded
                          : Icons.live_tv_outlined,
                      color: variant.id == current.id
                          ? AppColors.accent
                          : AppColors.textMuted,
                    ),
                    title: Text(variant.title),
                    subtitle: Text(
                      ChannelQuality.detailLine(
                        variant,
                        sourceLabel: library.sourceLabelFor(variant),
                      ),
                    ),
                    trailing: variant.id == current.id
                        ? const Icon(Icons.check, color: AppColors.accent)
                        : null,
                    onTap: () => Navigator.pop(context, variant),
                  ),
              ],
            ),
          );
        },
      );
    },
  );

  if (chosen == null) return null;
  if (rememberThisChannel) {
    await library.setPreferredLiveQuality(chosen);
  } else {
    await library.setSessionLiveQuality(chosen);
  }
  return chosen;
}

/// First-tune prompt only when global mode is [LiveQualityMode.ask] and no
/// remembered preference exists yet.
///
/// Returns the chosen (or resolved default) channel to open. Cancelling keeps
/// the Auto/best variant so play is never blocked.
Future<MediaItem> promptLiveQualityIfNeeded(
  BuildContext context,
  MediaItem item,
) async {
  final library = context.read<LibraryProvider>();
  if (library.liveQualityMode != LiveQualityMode.ask) {
    return library.resolveLiveChannelAsync(item);
  }

  final variants = await library.qualityVariantsForAsync(item);
  if (!context.mounted) return library.resolveLiveChannel(item);
  if (variants.length <= 1) {
    return variants.isEmpty ? item : variants.first;
  }
  if (library.hasPreferredLiveQuality(item)) {
    return library.resolveLiveChannelAsync(item);
  }

  final chosen = await showDialog<MediaItem>(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.chooseQuality),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                context.l10n.preferredQualityHint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: 12),
              for (final variant in variants)
                TvFocusable(
                  onSelect: () => Navigator.pop(context, variant),
                  borderRadius: 10,
                  child: ListTile(
                    title: Text(variant.title),
                    subtitle: Text(
                      ChannelQuality.detailLine(
                        variant,
                        sourceLabel: library.sourceLabelFor(variant),
                      ),
                    ),
                    onTap: () => Navigator.pop(context, variant),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
        ],
      );
    },
  );

  if (chosen != null) {
    // Ask mode: remember so this family is not prompted again.
    await library.setPreferredLiveQuality(chosen);
    return chosen;
  }
  // Dismissed — play Auto once without locking a preference.
  return variants.first;
}
