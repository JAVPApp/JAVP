import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/playback_speeds.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/models/video_aspect_mode.dart';
import 'package:javp/models/video_deinterlace_mode.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/playback/track_language.dart';
import 'package:javp/services/platform/external_player.dart';
import 'package:javp/services/platform/external_player_actions.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/player/player_settings_page.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/compat/media_kit.dart';
import 'package:provider/provider.dart';

/// Remote-friendly player settings (audio / subs / quality / speed / versions).
///
/// Rendered as a right-side panel; nest sub-lists in-place so D-pad stays local.
class TvPlayerSettingsOverlay extends StatefulWidget {
  const TvPlayerSettingsOverlay({
    super.key,
    required this.onClose,
    this.allowSpeed = true,
  });

  final VoidCallback onClose;
  final bool allowSpeed;

  @override
  State<TvPlayerSettingsOverlay> createState() =>
      TvPlayerSettingsOverlayState();
}

class TvPlayerSettingsOverlayState extends State<TvPlayerSettingsOverlay> {
  PlayerSettingsPage _page = PlayerSettingsPage.root;
  final _scope = FocusScopeNode(debugLabel: 'tvPlayerSettings');

  @override
  void initState() {
    super.initState();
    _claimFocus();
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  /// Remote Back: pop a nested list. False when already on root so the
  /// parent can dismiss the overlay instead of leaving playback.
  bool handleBack() {
    if (_page == PlayerSettingsPage.root) return false;
    _openPage(PlayerSettingsPage.root);
    return true;
  }

  void _back() {
    if (handleBack()) return;
    widget.onClose();
  }

  void _openPage(PlayerSettingsPage page) {
    setState(() => _page = page);
    _claimFocus();
  }

  /// Steal focus from the live/VOD root [Focus] so autofocus on a nested
  /// list actually attaches. Without this, OK on Stream quality rebuilds
  /// the panel while the parent still holds focus and no row gets a ring.
  void _claimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scope.canRequestFocus) return;
      _scope.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final child = _scope.focusedChild;
        if (child != null && child != _scope && child.hasFocus) return;
        for (final node in _scope.traversalDescendants) {
          if (node.canRequestFocus && !node.skipTraversal) {
            node.requestFocus();
            return;
          }
        }
      });
    });
  }

  int _autofocusIndex({
    required int length,
    required int selectedIndex,
    int fallback = 0,
  }) {
    if (length <= 0) return 0;
    if (selectedIndex >= 0 && selectedIndex < length) return selectedIndex;
    return fallback.clamp(0, length - 1);
  }

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

  String _videoLabel(VideoTrack t) {
    final l10n = context.l10n;
    return playerVideoTrackLabel(
      id: t.id,
      autoLabel: l10n.auto,
      offLabel: l10n.off,
      trackNumber: l10n.trackNumber,
      height: t.h,
      bitrate: t.bitrate,
      title: t.title,
      compact: true,
    );
  }

  String _speedLabel(double rate) {
    final text = rate == rate.roundToDouble()
        ? rate.toStringAsFixed(0)
        : rate.toStringAsFixed(2);
    return '${text}x';
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    context.select<PlaybackProvider, int>(
      (p) => Object.hash(
        p.showStreamStats,
        p.videoAspectMode,
        p.deinterlaceMode,
        p.volumeBoostPercent.round(),
        p.hasSleepTimer,
        p.item?.id,
        p.liveChannel?.id,
        p.selectedVideoTrackId,
        p.track.audio,
        p.track.subtitle,
        p.track.video,
        p.engineRevision,
        p.playbackRate,
      ),
    );
    final library = context.read<LibraryProvider>();
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.liveScrubMode,
        l.liveDbRevision,
        l.mediaServerStreamQuality,
      ),
    );
    final item = playback.item;
    final live =
        playback.liveChannel ??
        (item != null && (item.isLive || item.kind == MediaKind.catchup)
            ? item
            : null);

    return FocusScope(
      node: _scope,
      autofocus: true,
      child: Material(
        color: const Color(0xF014161C),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        playerSettingsPageTitle(_page, context.l10n, tv: true),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    // Back already closes; keep this off the D-pad path so
                    // nested lists (quality, audio, …) can take focus.
                    GestureDetector(
                      onTap: _back,
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.close_rounded),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Expanded(
                child: switch (_page) {
                  PlayerSettingsPage.root => _rootList(
                    playback: playback,
                    library: library,
                    live: live,
                    item: item,
                  ),
                  PlayerSettingsPage.audio => _audioList(playback),
                  PlayerSettingsPage.subs => _subsList(playback),
                  PlayerSettingsPage.video => _videoList(playback),
                  PlayerSettingsPage.quality => _qualityList(library, live!),
                  PlayerSettingsPage.msQuality => _msQualityList(playback),
                  PlayerSettingsPage.versions => _versionsList(library, item!),
                  PlayerSettingsPage.speed => _speedList(playback),
                  PlayerSettingsPage.sleep => _sleepList(playback),
                  PlayerSettingsPage.scrub => _scrubList(library),
                  PlayerSettingsPage.boost => _boostList(playback),
                  PlayerSettingsPage.aspect => _aspectList(playback),
                  PlayerSettingsPage.deinterlace => _deinterlaceList(playback),
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  '← back   OK select',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rootList({
    required PlaybackProvider playback,
    required LibraryProvider library,
    required MediaItem? live,
    required MediaItem? item,
  }) {
    final rows = <Widget>[];
    var first = true;

    void addRow({
      required IconData icon,
      required String label,
      String? value,
      required VoidCallback onSelect,
    }) {
      rows.add(
        TvFocusable(
          autofocus: first,
          onSelect: onSelect,
          borderRadius: 10,
          child: ListTile(
            leading: Icon(icon, color: AppColors.accent),
            title: Text(label),
            subtitle: value == null || value.isEmpty
                ? null
                : Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right_rounded),
          ),
        ),
      );
      first = false;
    }

    if (widget.allowSpeed &&
        (item == null || !item.isLive || playback.canLiveDvr)) {
      final rate = playback.player.state.rate;
      addRow(
        icon: Icons.speed_rounded,
        label: context.l10n.playbackSpeed,
        value: _speedLabel(rate),
        onSelect: () => _openPage(PlayerSettingsPage.speed),
      );
    }

    addRow(
      icon: Icons.volume_up_rounded,
      label: context.l10n.volumeBoost,
      value: playback.hasVolumeBoost
          ? context.l10n.volumeBoostPercent(playback.volumeBoostPercent.round())
          : context.l10n.off,
      onSelect: () => _openPage(PlayerSettingsPage.boost),
    );

    addRow(
      icon: Icons.aspect_ratio_rounded,
      label: context.l10n.videoAspect,
      value: playback.videoAspectMode.localizedLabel(context.l10n),
      onSelect: () => _openPage(PlayerSettingsPage.aspect),
    );

    if (AppCapabilities.usesMediaKit) {
      addRow(
        icon: Icons.filter_frames_rounded,
        label: context.l10n.deinterlace,
        value: playback.deinterlaceMode.localizedLabel(context.l10n),
        onSelect: () => _openPage(PlayerSettingsPage.deinterlace),
      );
    }

    addRow(
      icon: Icons.analytics_outlined,
      label: context.l10n.streamStats,
      value: playback.showStreamStats
          ? context.l10n.streamStatsOn
          : context.l10n.off,
      onSelect: () => unawaited(playback.toggleStreamStats()),
    );

    if (playback.canLiveDvr) {
      addRow(
        icon: Icons.tune_rounded,
        label: context.l10n.liveScrubber,
        value: library.liveScrubMode.localizedLabel(context.l10n),
        onSelect: () => _openPage(PlayerSettingsPage.scrub),
      );
    }

    final sleepLeft = playback.sleepRemaining;
    addRow(
      icon: Icons.bedtime_outlined,
      label: context.l10n.sleepTimer,
      value: sleepLeft == null
          ? context.l10n.sleepTimerOff
          : context.l10n.minutesLeft(
              (sleepLeft.inSeconds / 60).ceil().clamp(1, 999),
            ),
      onSelect: () => _openPage(PlayerSettingsPage.sleep),
    );

    final externalUrl = playback.currentPlayUrl ?? item?.playUrl;
    if (ExternalPlayer.canOpenUrl(externalUrl)) {
      addRow(
        icon: Icons.open_in_new_rounded,
        label: context.l10n.externalPlayer,
        onSelect: () async {
          widget.onClose();
          await openCurrentInExternalPlayer(context);
        },
      );
    }

    if (playback.hasSelectableAudio) {
      addRow(
        icon: Icons.audiotrack_rounded,
        label: context.l10n.audioTrack,
        value: _audioLabel(playback.track.audio),
        onSelect: () => _openPage(PlayerSettingsPage.audio),
      );
    }

    if (playback.hasSelectableSubtitles) {
      addRow(
        icon: Icons.closed_caption_rounded,
        label: context.l10n.subtitles,
        value: _subLabel(playback.track.subtitle),
        onSelect: () => _openPage(PlayerSettingsPage.subs),
      );
    }

    if (playback.canPickMediaServerQuality) {
      final q = playback.mediaServerStreamQuality;
      addRow(
        icon: Icons.high_quality_outlined,
        label: context.l10n.streamQuality,
        value: q.localizedLabel(context.l10n),
        onSelect: () => _openPage(PlayerSettingsPage.msQuality),
      );
    } else if (live != null &&
        (live.isLive || live.kind == MediaKind.catchup)) {
      final channel = library.resolveLiveChannel(playback.liveChannel ?? live);
      final variants = library.qualityVariantsFor(channel);
      if (variants.length > 1) {
        final quality =
            ChannelQuality.labelFor(channel) ?? context.l10n.defaultQuality;
        addRow(
          icon: Icons.high_quality_outlined,
          label: context.l10n.streamQuality,
          value: '$quality · ${library.sourceLabelFor(channel)}',
          onSelect: () => _openPage(PlayerSettingsPage.quality),
        );
      }
    }

    if (playback.hasSelectableVideo) {
      final selectedId = playback.selectedVideoTrackId;
      final selectedTrack = selectedId == 'auto'
          ? VideoTrack.auto()
          : playback.selectableVideoTracks.cast<VideoTrack?>().firstWhere(
              (t) => t?.id == selectedId,
              orElse: () => null,
            );
      addRow(
        icon: Icons.hd_outlined,
        label: context.l10n.adaptiveQuality,
        value: _videoLabel(selectedTrack ?? VideoTrack.auto()),
        onSelect: () => _openPage(PlayerSettingsPage.video),
      );
    }

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
          onSelect: () => _openPage(PlayerSettingsPage.versions),
        );
      }
    } else if (playback.editionQualitySiblings.length > 1) {
      final q = item == null ? '' : VodGrouping.qualityKey(item).label;
      addRow(
        icon: Icons.high_quality_outlined,
        label: context.l10n.quality,
        value: q.isEmpty ? context.l10n.version : q,
        onSelect: () => _openPage(PlayerSettingsPage.versions),
      );
    }

    addRow(
      icon: Icons.text_fields_rounded,
      label: context.l10n.captionStyle,
      value: context.l10n.open,
      onSelect: () {
        widget.onClose();
        context.push('/captions');
      },
    );

    if (rows.isEmpty) {
      return Center(
        child: Text(
          context.l10n.noSettingsForStream,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: rows,
    );
  }

  Widget _audioList(PlaybackProvider playback) {
    final tracks = playback.selectableAudioTracks;
    final current = playback.track.audio;
    final focusIndex = _autofocusIndex(
      length: tracks.length,
      selectedIndex: tracks.indexWhere((t) => t.id == current.id),
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final selected = track.id == current.id;
        return TvFocusable(
          autofocus: index == focusIndex,
          onSelect: () async {
            await playback.setAudioTrack(track);
            if (mounted) widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            title: Text(_audioLabel(track)),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }

  Widget _subsList(PlaybackProvider playback) {
    final tracks = [SubtitleTrack.no(), ...playback.selectableSubtitleTracks];
    final current = playback.track.subtitle;
    final focusIndex = _autofocusIndex(
      length: tracks.length,
      selectedIndex: tracks.indexWhere((t) => t.id == current.id),
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final selected = track.id == current.id;
        return TvFocusable(
          autofocus: index == focusIndex,
          onSelect: () async {
            await playback.setSubtitleTrack(track);
            if (mounted) widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            title: Text(_subLabel(track)),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }

  Widget _videoList(PlaybackProvider playback) {
    final tracks = [VideoTrack.auto(), ...playback.selectableVideoTracks];
    final focusIndex = _autofocusIndex(
      length: tracks.length,
      selectedIndex: tracks.indexWhere(playback.isVideoTrackSelected),
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final selected = playback.isVideoTrackSelected(track);
        return TvFocusable(
          autofocus: index == focusIndex,
          onSelect: () async {
            await playback.setVideoTrack(track);
            if (mounted) widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            title: Text(_videoLabel(track)),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }

  Widget _qualityList(LibraryProvider library, MediaItem live) {
    final channel = library.resolveLiveChannel(live);
    final variants = library.qualityVariantsFor(channel);
    final focusIndex = _autofocusIndex(
      length: variants.length,
      selectedIndex: variants.indexWhere((v) => v.id == channel.id),
    );
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (var index = 0; index < variants.length; index++)
          TvFocusable(
            autofocus: index == focusIndex,
            onSelect: () async {
              await context.read<PlaybackProvider>().switchLiveQuality(
                variants[index],
              );
              if (mounted) widget.onClose();
            },
            borderRadius: 10,
            child: ListTile(
              title: Text(variants[index].title),
              subtitle: Text(
                ChannelQuality.detailLine(
                  variants[index],
                  sourceLabel: library.sourceLabelFor(variants[index]),
                ),
              ),
              trailing: variants[index].id == channel.id
                  ? const Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _msQualityList(PlaybackProvider playback) {
    final qualities = MediaServerStreamQuality.values;
    final current = playback.mediaServerStreamQuality;
    final focusIndex = _autofocusIndex(
      length: qualities.length,
      selectedIndex: qualities.indexOf(current),
    );
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (var index = 0; index < qualities.length; index++)
          TvFocusable(
            autofocus: index == focusIndex,
            onSelect: () async {
              await playback.reopenWithMediaServerQuality(qualities[index]);
              if (mounted) widget.onClose();
            },
            borderRadius: 10,
            child: ListTile(
              title: Text(qualities[index].localizedLabel(context.l10n)),
              subtitle: Text(qualities[index].localizedSubtitle(context.l10n)),
              trailing: qualities[index] == current
                  ? const Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _versionsList(LibraryProvider library, MediaItem item) {
    if (!item.isEpisode) {
      final playback = context.read<PlaybackProvider>();
      final qualities = playback.editionQualitySiblings;
      final prefs = context
          .read<LocaleController>()
          .preferredContentLanguageCodes;
      final focusIndex = _autofocusIndex(
        length: qualities.length,
        selectedIndex: qualities.indexWhere((v) => v.id == item.id),
      );
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: qualities.length,
        itemBuilder: (context, index) {
          final v = qualities[index];
          final selected = v.id == item.id;
          final label = [
            VodGrouping.qualityKey(v).label,
            VodGrouping.localeAvailabilityLabel(
              audioLangs: VodGrouping.inferredAudioLanguages(v),
              subtitleLangs: VodGrouping.inferredSubtitleLanguages(v),
              preferredLangs: prefs,
            ),
          ].where((e) => e.trim().isNotEmpty).join(' · ');
          return TvFocusable(
            autofocus: index == focusIndex,
            onSelect: () async {
              await library.setPreferredVodVariant(v);
              await playback.switchEditionKeepingPosition(v);
              if (mounted) widget.onClose();
            },
            borderRadius: 10,
            child: ListTile(
              title: Text(label.isEmpty ? v.title : label, maxLines: 2),
              trailing: selected
                  ? const Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
            ),
          );
        },
      );
    }
    final variants = library.playVariantsForEpisodeItem(item);
    final focusIndex = _autofocusIndex(
      length: variants.length,
      selectedIndex: variants.indexWhere(
        (v) => v.playUrl == item.playUrl || v.id == item.id,
      ),
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: variants.length,
      itemBuilder: (context, index) {
        final v = variants[index];
        final selected = v.playUrl == item.playUrl || v.id == item.id;
        return TvFocusable(
          autofocus: index == focusIndex,
          onSelect: () async {
            final playback = context.read<PlaybackProvider>();
            final next = await library.switchEpisodeVariant(item, v);
            if (next == null || !mounted) return;
            await playback.open(next, expand: true);
            if (mounted) widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            title: Text(v.displayLabel, maxLines: 2),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }

  Widget _speedList(PlaybackProvider playback) {
    const speeds = kPlaybackSpeeds;
    final current = playback.player.state.rate;
    final selectedIndex = speeds.indexWhere((s) => (current - s).abs() < 0.01);
    final focusIndex = _autofocusIndex(
      length: speeds.length,
      selectedIndex: selectedIndex,
      fallback: 2,
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: speeds.length,
      itemBuilder: (context, index) {
        final speed = speeds[index];
        final selected = (current - speed).abs() < 0.01;
        return TvFocusable(
          autofocus: index == focusIndex,
          onSelect: () async {
            await playback.player.setRate(speed);
            if (mounted) widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            title: Text(_speedLabel(speed)),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }

  Widget _aspectList(PlaybackProvider playback) {
    final modes = VideoAspectMode.values;
    final focusIndex = _autofocusIndex(
      length: modes.length,
      selectedIndex: modes.indexOf(playback.videoAspectMode),
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: modes.length,
      itemBuilder: (context, index) {
        final mode = modes[index];
        final selected = playback.videoAspectMode == mode;
        return TvFocusable(
          autofocus: index == focusIndex,
          onSelect: () {
            unawaited(playback.setVideoAspectMode(mode));
            widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            title: Text(mode.localizedLabel(context.l10n)),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }

  Widget _deinterlaceList(PlaybackProvider playback) {
    final modes = VideoDeinterlaceMode.values;
    final focusIndex = _autofocusIndex(
      length: modes.length,
      selectedIndex: modes.indexOf(playback.deinterlaceMode),
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: modes.length,
      itemBuilder: (context, index) {
        final mode = modes[index];
        final selected = playback.deinterlaceMode == mode;
        return TvFocusable(
          autofocus: index == focusIndex,
          onSelect: () {
            unawaited(playback.setDeinterlaceMode(mode));
            widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            title: Text(mode.localizedLabel(context.l10n)),
            subtitle: Text(mode.localizedSubtitle(context.l10n)),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }

  Widget _sleepList(PlaybackProvider playback) {
    final presets = <Duration?>[null, ...PlaybackProvider.sleepTimerPresets];
    final selectedIndex = presets.indexWhere((preset) {
      if (preset == null) return !playback.hasSleepTimer;
      return playback.sleepDuration == preset;
    });
    final focusIndex = _autofocusIndex(
      length: presets.length,
      selectedIndex: selectedIndex,
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: presets.length,
      itemBuilder: (context, index) {
        final preset = presets[index];
        final selected = preset == null
            ? !playback.hasSleepTimer
            : playback.sleepDuration == preset;
        final label = preset == null
            ? context.l10n.sleepTimerOff
            : context.l10n.sleepTimerMinutes(preset.inMinutes);
        return TvFocusable(
          autofocus: index == focusIndex,
          onSelect: () {
            if (preset == null) {
              playback.clearSleepTimer();
            } else {
              playback.setSleepTimer(preset);
            }
            widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            title: Text(label),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }

  Widget _scrubList(LibraryProvider library) {
    final current = library.liveScrubMode;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final mode in LiveScrubMode.values)
          TvFocusable(
            autofocus: mode == current,
            onSelect: () async {
              await library.setLiveScrubMode(mode);
              if (mounted) widget.onClose();
            },
            borderRadius: 10,
            child: ListTile(
              title: Text(mode.localizedLabel(context.l10n)),
              trailing: mode == current
                  ? const Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _boostList(PlaybackProvider playback) {
    final current = playback.volumeBoostPercent;
    final presets = PlaybackProvider.volumeBoostPresets;
    var closest = presets.first;
    var best = (current - closest).abs();
    for (final preset in presets) {
      final delta = (current - preset).abs();
      if (delta < best) {
        best = delta;
        closest = preset;
      }
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Text(
            context.l10n.volumeBoostHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ),
        for (final preset in presets)
          TvFocusable(
            autofocus: preset == closest,
            onSelect: () {
              unawaited(playback.setVolumeBoost(preset));
            },
            borderRadius: 10,
            child: ListTile(
              title: Text(
                preset <= PlaybackProvider.volumeBoostMin
                    ? context.l10n.off
                    : context.l10n.volumeBoostPercent(preset.round()),
              ),
              trailing: (current - preset).abs() < 0.5
                  ? const Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// Side panel to pick another episode while watching.
class TvEpisodePickerOverlay extends StatefulWidget {
  const TvEpisodePickerOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<TvEpisodePickerOverlay> createState() => _TvEpisodePickerOverlayState();
}

class _TvEpisodePickerOverlayState extends State<TvEpisodePickerOverlay> {
  static const _episodeExtent = 76.0;

  SeriesInfo? _info;
  int? _seasonNumber;
  String? _error;
  bool _loading = true;
  final _episodeScroll = ScrollController();
  int _autofocusEpisodeIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _episodeScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final playback = context.read<PlaybackProvider>();
    final library = context.read<LibraryProvider>();
    final item = playback.item;
    if (item == null || !item.isEpisode) {
      setState(() {
        _loading = false;
        _error = 'Not an episode';
      });
      return;
    }
    final series =
        library.seriesForEpisode(item) ?? library.seriesShellForEpisode(item);
    if (series == null) {
      setState(() {
        _loading = false;
        _error = 'Series not found';
      });
      return;
    }
    try {
      final info = await library.loadSeriesInfo(series);
      if (!mounted) return;
      final seasonNumber =
          item.seasonNumber ??
          (info.seasons.isNotEmpty ? info.seasons.first.seasonNumber : null);
      final season = info.seasons.cast<SeriesSeason?>().firstWhere(
        (s) => s?.seasonNumber == seasonNumber,
        orElse: () => info.seasons.isEmpty ? null : info.seasons.first,
      );
      final episodes = season?.episodes ?? const <SeriesEpisode>[];
      var focusIndex = 0;
      for (var i = 0; i < episodes.length; i++) {
        final ep = episodes[i];
        if (ep.seasonNumber == item.seasonNumber &&
            ep.episodeNum == item.episodeNumber) {
          focusIndex = i;
          break;
        }
      }
      setState(() {
        _info = info;
        _seasonNumber = seasonNumber;
        _autofocusEpisodeIndex = focusIndex;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_episodeScroll.hasClients || episodes.isEmpty) return;
        final max = _episodeScroll.position.maxScrollExtent;
        final offset = (focusIndex * _episodeExtent).clamp(0.0, max);
        _episodeScroll.jumpTo(offset);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackProvider>();
    final current = playback.item;

    return Material(
      color: const Color(0xE60B0D12),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.episodes,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  TvFocusable(
                    onSelect: widget.onClose,
                    borderRadius: 20,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
            if (_info != null && _info!.seasons.length > 1)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final season in _info!.seasons)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TvFocusable(
                          onSelect: () => setState(
                            () => _seasonNumber = season.seasonNumber,
                          ),
                          borderRadius: 20,
                          child: Chip(
                            label: Text(season.name),
                            backgroundColor:
                                season.seasonNumber == _seasonNumber
                                ? AppColors.accentSoft
                                : AppColors.surfaceHigh,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    )
                  : _episodeList(current),
            ),
          ],
        ),
      ),
    );
  }

  Widget _episodeList(MediaItem? current) {
    final info = _info;
    if (info == null || current == null) return const SizedBox.shrink();
    final season = info.seasons.cast<SeriesSeason?>().firstWhere(
      (s) => s?.seasonNumber == _seasonNumber,
      orElse: () => info.seasons.isEmpty ? null : info.seasons.first,
    );
    final episodes = season?.episodes ?? const <SeriesEpisode>[];
    if (episodes.isEmpty) {
      return Center(
        child: Text(
          context.l10n.noEpisodesFound,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      );
    }
    final library = context.read<LibraryProvider>();
    final series =
        library.seriesForEpisode(current) ??
        library.seriesShellForEpisode(current);
    final sameSeasonAsPlaying = current.seasonNumber == _seasonNumber;
    final autofocusIndex = sameSeasonAsPlaying
        ? _autofocusEpisodeIndex.clamp(0, episodes.length - 1)
        : 0;

    return ListView.builder(
      controller: _episodeScroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemExtent: _episodeExtent,
      itemCount: episodes.length,
      itemBuilder: (context, index) {
        final ep = episodes[index];
        final selected =
            current.seasonNumber == ep.seasonNumber &&
            current.episodeNumber == ep.episodeNum;
        final title = ep.title.trim().isEmpty
            ? context.l10n.episodeNumber(ep.episodeNum)
            : ep.title.trim();
        return TvFocusable(
          // Only one autofocus target — the playing episode when in its season.
          autofocus: index == autofocusIndex,
          onSelect: () async {
            if (series == null) return;
            final playable = library.episodeMediaItem(
              series: series,
              episode: ep,
            );
            if (playable == null) return;
            await context.read<PlaybackProvider>().open(playable, expand: true);
            if (mounted) widget.onClose();
          },
          borderRadius: 10,
          child: ListTile(
            leading: Text(
              '${ep.episodeNum}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: selected ? AppColors.accent : AppColors.textMuted,
              ),
            ),
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(ep.shortLabel),
            trailing: selected
                ? const Icon(Icons.play_arrow_rounded, color: AppColors.accent)
                : null,
          ),
        );
      },
    );
  }
}

/// Live EPG nearby programmes for catchup / jump.
class TvEpgOverlay extends StatefulWidget {
  const TvEpgOverlay({super.key, required this.channel, required this.onClose});

  final MediaItem channel;
  final VoidCallback onClose;

  @override
  State<TvEpgOverlay> createState() => _TvEpgOverlayState();
}

class _TvEpgOverlayState extends State<TvEpgOverlay> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        context.read<LibraryProvider>().fetchChannelGuide(widget.channel),
      );
    });
  }

  String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    final now = DateTime.now();
    final programs = library.nearbyPrograms(
      widget.channel,
      at: now,
      before: widget.channel.supportsCatchup
          ? (widget.channel.catchupDays.clamp(1, 14) * 6).clamp(12, 48).toInt()
          : 8,
      after: 4,
    );
    final loading = library.isGuideLoading(widget.channel);

    return Material(
      color: const Color(0xF014161C),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.guide,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          library.officialLiveTitle(widget.channel),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  TvFocusable(
                    onSelect: widget.onClose,
                    borderRadius: 20,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: programs.isEmpty
                  ? Center(
                      child: Text(
                        loading
                            ? 'Loading guide…'
                            : 'No guide entries for this channel yet.',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: programs.length,
                      itemBuilder: (context, index) {
                        final p = programs[index];
                        final isNow =
                            !p.start.isAfter(now) && p.end.isAfter(now);
                        final isPast = p.end.isBefore(now);
                        final canCatchup =
                            isPast &&
                            (widget.channel.supportsCatchup || p.hasArchive);
                        return TvFocusable(
                          autofocus: isNow || index == 0,
                          onSelect: () async {
                            if (isNow) {
                              await playback.jumpToLive();
                              if (mounted) widget.onClose();
                              return;
                            }
                            if (!canCatchup) return;
                            await playback.seekLiveDvrTo(p.start);
                            if (mounted) widget.onClose();
                          },
                          borderRadius: 10,
                          child: ListTile(
                            selected: isNow,
                            title: Text(
                              p.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${_hhmm(p.start)}–${_hhmm(p.end)}'
                              '${isNow
                                  ? ' · ${context.l10n.now}'
                                  : canCatchup
                                  ? ' · ${context.l10n.catchup}'
                                  : ''}',
                            ),
                            trailing: isNow
                                ? const Icon(
                                    Icons.live_tv_rounded,
                                    color: AppColors.accent,
                                  )
                                : canCatchup
                                ? const Icon(
                                    Icons.replay_rounded,
                                    color: AppColors.accent,
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
