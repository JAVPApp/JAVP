import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/live_quality_mode.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/models/track_language_settings.dart';
import 'package:javp/models/video_deinterlace_mode.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/screens/settings/settings_guide_widgets.dart';
import 'package:javp/services/playback/track_language.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:provider/provider.dart';

class SettingsPlaybackTab extends StatelessWidget {
  const SettingsPlaybackTab({super.key});

  static const _aheadChoices = [1, 2, 3, 5, 10];

  @override
  Widget build(BuildContext context) {
    // Non-switch controls only — toggles select their own bool so one flip
    // does not rebuild this whole ListView during / after the thumb settle.
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.downloadSettings.downloadAheadWhileWatching,
        l.downloadSettings.downloadAheadCount,
        l.downloadSettings.dvrPadBefore.inMinutes,
        l.downloadSettings.dvrPadAfter.inMinutes,
        l.trackLanguageSettings.subtitleLanguage,
        l.trackLanguageSettings.audioMode,
        l.trackLanguageSettings.audioLanguage,
        l.mediaServerStreamQuality,
        l.liveQualityMode,
        l.castServerTranscodeFallback,
      ),
    );
    context.select<PlaybackProvider, VideoDeinterlaceMode>(
      (p) => p.deinterlaceMode,
    );
    final library = context.read<LibraryProvider>();
    final dl = library.downloadSettings;
    final settings = library.trackLanguageSettings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(
          context.l10n.skipIntroCredits,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.skipIntroCreditsHelp,
          style: TextStyle(color: AppColors.textMuted),
        ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.autoSkipIntro),
          valueOf: (l) => l.skipSettings.autoSkipIntro,
          onChanged: (l, v) =>
              l.saveSkipSettings(l.skipSettings.copyWith(autoSkipIntro: v)),
        ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.autoSkipRecap),
          valueOf: (l) => l.skipSettings.autoSkipRecap,
          onChanged: (l, v) =>
              l.saveSkipSettings(l.skipSettings.copyWith(autoSkipRecap: v)),
        ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.autoSkipCredits),
          valueOf: (l) => l.skipSettings.autoSkipCredits,
          onChanged: (l, v) =>
              l.saveSkipSettings(l.skipSettings.copyWith(autoSkipCredits: v)),
        ),
        const SizedBox(height: 28),
        Text(
          context.l10n.downloads,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.downloadsHelp,
          style: TextStyle(color: AppColors.textMuted),
        ),
        if (!DesktopUi.enabled)
          _LibraryBoolSwitch(
            title: Text(context.l10n.downloadWifiOnly),
            subtitle: Text(context.l10n.downloadWifiOnlySubtitle),
            valueOf: (l) => l.downloadSettings.wifiOnly,
            onChanged: (l, v) => l.saveDownloadSettings(
              l.downloadSettings.copyWith(wifiOnly: v),
            ),
          ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.downloadAheadWhileWatching),
          valueOf: (l) => l.downloadSettings.downloadAheadWhileWatching,
          onChanged: (l, v) => l.saveDownloadSettings(
            l.downloadSettings.copyWith(downloadAheadWhileWatching: v),
          ),
        ),
        if (dl.downloadAheadWhileWatching) ...[
          const SizedBox(height: 4),
          Text(
            context.l10n.episodesAhead,
            style: TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [
              for (final n in _aheadChoices)
                ButtonSegment(value: n, label: Text('$n')),
            ],
            selected: {dl.aheadCountClamped},
            onSelectionChanged: (s) {
              library.saveDownloadSettings(
                dl.copyWith(downloadAheadCount: s.first),
              );
            },
          ),
        ],
        _LibraryBoolSwitch(
          title: Text(context.l10n.removeAfterWatching),
          subtitle: Text(context.l10n.removeAfterWatchingSubtitle),
          valueOf: (l) => l.downloadSettings.removeAfterWatch,
          onChanged: (l, v) => l.saveDownloadSettings(
            l.downloadSettings.copyWith(removeAfterWatch: v),
          ),
        ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.downloadNewEpisodesMyList),
          subtitle: Text(context.l10n.downloadNewEpisodesMyListSubtitle),
          valueOf: (l) => l.downloadSettings.downloadNewOnUpdate,
          onChanged: (l, v) => l.saveDownloadSettings(
            l.downloadSettings.copyWith(downloadNewOnUpdate: v),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          context.l10n.defaultCatchupPadding,
          style: TextStyle(color: AppColors.textMuted),
        ),
        _MinuteStepper(
          label: context.l10n.before,
          minutes: dl.dvrPadBefore.inMinutes.clamp(0, 15),
          onChanged: (m) => library.saveDownloadSettings(
            dl.copyWith(dvrPadBefore: Duration(minutes: m)),
          ),
        ),
        _MinuteStepper(
          label: context.l10n.after,
          minutes: dl.dvrPadAfter.inMinutes.clamp(0, 15),
          onChanged: (m) => library.saveDownloadSettings(
            dl.copyWith(dvrPadAfter: Duration(minutes: m)),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_outlined, color: AppColors.accent),
          title: Text(context.l10n.downloads),
          subtitle: Text(context.l10n.downloadsLinkSubtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/downloads'),
        ),
        const SizedBox(height: 28),
        Text(
          context.l10n.capabilityMediaServers,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.mediaServersHelp,
          style: TextStyle(color: AppColors.textMuted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.streamQuality),
          subtitle: Text(
            library.mediaServerStreamQuality.localizedLabel(context.l10n),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickMediaServerQuality(context, library),
        ),
        const SizedBox(height: 28),
        Text(
          context.l10n.liveQualityMode,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.liveQualityModeHelp,
          style: TextStyle(color: AppColors.textMuted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.liveQualityMode),
          subtitle: Text(library.liveQualityMode.localizedLabel(context.l10n)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickLiveQualityMode(context, library),
        ),
        const SizedBox(height: 28),
        Text(
          context.l10n.audioAndSubtitles,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.audioSubtitlesHelp,
          style: TextStyle(color: AppColors.textMuted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.preferredSubtitles),
          subtitle: Text(
            settings.subtitlesOff
                ? context.l10n.off
                : settings.subtitleLanguage == 'auto'
                ? context.l10n.deviceLanguageIfAudioDiffers(
                    TrackLanguage.deviceLanguageCode().toUpperCase(),
                  )
                : TrackLanguage.labelForL10n(
                    context.l10n,
                    settings.subtitleLanguage,
                  ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickSubtitleLanguage(context, library, settings),
        ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.rememberLastSubtitlePick),
          subtitle: Text(context.l10n.rememberLastSubtitlePickSubtitle),
          valueOf: (l) => l.trackLanguageSettings.rememberLastSubtitlePick,
          onChanged: (l, v) => l.saveTrackLanguageSettings(
            l.trackLanguageSettings.copyWith(rememberLastSubtitlePick: v),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.audio),
          subtitle: Text(
            settings.audioMode == AudioTrackMode.original
                ? context.l10n.originalStreamDefault
                : context.l10n.preferLanguageNamed(
                    TrackLanguage.labelForL10n(
                      context.l10n,
                      settings.audioLanguage,
                    ),
                  ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickAudioMode(context, library, settings),
        ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.rememberLastAudioPick),
          subtitle: Text(context.l10n.rememberLastAudioPickSubtitle),
          valueOf: (l) => l.trackLanguageSettings.rememberLastAudioPick,
          onChanged: (l, v) => l.saveTrackLanguageSettings(
            l.trackLanguageSettings.copyWith(rememberLastAudioPick: v),
          ),
        ),
        const SizedBox(height: 28),
        Text(
          context.l10n.captions,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.captionsHelp,
          style: TextStyle(color: AppColors.textMuted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.subtitles_outlined,
            color: AppColors.accent,
          ),
          title: Text(context.l10n.captionStyle),
          subtitle: Text(context.l10n.captionStyleSubtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/captions'),
        ),
        const SizedBox(height: 28),
        Text(
          context.l10n.decoder,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.decoderHelp,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.softwareVideoDecoder),
          subtitleBuilder: (context, enabled) => Text(
            enabled
                ? context.l10n.softwareDecoderOn
                : context.l10n.softwareDecoderOff,
          ),
          valueOf: (l) => l.softwareVideoDecoder,
          onChanged: (l, v) async {
            await l.saveSoftwareVideoDecoder(v);
            if (!context.mounted) return;
            await context.read<PlaybackProvider>().reloadForDecoderChange();
          },
        ),
        if (AppCapabilities.usesMediaKit) ...[
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.filter_frames_rounded,
              color: AppColors.accent,
            ),
            title: Text(context.l10n.deinterlace),
            subtitle: Text(
              context.read<PlaybackProvider>().deinterlaceMode.localizedLabel(
                context.l10n,
              ),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _pickDeinterlaceMode(context),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 56, bottom: 4),
            child: Text(
              context.l10n.deinterlaceHelp,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 28),
        Text(
          context.l10n.googleCast,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.castServerTranscodeFallbackHelp,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        _LibraryBoolSwitch(
          title: Text(context.l10n.castServerTranscodeFallback),
          valueOf: (l) => l.castServerTranscodeFallback,
          onChanged: (l, v) => l.saveCastServerTranscodeFallback(v),
        ),
        const SizedBox(height: 28),
        Text(
          context.l10n.playerSection,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        SettingsInfoTile(
          icon: Icons.fast_forward_rounded,
          title: context.l10n.holdSidesFor2x,
          subtitle: context.l10n.holdSidesFor2xSubtitle,
        ),
        SettingsInfoTile(
          icon: Icons.touch_app_rounded,
          title: context.l10n.doubleTapSeek,
          subtitle: context.l10n.doubleTapSeekSubtitle,
        ),
        SettingsInfoTile(
          icon: Icons.lock_outline_rounded,
          title: context.l10n.lockControls,
          subtitle: context.l10n.lockControlsSubtitle,
        ),
      ],
    );
  }
}

Future<void> _pickMediaServerQuality(
  BuildContext context,
  LibraryProvider library,
) async {
  final chosen = await showAppModal<MediaServerStreamQuality>(
    context: context,
    builder: (context) {
      final current = library.mediaServerStreamQuality;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                context.l10n.streamQuality,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            for (final q in MediaServerStreamQuality.values)
              ListTile(
                title: Text(q.localizedLabel(context.l10n)),
                subtitle: Text(q.localizedSubtitle(context.l10n)),
                trailing: current == q
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, q),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (chosen == null) return;
  await library.saveMediaServerStreamQuality(chosen);
}

Future<void> _pickLiveQualityMode(
  BuildContext context,
  LibraryProvider library,
) async {
  final chosen = await showAppModal<LiveQualityMode>(
    context: context,
    builder: (context) {
      final current = library.liveQualityMode;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                context.l10n.liveQualityMode,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            for (final mode in LiveQualityMode.values)
              ListTile(
                title: Text(mode.localizedLabel(context.l10n)),
                subtitle: Text(mode.localizedSubtitle(context.l10n)),
                trailing: current == mode
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, mode),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (chosen == null) return;
  await library.setLiveQualityMode(chosen);
}

Future<void> _pickDeinterlaceMode(BuildContext context) async {
  final playback = context.read<PlaybackProvider>();
  final chosen = await showAppModal<VideoDeinterlaceMode>(
    context: context,
    builder: (context) {
      final current = playback.deinterlaceMode;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                context.l10n.deinterlace,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            for (final mode in VideoDeinterlaceMode.values)
              ListTile(
                title: Text(mode.localizedLabel(context.l10n)),
                subtitle: Text(mode.localizedSubtitle(context.l10n)),
                trailing: current == mode
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, mode),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (chosen == null) return;
  await playback.setDeinterlaceMode(chosen);
}

Future<void> _pickSubtitleLanguage(
  BuildContext context,
  LibraryProvider library,
  TrackLanguageSettings settings,
) async {
  final chosen = await showAppModal<String>(
    context: context,
    builder: (context) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                context.l10n.preferredSubtitles,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            ListTile(
              title: Text(context.l10n.off),
              trailing: settings.subtitleLanguage == 'off'
                  ? const Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(context, 'off'),
            ),
            for (final c in TrackLanguage.commonChoices)
              ListTile(
                title: Text(TrackLanguage.labelForL10n(context.l10n, c.code)),
                trailing: settings.subtitleLanguage == c.code
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, c.code),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (chosen == null) return;
  await library.saveTrackLanguageSettings(
    settings.copyWith(subtitleLanguage: chosen),
  );
}

Future<void> _pickAudioMode(
  BuildContext context,
  LibraryProvider library,
  TrackLanguageSettings settings,
) async {
  final chosen = await showAppModal<({AudioTrackMode mode, String? lang})>(
    context: context,
    builder: (context) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                context.l10n.audio,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            ListTile(
              title: Text(context.l10n.originalStreamDefault),
              subtitle: Text(context.l10n.doNotAutoSwitchAudio),
              trailing: settings.audioMode == AudioTrackMode.original
                  ? const Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(context, (
                mode: AudioTrackMode.original,
                lang: null,
              )),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                context.l10n.preferLanguage,
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
            for (final c in TrackLanguage.commonChoices)
              ListTile(
                title: Text(TrackLanguage.labelForL10n(context.l10n, c.code)),
                trailing:
                    settings.audioMode == AudioTrackMode.preferred &&
                        settings.audioLanguage == c.code
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, (
                  mode: AudioTrackMode.preferred,
                  lang: c.code,
                )),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (chosen == null) return;
  await library.saveTrackLanguageSettings(
    settings.copyWith(
      audioMode: chosen.mode,
      audioLanguage: chosen.lang ?? settings.audioLanguage,
    ),
  );
}

class _MinuteStepper extends StatelessWidget {
  const _MinuteStepper({
    required this.label,
    required this.minutes,
    required this.onChanged,
  });

  final String label;
  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 72, child: Text(label)),
        IconButton(
          onPressed: minutes > 0 ? () => onChanged(minutes - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text(
          context.l10n.minutesShort(minutes),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        IconButton(
          onPressed: minutes < 15 ? () => onChanged(minutes + 1) : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

/// Selects a single library bool so flipping one toggle does not rebuild the
/// whole playback settings [ListView].
class _LibraryBoolSwitch extends StatelessWidget {
  const _LibraryBoolSwitch({
    required this.title,
    required this.valueOf,
    required this.onChanged,
    this.subtitle,
    this.subtitleBuilder,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget Function(BuildContext context, bool value)? subtitleBuilder;
  final bool Function(LibraryProvider library) valueOf;
  final void Function(LibraryProvider library, bool value) onChanged;

  @override
  Widget build(BuildContext context) {
    final value = context.select<LibraryProvider, bool>(valueOf);
    return SettingsSwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: title,
      subtitle: subtitleBuilder?.call(context, value) ?? subtitle,
      value: value,
      onChanged: (v) => onChanged(context.read<LibraryProvider>(), v),
    );
  }
}
