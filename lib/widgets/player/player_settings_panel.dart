import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/caption_style.dart';
import 'package:javp/models/playback_speeds.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/models/video_aspect_mode.dart';
import 'package:javp/models/video_deinterlace_mode.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/providers/caption_style_provider.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/download/download_manager.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/playback/track_language.dart';
import 'package:javp/services/platform/external_player.dart';
import 'package:javp/services/platform/external_player_actions.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/player/player_settings_page.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:javp/widgets/download/dvr_download_dialog.dart';
import 'package:javp/compat/media_kit.dart';
import 'package:provider/provider.dart';

/// Wide enough for a right-side sheet that still leaves most of the video up.
const double kPlayerOverlaySideBreakpoint = 560;

/// Width of the in-player settings / picker side sheet.
@visibleForTesting
double playerOverlayPanelWidth(double screenWidth) {
  return (screenWidth * 0.38)
      .clamp(300.0, 360.0)
      .clamp(0.0, screenWidth * 0.86);
}

@visibleForTesting
bool usePlayerOverlaySidePanel(double screenWidth) =>
    screenWidth >= kPlayerOverlaySideBreakpoint;

/// Compact overlay that keeps most of the video visible.
///
/// Landscape / desktop: right-side panel. Narrow portrait: short bottom sheet.
Future<T?> showPlayerOverlaySheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
}) {
  final size = MediaQuery.sizeOf(context);
  const barrier = Color(0x59000000);

  if (usePlayerOverlaySidePanel(size.width)) {
    final width = playerOverlayPanelWidth(size.width);
    return showGeneralDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: barrier,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, animation, secondary) {
        // Align (not a full-screen hit target) so taps beside the panel reach
        // the modal barrier. Sliding a Positioned.fill absorber with the panel
        // ate those taps and left Escape/click-outside unable to dismiss.
        return _OverlayEscapeDismiss(
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: width,
              height: MediaQuery.sizeOf(ctx).height,
              child: Material(
                color: AppColors.surface.withValues(alpha: 0.94),
                elevation: 12,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: builder(ctx),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondary, child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        );
      },
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    backgroundColor: AppColors.surface.withValues(alpha: 0.96),
    barrierColor: barrier,
    constraints: BoxConstraints(maxHeight: size.height * 0.5, maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => _OverlayEscapeDismiss(
      child: SizedBox(height: size.height * 0.5, child: builder(ctx)),
    ),
  );
}

/// Takes keyboard focus and handles Escape so desktop hotkeys / player keys
/// cannot swallow dismiss for this route.
class _OverlayEscapeDismiss extends StatelessWidget {
  const _OverlayEscapeDismiss({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).maybePop();
        },
      },
      child: Focus(autofocus: true, skipTraversal: true, child: child),
    );
  }
}

/// In-player settings: nested pages so the root list stays short.
class PlayerSettingsPanel extends StatefulWidget {
  const PlayerSettingsPanel({
    super.key,
    required this.item,
    required this.desktop,
    required this.hostContext,
    this.onLock,
    this.onCaptionSettings,
    this.onShortcuts,
  });

  final MediaItem item;
  final bool desktop;

  /// Player overlay context — still mounted after this sheet is popped.
  final BuildContext hostContext;
  final VoidCallback? onLock;
  final VoidCallback? onCaptionSettings;
  final VoidCallback? onShortcuts;

  @override
  State<PlayerSettingsPanel> createState() => _PlayerSettingsPanelState();
}

class _PlayerSettingsPanelState extends State<PlayerSettingsPanel> {
  PlayerSettingsPage _page = PlayerSettingsPage.root;
  bool _rememberLiveQuality = false;

  void _go(PlayerSettingsPage page) => setState(() => _page = page);

  void _close() => Navigator.of(context).pop();

  void _afterClose(void Function(BuildContext host) action) {
    _close();
    final host = widget.hostContext;
    if (!host.mounted) return;
    action(host);
  }

  String _title(BuildContext context) =>
      playerSettingsPageTitle(_page, context.l10n);

  String _audioLabel(AudioTrack t) {
    return TrackLanguage.pickerLabel(
      l10n: context.l10n,
      id: t.id,
      title: t.title,
      language: t.language,
    );
  }

  String _subLabel(SubtitleTrack t) {
    return TrackLanguage.pickerLabel(
      l10n: context.l10n,
      id: t.id,
      title: t.title,
      language: t.language,
    );
  }

  String _videoLabel(VideoTrack track) {
    final l10n = context.l10n;
    return playerVideoTrackLabel(
      id: track.id,
      autoLabel: l10n.auto,
      offLabel: l10n.off,
      trackNumber: l10n.trackNumber,
      height: track.h,
      bitrate: track.bitrate,
      title: track.title,
    );
  }

  VideoTrack _selectedVideo(PlaybackProvider playback) {
    final id = playback.selectedVideoTrackId;
    if (id == 'auto') return VideoTrack.auto();
    for (final track in playback.selectableVideoTracks) {
      if (track.id == id) return track;
    }
    return playback.track.video;
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    // Position ticks must not rebuild this overlay (it used to hitch pause /
    // stream-stats taps). Discrete session/settings identity only.
    context.select<PlaybackProvider, int>(
      (p) => Object.hash(
        p.videoAspectMode,
        p.deinterlaceMode,
        p.volumeBoostPercent.round(),
        p.hasSleepTimer,
        p.sleepDuration,
        p.item?.id,
        p.liveChannel?.id,
        p.mediaServerStreamQuality,
        p.hasSelectableAudio,
        p.hasSelectableSubtitles,
        p.hasSelectableVideo,
        p.engineRevision,
        p.canLiveDvr,
        p.currentProgram?.start,
      ),
    );
    final library = context.read<LibraryProvider>();
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.liveScrubMode,
        l.liveDbRevision,
        l.mediaServerStreamQuality,
        l.catalog.length,
      ),
    );
    final side = usePlayerOverlaySidePanel(MediaQuery.sizeOf(context).width);

    return PopScope(
      canPop: _page == PlayerSettingsPage.root,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _go(PlayerSettingsPage.root);
      },
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!side)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                children: [
                  if (_page != PlayerSettingsPage.root)
                    IconButton(
                      onPressed: () => _go(PlayerSettingsPage.root),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: AppColors.text,
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                    )
                  else
                    const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _title(context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _close,
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textMuted,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: switch (_page) {
                PlayerSettingsPage.root => _rootList(playback, library),
                PlayerSettingsPage.audio => _audioList(playback),
                PlayerSettingsPage.subs => _subsList(playback),
                PlayerSettingsPage.video => _videoList(playback),
                PlayerSettingsPage.quality => _qualityList(library, playback),
                PlayerSettingsPage.msQuality => _msQualityList(playback),
                PlayerSettingsPage.versions => _versionsList(library, playback),
                PlayerSettingsPage.speed => _speedList(playback),
                PlayerSettingsPage.sleep => _sleepList(playback),
                PlayerSettingsPage.scrub => _scrubList(library),
                PlayerSettingsPage.boost => _boostList(playback),
                PlayerSettingsPage.aspect => _aspectList(playback),
                PlayerSettingsPage.deinterlace => _deinterlaceList(playback),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _rootList(PlaybackProvider playback, LibraryProvider library) {
    final rows = <Widget>[];

    void addRow({
      required IconData icon,
      required String label,
      String? value,
      required VoidCallback onTap,
    }) {
      rows.add(
        _SettingsRow(icon: icon, label: label, value: value, onTap: onTap),
      );
    }

    if (playback.canPickMediaServerQuality) {
      final q = playback.mediaServerStreamQuality;
      addRow(
        icon: Icons.high_quality_outlined,
        label: context.l10n.streamQuality,
        value: q.localizedLabel(context.l10n),
        onTap: () => _go(PlayerSettingsPage.msQuality),
      );
    } else {
      final live = playback.liveChannel ?? playback.item;
      if (live != null && (live.isLive || live.kind == MediaKind.catchup)) {
        final channel = library.resolveLiveChannel(
          playback.liveChannel ?? live,
        );
        final variants = library.qualityVariantsFor(channel);
        if (variants.length > 1) {
          final quality =
              ChannelQuality.labelFor(channel) ?? context.l10n.defaultQuality;
          final source = library.sourceLabelFor(channel);
          addRow(
            icon: Icons.high_quality_outlined,
            label: context.l10n.streamQuality,
            value: '$quality · $source',
            onTap: () => _go(PlayerSettingsPage.quality),
          );
        }
      }
    }

    if (playback.hasSelectableVideo) {
      addRow(
        icon: Icons.hd_outlined,
        label: context.l10n.adaptiveQuality,
        value: _videoLabel(_selectedVideo(playback)),
        onTap: () => _go(PlayerSettingsPage.video),
      );
    }

    if (playback.hasSelectableAudio) {
      addRow(
        icon: Icons.audiotrack_rounded,
        label: context.l10n.audioTrack,
        value: _audioLabel(playback.track.audio),
        onTap: () => _go(PlayerSettingsPage.audio),
      );
    }

    addRow(
      icon: Icons.volume_up_rounded,
      label: context.l10n.volumeBoost,
      value: playback.hasVolumeBoost
          ? context.l10n.volumeBoostPercent(playback.volumeBoostPercent.round())
          : context.l10n.off,
      onTap: () => _go(PlayerSettingsPage.boost),
    );

    addRow(
      icon: Icons.aspect_ratio_rounded,
      label: context.l10n.videoAspect,
      value: playback.videoAspectMode.localizedLabel(context.l10n),
      onTap: () => _go(PlayerSettingsPage.aspect),
    );

    if (AppCapabilities.usesMediaKit) {
      addRow(
        icon: Icons.filter_frames_rounded,
        label: context.l10n.deinterlace,
        value: playback.deinterlaceMode.localizedLabel(context.l10n),
        onTap: () => _go(PlayerSettingsPage.deinterlace),
      );
    }

    rows.add(const _StreamStatsSettingsRow());

    if (playback.hasSelectableSubtitles) {
      addRow(
        icon: Icons.closed_caption_rounded,
        label: context.l10n.subtitles,
        value: _subLabel(playback.track.subtitle),
        onTap: () => _go(PlayerSettingsPage.subs),
      );
    }

    final item = playback.item;
    if (item != null && item.isEpisode) {
      final variants = library.playVariantsForEpisodeItem(item);
      if (variants.length > 1) {
        final current = variants.cast<EpisodePlayVariant?>().firstWhere(
          (v) => v?.playUrl == item.playUrl || v?.id == item.id,
          orElse: () => variants.first,
        );
        addRow(
          icon: Icons.layers_rounded,
          label: context.l10n.version,
          value:
              current?.displayLabel ?? context.l10n.nAvailable(variants.length),
          onTap: () => _go(PlayerSettingsPage.versions),
        );
      }
    } else if (playback.editionQualitySiblings.length > 1) {
      final q = item == null ? '' : VodGrouping.qualityKey(item).label;
      addRow(
        icon: Icons.high_quality_outlined,
        label: context.l10n.quality,
        value: q.isEmpty ? context.l10n.version : q,
        onTap: () => _go(PlayerSettingsPage.versions),
      );
    }

    final remaining = playback.sleepRemaining;
    addRow(
      icon: Icons.bedtime_outlined,
      label: context.l10n.sleepTimer,
      value: remaining == null
          ? context.l10n.sleepTimerOff
          : context.l10n.minutesLeft(
              (remaining.inSeconds / 60).ceil().clamp(1, 999),
            ),
      onTap: () => _go(PlayerSettingsPage.sleep),
    );

    final url =
        playback.currentPlayUrl ??
        playback.item?.playUrl ??
        widget.item.playUrl;
    if (ExternalPlayer.canOpenUrl(url)) {
      addRow(
        icon: Icons.open_in_new_rounded,
        label: context.l10n.externalPlayer,
        onTap: () => _afterClose((host) {
          unawaited(openCurrentInExternalPlayer(host));
        }),
      );
    }

    if (playback.canLiveDvr && playback.currentProgram != null) {
      addRow(
        icon: Icons.linear_scale_rounded,
        label: context.l10n.scrubber,
        value: library.liveScrubMode.label,
        onTap: () => _go(PlayerSettingsPage.scrub),
      );
    }

    final downloadRow = _downloadRow(playback, library);
    if (downloadRow != null) rows.add(downloadRow);

    if (widget.onLock != null) {
      addRow(
        icon: Icons.lock_outline_rounded,
        label: context.l10n.lockControls,
        onTap: () => _afterClose((_) => widget.onLock!()),
      );
    }

    if (playback.hasSelectableSubtitles && widget.onCaptionSettings != null) {
      final preset = context.watch<CaptionStyleProvider>().style.preset;
      addRow(
        icon: Icons.subtitles_outlined,
        label: context.l10n.captionStyle,
        value: preset == CaptionPreset.outline
            ? context.l10n.outline
            : preset.label,
        onTap: () => _afterClose((_) => widget.onCaptionSettings!()),
      );
    }

    if (widget.desktop && widget.onShortcuts != null) {
      addRow(
        icon: Icons.keyboard_rounded,
        label: context.l10n.keyboardShortcuts,
        value: '? / F1',
        onTap: () => _afterClose((_) => widget.onShortcuts!()),
      );
    }

    if (rows.isEmpty) {
      return Center(
        child: Text(
          context.l10n.noSettingsForStream,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: rows,
    );
  }

  Widget? _downloadRow(PlaybackProvider playback, LibraryProvider library) {
    final playing = playback.item ?? widget.item;
    final channel =
        playback.liveChannel ??
        (playing.isLive ? playing : library.liveChannelForCatchup(playing));
    final program =
        playback.currentProgram ??
        (playing.kind == MediaKind.catchup
            ? library.programForCatchup(playing)
            : null);

    if (channel != null &&
        program != null &&
        (library.liveSupportsCatchup(channel) || program.hasArchive)) {
      return _SettingsRow(
        icon: Icons.download_rounded,
        label: context.l10n.downloadForOffline,
        value: program.title,
        onTap: () => _afterClose((host) {
          unawaited(
            showDvrDownloadPadDialog(
              context: host,
              channel: library.resolveLiveChannel(channel),
              program: program,
            ),
          );
        }),
      );
    }
    if (channel != null && library.liveSupportsCatchup(channel)) {
      return _SettingsRow(
        icon: Icons.download_rounded,
        label: context.l10n.downloadForOffline,
        value: context.l10n.recordFromArchive,
        onTap: () => _afterClose((host) {
          unawaited(
            showCatchupRecordDialog(
              context: host,
              channel: library.resolveLiveChannel(channel),
              initialStart: playing.kind == MediaKind.catchup
                  ? LibraryProvider.catchupStartOf(playing)
                  : null,
              initialDurationMin: playing.kind == MediaKind.catchup
                  ? playing.duration?.inMinutes
                  : null,
              initialTitle: playing.kind == MediaKind.catchup
                  ? playing.title
                  : null,
            ),
          );
        }),
      );
    }
    if (isDownloadActionAvailable(playing)) {
      final task = library.downloadTaskFor(playing);
      final presentation = downloadStatusPresentation(
        task?.status,
        context.l10n,
        progress: task?.progress ?? 0,
      );
      return _SettingsRow(
        icon: presentation.icon,
        label: presentation.label,
        value: task?.statusDetail,
        onTap: () => _afterClose((host) {
          final status = task?.status;
          if (status == DownloadStatus.queued ||
              status == DownloadStatus.downloading) {
            host.push('/downloads');
            return;
          }
          if (status == DownloadStatus.completed) {
            final local = task?.asLocalItem();
            if (local != null) {
              host.push('/player', extra: local);
            }
            return;
          }
          unawaited(enqueueDownloadWithFeedback(host, library, playing));
        }),
      );
    }
    return null;
  }

  Widget _audioList(PlaybackProvider playback) {
    final tracks = playback.selectableAudioTracks;
    final current = playback.track.audio;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return _ChoiceRow(
          label: _audioLabel(track),
          selected: track.id == current.id,
          onTap: () async {
            await playback.setAudioTrack(track);
            if (mounted) _close();
          },
        );
      },
    );
  }

  Widget _subsList(PlaybackProvider playback) {
    final tracks = [SubtitleTrack.no(), ...playback.selectableSubtitleTracks];
    final current = playback.track.subtitle;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return _ChoiceRow(
          label: _subLabel(track),
          selected: track.id == current.id,
          onTap: () async {
            await playback.setSubtitleTrack(track);
            if (mounted) _close();
          },
        );
      },
    );
  }

  Widget _videoList(PlaybackProvider playback) {
    final tracks = [VideoTrack.auto(), ...playback.selectableVideoTracks];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            context.l10n.adaptiveQualityHelp,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ),
        for (final track in tracks)
          _ChoiceRow(
            label: _videoLabel(track),
            selected: playback.isVideoTrackSelected(track),
            onTap: () async {
              await playback.setVideoTrack(track);
              if (mounted) _close();
            },
          ),
      ],
    );
  }

  Widget _qualityList(LibraryProvider library, PlaybackProvider playback) {
    final live = playback.liveChannel ?? playback.item;
    if (live == null) return const SizedBox.shrink();
    final channel = library.resolveLiveChannel(live);
    final variants = library.qualityVariantsFor(channel);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            context.l10n.preferredQualityHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          dense: true,
          title: Text(context.l10n.rememberForThisChannel),
          value: _rememberLiveQuality,
          activeThumbColor: AppColors.accent,
          onChanged: (v) => setState(() => _rememberLiveQuality = v),
        ),
        for (final variant in variants)
          _ChoiceRow(
            label: variant.title,
            subtitle: ChannelQuality.detailLine(
              variant,
              sourceLabel: library.sourceLabelFor(variant),
            ),
            selected: variant.id == channel.id,
            onTap: () async {
              if (_rememberLiveQuality) {
                await library.setPreferredLiveQuality(variant);
              }
              await playback.switchLiveQuality(variant);
              if (mounted) _close();
            },
          ),
      ],
    );
  }

  Widget _msQualityList(PlaybackProvider playback) {
    final current = playback.mediaServerStreamQuality;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final q in MediaServerStreamQuality.values)
          _ChoiceRow(
            label: q.localizedLabel(context.l10n),
            subtitle: q.localizedSubtitle(context.l10n),
            selected: q == current,
            onTap: () async {
              await playback.reopenWithMediaServerQuality(q);
              if (mounted) _close();
            },
          ),
      ],
    );
  }

  Widget _versionsList(LibraryProvider library, PlaybackProvider playback) {
    final item = playback.item;
    if (item == null) return const SizedBox.shrink();
    if (!item.isEpisode) {
      final qualities = playback.editionQualitySiblings;
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final v in qualities)
            _ChoiceRow(
              label: [
                VodGrouping.qualityKey(v).label,
                VodGrouping.localeAvailabilityLabel(
                  audioLangs: VodGrouping.inferredAudioLanguages(v),
                  subtitleLangs: VodGrouping.inferredSubtitleLanguages(v),
                  preferredLangs: context
                      .read<LocaleController>()
                      .preferredContentLanguageCodes,
                ),
              ].where((e) => e.trim().isNotEmpty).join(' · '),
              selected: v.id == item.id,
              onTap: () async {
                await library.setPreferredVodVariant(v);
                await playback.switchEditionKeepingPosition(v);
                if (mounted) _close();
              },
            ),
        ],
      );
    }
    final variants = library.playVariantsForEpisodeItem(item);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final v in variants)
          _ChoiceRow(
            label: v.displayLabel,
            subtitle:
                v.subtitle != null &&
                    v.subtitle!.trim().isNotEmpty &&
                    !v.displayLabel.contains(v.subtitle!.trim())
                ? v.subtitle
                : null,
            selected: v.playUrl == item.playUrl || v.id == item.id,
            onTap: () async {
              final next = await library.switchEpisodeVariant(item, v);
              if (next == null || !mounted) return;
              await playback.open(next, expand: true);
              if (mounted) _close();
            },
          ),
      ],
    );
  }

  Widget _aspectList(PlaybackProvider playback) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final mode in VideoAspectMode.values)
          _ChoiceRow(
            label: mode.localizedLabel(context.l10n),
            selected: playback.videoAspectMode == mode,
            onTap: () {
              unawaited(playback.setVideoAspectMode(mode));
              _close();
            },
          ),
      ],
    );
  }

  Widget _deinterlaceList(PlaybackProvider playback) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final mode in VideoDeinterlaceMode.values)
          _ChoiceRow(
            label: mode.localizedLabel(context.l10n),
            subtitle: mode.localizedSubtitle(context.l10n),
            selected: playback.deinterlaceMode == mode,
            onTap: () {
              unawaited(playback.setDeinterlaceMode(mode));
              _close();
            },
          ),
      ],
    );
  }

  Widget _speedList(PlaybackProvider playback) {
    final current = playback.playbackRate;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final speed in kPlaybackSpeeds)
          _ChoiceRow(
            label: formatPlaybackRateLabel(speed),
            selected: (current - speed).abs() < 0.01,
            onTap: () {
              unawaited(playback.setPlaybackRate(speed));
              _close();
            },
          ),
      ],
    );
  }

  Widget _sleepList(PlaybackProvider playback) {
    final presets = <Duration?>[null, ...PlaybackProvider.sleepTimerPresets];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final preset in presets)
          _ChoiceRow(
            label: preset == null
                ? context.l10n.sleepTimerOff
                : context.l10n.sleepTimerMinutes(preset.inMinutes),
            selected: preset == null
                ? !playback.hasSleepTimer
                : playback.sleepDuration == preset,
            onTap: () {
              if (preset == null) {
                playback.clearSleepTimer();
              } else {
                playback.setSleepTimer(preset);
              }
              _close();
            },
          ),
      ],
    );
  }

  Widget _scrubList(LibraryProvider library) {
    final current = library.liveScrubMode;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _ChoiceRow(
          label: LiveScrubMode.timeline.localizedLabel(context.l10n),
          subtitle: LiveScrubMode.timeline.localizedSubtitle(context.l10n),
          selected: current == LiveScrubMode.timeline,
          onTap: () async {
            await library.setLiveScrubMode(LiveScrubMode.timeline);
            if (mounted) _close();
          },
        ),
        _ChoiceRow(
          label: LiveScrubMode.program.localizedLabel(context.l10n),
          subtitle: LiveScrubMode.program.localizedSubtitle(context.l10n),
          selected: current == LiveScrubMode.program,
          onTap: () async {
            await library.setLiveScrubMode(LiveScrubMode.program);
            if (mounted) _close();
          },
        ),
      ],
    );
  }

  Widget _boostList(PlaybackProvider playback) {
    final value = playback.volumeBoostPercent
        .clamp(PlaybackProvider.volumeBoostMin, PlaybackProvider.volumeBoostMax)
        .toDouble();
    final label = playback.hasVolumeBoost
        ? context.l10n.volumeBoostPercent(value.round())
        : context.l10n.off;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Text(
          context.l10n.volumeBoostHint,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Text(
              context.l10n.off,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                min: PlaybackProvider.volumeBoostMin,
                max: PlaybackProvider.volumeBoostMax,
                divisions: 20,
                value: value,
                label: label,
                onChanged: (next) {
                  unawaited(playback.setVolumeBoost(next));
                },
              ),
            ),
            Text(
              context.l10n.volumeBoostPercent(
                PlaybackProvider.volumeBoostMax.round(),
              ),
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _StreamStatsSettingsRow extends StatelessWidget {
  const _StreamStatsSettingsRow();

  @override
  Widget build(BuildContext context) {
    final on = context.select<PlaybackProvider, bool>((p) => p.showStreamStats);
    return _SettingsRow(
      icon: Icons.analytics_outlined,
      label: context.l10n.streamStats,
      value: on ? context.l10n.streamStatsOn : context.l10n.off,
      onTap: () =>
          unawaited(context.read<PlaybackProvider>().toggleStreamStats()),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, color: AppColors.text, size: 22),
      title: Row(
        children: [
          Flexible(
            flex: value == null ? 1 : 2,
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.text),
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 10),
            Flexible(
              flex: 3,
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ],
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AppColors.textMuted,
      ),
      onTap: onTap,
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: selected
          ? const Icon(Icons.check_rounded, color: AppColors.accent)
          : null,
      onTap: onTap,
    );
  }
}
