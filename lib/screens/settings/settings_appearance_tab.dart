import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/display_settings.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/layout_mode.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:provider/provider.dart';

/// Poster / cover layout — visual browsing prefs, not playback.
class SettingsAppearanceTab extends StatelessWidget {
  const SettingsAppearanceTab({super.key});

  @override
  Widget build(BuildContext context) {
    final coverOrientation = context
        .select<LibraryProvider, MoviesCoverOrientation>(
          (l) => l.displaySettings.moviesCoverOrientation,
        );
    final showMusicTab = context.select<LibraryProvider, bool>(
      (l) => l.displaySettings.showMusicTab,
    );
    final library = context.read<LibraryProvider>();
    final l10n = context.l10n;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(
          l10n.movieCoverOrientation,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.movieCoverOrientationSubtitle,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        SegmentedButton<MoviesCoverOrientation>(
          segments: [
            ButtonSegment(
              value: MoviesCoverOrientation.vertical,
              label: Text(l10n.coverOrientationVertical),
              icon: const Icon(Icons.crop_portrait_rounded),
            ),
            ButtonSegment(
              value: MoviesCoverOrientation.horizontal,
              label: Text(l10n.coverOrientationHorizontal),
              icon: const Icon(Icons.crop_landscape_rounded),
            ),
            ButtonSegment(
              value: MoviesCoverOrientation.auto,
              label: Text(l10n.coverOrientationAuto),
              icon: const Icon(Icons.auto_awesome_rounded),
            ),
          ],
          selected: {coverOrientation},
          onSelectionChanged: (selected) {
            library.saveDisplaySettings(
              library.displaySettings.copyWith(
                moviesCoverOrientation: selected.first,
              ),
            );
          },
        ),
        const SizedBox(height: 28),
        SettingsSwitchListTile(
          value: showMusicTab,
          title: Text(l10n.showMusicTab),
          subtitle: Text(l10n.showMusicTabSubtitle),
          onChanged: (value) {
            library.saveDisplaySettings(
              library.displaySettings.copyWith(showMusicTab: value),
            );
          },
        ),
        if (DesktopUi.isDesktopOs) ...[
          const SizedBox(height: 28),
          _LayoutModeSection(library: library, l10n: l10n),
        ],
      ],
    );
  }
}

class _LayoutModeSection extends StatelessWidget {
  const _LayoutModeSection({required this.library, required this.l10n});

  final LibraryProvider library;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final layoutMode = context.select<LibraryProvider, LayoutModePreference>(
      (l) => l.displaySettings.layoutMode,
    );
    final isEnvForced = LayoutModeResolver.isEnvForced;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.layoutMode, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          isEnvForced
              ? l10n.layoutModeEnvForced
              : l10n.layoutModeSubtitle,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        SegmentedButton<LayoutModePreference>(
          segments: [
            ButtonSegment(
              value: LayoutModePreference.auto,
              label: Text(l10n.layoutModeAuto),
              icon: const Icon(Icons.auto_awesome_rounded),
            ),
            ButtonSegment(
              value: LayoutModePreference.desktop,
              label: Text(l10n.layoutModeDesktop),
              icon: const Icon(Icons.computer_rounded),
            ),
            ButtonSegment(
              value: LayoutModePreference.tv,
              label: Text(l10n.layoutModeTv),
              icon: const Icon(Icons.tv_rounded),
            ),
          ],
          selected: {layoutMode},
          onSelectionChanged: isEnvForced
              ? null
              : (selected) {
                  final newMode = selected.first;
                  library.saveDisplaySettings(
                    library.displaySettings.copyWith(layoutMode: newMode),
                  );
                  // Hot-apply is tricky (shell/navigation would need rebuild).
                  // Show a note that restart is needed for the change to apply.
                  if (newMode != LayoutModeResolver.activePreference) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.layoutModeRestartRequired),
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  }
                },
        ),
      ],
    );
  }
}
