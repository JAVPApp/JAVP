import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/multi_view_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/multi_view/multi_view_channel_picker.dart';
import 'package:provider/provider.dart';

/// Compact action strip shown while multi-view is active.
class MultiViewToolbar extends StatelessWidget {
  const MultiViewToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final multi = context.watch<MultiViewProvider>();
    if (!multi.isActive) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: l10n.multiViewSwapAudio,
              onPressed: () => unawaited(multi.swapAudio()),
              icon: const Icon(Icons.swap_horiz_rounded, color: AppColors.text),
            ),
            IconButton(
              tooltip: l10n.multiViewToggleFocus,
              onPressed: multi.toggleFocusedPane,
              icon: const Icon(
                Icons.filter_center_focus_rounded,
                color: AppColors.text,
              ),
            ),
            IconButton(
              tooltip: multi.layoutMode == MultiViewLayoutMode.pip
                  ? l10n.multiViewSideBySide
                  : l10n.multiViewPip,
              onPressed: multi.toggleLayoutMode,
              icon: Icon(
                multi.layoutMode == MultiViewLayoutMode.pip
                    ? Icons.view_column_rounded
                    : Icons.picture_in_picture_alt_rounded,
                color: AppColors.text,
              ),
            ),
            IconButton(
              tooltip: l10n.multiViewChangeSecondary,
              onPressed: () async {
                final channel = await showMultiViewChannelPicker(context);
                if (channel == null || !context.mounted) return;
                await multi.retuneSecondary(
                  channel,
                  library: context.read<LibraryProvider>(),
                );
              },
              icon: const Icon(Icons.tv_rounded, color: AppColors.text),
            ),
            IconButton(
              tooltip: l10n.multiViewExit,
              onPressed: () => unawaited(multi.exit()),
              icon: const Icon(Icons.close_rounded, color: AppColors.text),
            ),
          ],
        ),
      ),
    );
  }
}
