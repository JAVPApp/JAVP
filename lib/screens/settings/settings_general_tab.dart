import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/config/distribution.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/update_provider.dart';
import 'package:javp/screens/settings/settings_guide_widgets.dart';
import 'package:javp/services/platform/desktop_tray_service.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/buffering_easter_egg.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:javp/widgets/update_dialog.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

const _kJavpWebsite = 'https://javp.app';
const _kJavpDiscord = 'https://discord.gg/deEVVzzaE4';

class SettingsGeneralTab extends StatefulWidget {
  const SettingsGeneralTab({super.key});

  @override
  State<SettingsGeneralTab> createState() => _SettingsGeneralTabState();
}

class _SettingsGeneralTabState extends State<SettingsGeneralTab> {
  Future<void> _pickLanguageSafe(BuildContext context) async {
    final localeController = context.read<LocaleController>();
    final l10n = context.l10n;
    final result = await showAppModal<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final current = localeController.overrideLocale?.languageCode;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(l10n.systemDefault),
                trailing: current == null
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, 'system'),
              ),
              for (final locale in LocaleController.supportedLocales)
                ListTile(
                  title: Text(LocaleController.nativeName(locale)),
                  trailing: current == locale.languageCode
                      ? const Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () => Navigator.pop(context, locale),
                ),
            ],
          ),
        );
      },
    );
    if (!context.mounted || result == null) return;
    if (result == 'system') {
      await localeController.setLocale(null);
    } else if (result is Locale) {
      await localeController.setLocale(result);
    }
  }

  Future<void> _pickContentLocalesSafe(BuildContext context) async {
    final localeController = context.read<LocaleController>();
    final l10n = context.l10n;
    await showAppModal<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: AnimatedBuilder(
            animation: localeController,
            builder: (context, _) {
              final selected = localeController.preferredContentLocalesOverride
                  .toSet();
              return ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      l10n.preferredContentLanguagesSubtitle,
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  ListTile(
                    title: Text(l10n.preferredContentLanguagesFollowDevice),
                    trailing: selected.isEmpty
                        ? const Icon(
                            Icons.check_rounded,
                            color: AppColors.accent,
                          )
                        : null,
                    onTap: () async {
                      await localeController.setPreferredContentLocales(
                        const [],
                      );
                    },
                  ),
                  for (final locale in LocaleController.supportedLocales)
                    CheckboxListTile(
                      value: selected.contains(locale.languageCode),
                      controlAffinity: ListTileControlAffinity.trailing,
                      activeColor: AppColors.accent,
                      title: Text(LocaleController.nativeName(locale)),
                      onChanged: (_) {
                        unawaited(
                          localeController.togglePreferredContentLocale(
                            locale.languageCode,
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<UpdateProvider>().loadPackageInfo();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Length-only stamps — never touch [LibraryProvider.allContent] (allocates).
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.watchlist.length,
        l.favoriteChannels.length,
        l.recentHistory.length,
        l.localMedia.length,
        l.catalog.length,
        l.sources.length,
      ),
    );
    final library = context.read<LibraryProvider>();
    final l10n = context.l10n;
    final localeController = context.watch<LocaleController>();
    final languageLabel = localeController.overrideLocale == null
        ? l10n.systemDefault
        : LocaleController.nativeName(localeController.overrideLocale!);
    final contentOverrides = localeController.preferredContentLocalesOverride;
    final contentLocalesLabel = contentOverrides.isEmpty
        ? l10n.preferredContentLanguagesFollowDevice
        : contentOverrides.length == 1
        ? LocaleController.nativeNameForCode(contentOverrides.first)
        : l10n.preferredContentLanguagesCount(contentOverrides.length);
    final updates = context.watch<UpdateProvider>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(
          l10n.appLanguage,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.appLanguageSubtitle,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.language_rounded, color: AppColors.accent),
          title: Text(l10n.appLanguage),
          subtitle: Text(languageLabel),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickLanguageSafe(context),
        ),
        const SizedBox(height: 28),
        Text(
          l10n.preferredContentLanguages,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.preferredContentLanguagesSubtitle,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.translate_rounded, color: AppColors.accent),
          title: Text(l10n.preferredContentLanguages),
          subtitle: Text(contentLocalesLabel),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickContentLocalesSafe(context),
        ),
        const SizedBox(height: 28),
        Text(
          l10n.localHistory,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.localHistoryBlurb,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.bookmarks_outlined,
            color: AppColors.accent,
          ),
          title: Text(
            l10n.myListCountFavorites(
              library.watchlist.length,
              library.favoriteChannels.length,
            ),
          ),
          subtitle: Text(l10n.watchlistAndStarred),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/mylist'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history_rounded, color: AppColors.accent),
          title: Text(l10n.watchedTitlesCount(library.recentHistory.length)),
          subtitle: Text(l10n.openHistoryBrowseOrClear),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/history'),
        ),
        if (library.recentHistory.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: AppActionButton(
              variant: AppActionButtonVariant.text,
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: AppColors.surface,
                    title: Text(l10n.clearWatchHistoryTitle),
                    content: Text(l10n.clearWatchHistoryBody),
                    actions: [
                      AppActionButton(
                        variant: AppActionButtonVariant.text,
                        onPressed: () => Navigator.pop(context, false),
                        label: l10n.cancel,
                      ),
                      AppActionButton(
                        onPressed: () => Navigator.pop(context, true),
                        label: l10n.clear,
                      ),
                    ],
                  ),
                );
                if (ok == true) await library.clearHistory();
              },
              label: l10n.clearLocalHistory,
            ),
          ),
        const SizedBox(height: 28),
        Text(l10n.navLibrary, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.category_outlined, color: AppColors.accent),
          title: Text(l10n.browseByGenre),
          subtitle: Text(l10n.browseByGenreSubtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/genres'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.collections_bookmark_outlined,
            color: AppColors.accent,
          ),
          title: Text(l10n.collections),
          subtitle: Text(l10n.collectionsSubtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/collections'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.queue_music_rounded,
            color: AppColors.accent,
          ),
          title: Text(l10n.playlists),
          subtitle: Text(l10n.playlistsSubtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/playlists'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_rounded, color: AppColors.accent),
          title: Text(l10n.downloads),
          subtitle: Text(l10n.downloadsSubtitleSettings),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/downloads'),
        ),
        const SizedBox(height: 28),
        if (updates.supportsInAppUpdates) ...[
          Text(l10n.updates, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            updates.channel.isDev
                ? 'Dev channel — checks https://updater.javp.app/dev (does not affect stable).'
                : updates.isWindowsTarget
                ? l10n.windowsUpdateSummary
                : updates.isLinuxTarget
                ? l10n.linuxUpdateSummary
                : updates.isMacosTarget
                ? l10n.macosUpdateSummary
                : l10n.updatesBlurb,
            style: const TextStyle(color: AppColors.textMuted),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.system_update_rounded,
              color: AppColors.accent,
            ),
            title: Text(l10n.checkForUpdates),
            subtitle: Text(_updateSubtitle(context, updates)),
            trailing: updates.status == UpdateStatus.checking
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onTap: () => _checkForUpdates(context),
          ),
          if (updates.available != null)
            Align(
              alignment: Alignment.centerLeft,
              child: AppActionButton(
                icon: Icons.download_rounded,
                onPressed: () => showUpdateDialog(context, fromSettings: true),
                label: l10n.installVersion(updates.available!.versionName),
              ),
            ),
          const SizedBox(height: 28),
        ],
        if (isWindowsDesktop) ...[
          const _CloseToTrayToggle(),
          const SizedBox(height: 28),
        ],
        Text(l10n.about, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        BufferingTapTarget(
          child: SettingsInfoTile(
            icon: Icons.movie_filter_outlined,
            title: l10n.appTitle,
            subtitle: l10n.aboutSubtitle,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.info_outline_rounded),
          title: Text(l10n.versionLabel(updates.currentLabel)),
          subtitle: Text(_distributionLine(context, updates)),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.language_rounded, color: AppColors.accent),
          title: Text(l10n.openWebsite),
          subtitle: const Text('javp.app'),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: () => _openExternal(_kJavpWebsite),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.forum_outlined, color: AppColors.accent),
          title: Text(l10n.joinDiscord),
          subtitle: Text(l10n.joinDiscordSubtitle),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: () => _openExternal(_kJavpDiscord),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.library_books_outlined),
          title: Text(
            l10n.titlesInLibraryCount(
              library.localMedia.length + library.catalog.length,
            ),
          ),
          subtitle: Text(l10n.iptvSourcesCount(library.sources.length)),
        ),
      ],
    );
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  /// Play / Microsoft Store defer to their store; sideload names its channel,
  /// and Windows sideload says so rather than reading as an APK.
  String _distributionLine(BuildContext context, UpdateProvider updates) {
    final l10n = context.l10n;
    if (Distribution.isPlayStore) return l10n.updatesViaGooglePlay;
    if (Distribution.isMicrosoftStore) return l10n.updatesViaMicrosoftStore;
    final label = updates.isWindowsTarget
        ? 'Windows'
        : updates.isLinuxTarget
        ? 'Linux'
        : Distribution.label;
    final line = l10n.distributionLabel(label);
    return updates.channel.isDev ? '$line · Dev' : line;
  }

  String _updateSubtitle(BuildContext context, UpdateProvider updates) {
    final l10n = context.l10n;
    switch (updates.status) {
      case UpdateStatus.available:
        return l10n.updateAvailableSubtitle(updates.available!.versionName);
      case UpdateStatus.upToDate:
        return l10n.onLatestBuild;
      case UpdateStatus.error:
        return updates.error ?? l10n.updateCheckFailed;
      case UpdateStatus.downloading:
        return l10n.downloadingEllipsis;
      case UpdateStatus.installing:
        return l10n.installingEllipsis;
      case UpdateStatus.readyToInstall:
        return l10n.downloadReadyInstall;
      case UpdateStatus.checking:
        return l10n.checkingForUpdates;
      case UpdateStatus.idle:
        return l10n.tapToCheckForUpdates;
    }
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    final updates = context.read<UpdateProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      final latest = await updates.check(manual: true, ignoreSkipped: true);
      if (!context.mounted) return;
      if (latest != null) {
        await showUpdateDialog(context, fromSettings: true);
      } else {
        messenger.showSnackBar(SnackBar(content: Text(l10n.onLatestJavpBuild)));
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.updateCheckFailedWithError('$e'))),
      );
    }
  }
}

class _CloseToTrayToggle extends StatefulWidget {
  const _CloseToTrayToggle();

  @override
  State<_CloseToTrayToggle> createState() => _CloseToTrayToggleState();
}

class _CloseToTrayToggleState extends State<_CloseToTrayToggle> {
  late bool _enabled = DesktopTrayService.instance.closeToTray;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: const Icon(
        Icons.notifications_none_rounded,
        color: AppColors.accent,
      ),
      title: Text(l10n.closeToTray),
      subtitle: Text(l10n.closeToTraySubtitle),
      value: _enabled,
      onWillChange: (v) => setState(() => _enabled = v),
      onChanged: (v) async {
        await DesktopTrayService.instance.setCloseToTray(v);
        if (!mounted) return;
        final actual = DesktopTrayService.instance.closeToTray;
        if (actual != _enabled) setState(() => _enabled = actual);
      },
    );
  }
}
