import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/cast/cast_ladder.dart';
import 'package:javp/services/cast/cast_mime.dart';
import 'package:javp/services/cast/cast_protocol.dart';
import 'package:javp/services/cast/cast_service.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/cast/cast_transport_extras.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/mini_player_bar.dart';
import 'package:javp/widgets/player/player_settings_panel.dart';
import 'package:provider/provider.dart';

/// Cast picker over the player (root overlay — video controls are a clipped
/// layer). Errors stay on that overlay instead of a SnackBar on the page under
/// the player. Discovery stays up until this route closes.
Future<void> showCastDeviceSheet(BuildContext host) async {
  final library = host.read<LibraryProvider>();
  final playback = host.read<PlaybackProvider>();
  final cast = library.cast;
  await cast.startDiscovery();
  if (cast.isCasting) unawaited(cast.refreshVolume());
  if (!host.mounted) {
    await cast.stopDiscovery();
    return;
  }

  var googlePicker = false;
  try {
    final result = await showPlayerOverlaySheet<String>(
      context: host,
      builder: (sheetContext) {
        return _CastPickerPanel(
          playback: playback,
          onGooglePicker: AppCapabilities.chromecast
              ? () {
                  googlePicker = true;
                  Navigator.of(sheetContext).pop();
                }
              : null,
        );
      },
    );

    if (googlePicker) {
      if (!host.mounted) return;
      if (playback.item == null) return;
      await playback.castCurrent();
      if (host.mounted && cast.isCasting) {
        await handOffPlayerToCastRemote(host);
      }
      await _finishCastConnect(host, cast, playback);
      return;
    }
    if (result == 'remote' && host.mounted) {
      await handOffPlayerToCastRemote(host);
      return;
    }
    if (result == 'preferred' && host.mounted) {
      final name = cast.preferredTarget?.name ?? '';
      if (name.isNotEmpty) {
        ScaffoldMessenger.of(
          host,
        ).showSnackBar(SnackBar(content: Text(host.l10n.castingTo(name))));
      }
      return;
    }
    if (result == 'connected' && host.mounted && cast.isCasting) {
      await handOffPlayerToCastRemote(host);
      await _finishCastConnect(host, cast, playback);
    }
  } finally {
    await cast.stopDiscovery();
  }
}

/// Root-navigator dialog so Cast errors sit on the player, not the shell.
Future<void> showCastErrorOnPlayer(
  BuildContext host,
  String err, {
  CastService? cast,
}) {
  return showDialog<void>(
    context: host,
    useRootNavigator: true,
    builder: (ctx) {
      final l10n = ctx.l10n;
      final kind = cast?.lastFailureKind;
      final title = kind == null || kind == CastFailureKind.connect
          ? null
          : l10n.contentCannotBeCastToThisDevice;
      final body = _castFailureBody(ctx, err, cast);
      return AlertDialog(
        backgroundColor: AppColors.surface,
        title: title == null ? null : Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.ok),
          ),
        ],
      );
    },
  );
}

String _castFailureBody(BuildContext context, String err, CastService? cast) {
  final l10n = context.l10n;
  final kind = cast?.lastFailureKind;
  final detail = switch (kind) {
    CastFailureKind.codecVideo => l10n.castCannotPlayVideoCodec,
    CastFailureKind.codecAudio => l10n.castCannotPlayAudioCodec,
    CastFailureKind.fetch => l10n.castCannotFetchStream,
    CastFailureKind.rejected => l10n.castReceiverRejected,
    CastFailureKind.connect || null => _castErrorLabel(context, err),
  };
  final tried = cast?.lastAttemptedModes ?? const [];
  if (tried.isEmpty || kind == CastFailureKind.connect || kind == null) {
    return detail;
  }
  final modes = tried
      .map(
        (m) => switch (m) {
          CastLoadMode.direct => l10n.castLoadModeDirect,
          CastLoadMode.proxy => l10n.castLoadModeProxy,
          CastLoadMode.serverTranscode => l10n.castLoadModeTranscode,
        },
      )
      .join(', ');
  return '$detail\n\n${l10n.castTriedModes(modes)}';
}

String _castErrorLabel(BuildContext context, String err) {
  if (err == kCastUnsupportedOnDevice) {
    return context.l10n.contentCannotBeCastToThisDevice;
  }
  return err;
}

Future<void> _finishCastConnect(
  BuildContext host,
  CastService cast,
  PlaybackProvider playback,
) async {
  final live = playback.item?.isLive == true;
  final err = await cast.waitForPlaybackOrError(live: live);
  if (err != null && host.mounted) {
    await showCastErrorOnPlayer(host, _castErrorLabel(host, err), cast: cast);
  }
}

class _CastPickerPanel extends StatefulWidget {
  const _CastPickerPanel({required this.playback, this.onGooglePicker});

  final PlaybackProvider playback;
  final VoidCallback? onGooglePicker;

  @override
  State<_CastPickerPanel> createState() => _CastPickerPanelState();
}

class _CastPickerPanelState extends State<_CastPickerPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _connect(CastTarget target) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final cast = context.read<LibraryProvider>().cast;
    if (widget.playback.item == null) {
      cast.setPreferredTarget(target);
      if (mounted) Navigator.of(context).pop('preferred');
      return;
    }
    await widget.playback.castCurrent(target: target);
    if (!mounted) return;
    if (cast.isCasting) {
      Navigator.of(context).pop('connected');
      return;
    }
    final err = cast.lastError;
    setState(() {
      _busy = false;
      _error = err == null ? null : _castFailureBody(context, err, cast);
    });
  }

  Future<void> _stop() async {
    await context.read<LibraryProvider>().cast.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cast = context.read<LibraryProvider>().cast;
    return SafeArea(
      child: ListenableBuilder(
        listenable: cast,
        builder: (context, _) {
          final l10n = context.l10n;
          final devices = cast.devices;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.castToDevice,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
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
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    if (cast.isCasting)
                      _CastSessionControls(
                        playback: widget.playback,
                        busy: _busy,
                        onOpenRemote: () => Navigator.of(context).pop('remote'),
                        onStop: () => unawaited(_stop()),
                      ),
                    if (cast.discovering && devices.isEmpty)
                      ListTile(
                        leading: const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        title: Text(l10n.searchingCastDevices),
                      ),
                    if (!cast.discovering &&
                        devices.isEmpty &&
                        widget.onGooglePicker == null)
                      ListTile(
                        leading: const Icon(Icons.tv_off_outlined),
                        title: Text(l10n.noCastDevicesFound),
                      ),
                    for (final device in devices)
                      ListTile(
                        leading: Icon(_iconFor(device.protocol)),
                        title: Text(device.name),
                        subtitle: Text(
                          _protocolLabel(context, device.protocol),
                        ),
                        selected: cast.activeTarget == device,
                        enabled: !_busy,
                        onTap: () => unawaited(_connect(device)),
                      ),
                    if (widget.onGooglePicker != null)
                      ListTile(
                        leading: const Icon(Icons.cast_rounded),
                        title: Text(l10n.googleCastPicker),
                        subtitle: Text(l10n.googleCast),
                        enabled: !_busy,
                        onTap: widget.onGooglePicker,
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static IconData _iconFor(CastProtocol protocol) {
    return switch (protocol) {
      CastProtocol.chromecast => Icons.cast_rounded,
      CastProtocol.dlna => Icons.tv_rounded,
      CastProtocol.airplay => Icons.airplay_rounded,
    };
  }

  static String _protocolLabel(BuildContext context, CastProtocol protocol) {
    final l10n = context.l10n;
    return switch (protocol) {
      CastProtocol.chromecast => l10n.googleCast,
      CastProtocol.dlna => l10n.dlna,
      CastProtocol.airplay => l10n.airPlay,
    };
  }
}

/// Play/pause, skip, and Chromecast volume while a session is up — same
/// idea as Google's expanded Cast dialog.
class _CastSessionControls extends StatelessWidget {
  const _CastSessionControls({
    required this.playback,
    required this.busy,
    required this.onOpenRemote,
    required this.onStop,
  });

  final PlaybackProvider playback;
  final bool busy;
  final VoidCallback onOpenRemote;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cast = context.read<LibraryProvider>().cast;
    final playing = context.select<PlaybackProvider, bool>((p) => p.playing);
    final buffering = context.select<PlaybackProvider, bool>(
      (p) => p.buffering,
    );
    final live = context.select<PlaybackProvider, bool>(
      (p) => p.item?.isLive == true,
    );
    final title = context.select<PlaybackProvider, String>((p) {
      final item = p.item;
      if (item == null) return l10n.nowPlaying;
      if (item.isLive) {
        return context.read<LibraryProvider>().liveOrCatchupDisplayTitle(item);
      }
      return item.title;
    });
    final art = context.select<PlaybackProvider, String?>(
      (p) => p.item?.artUrlFor(portrait: false) ?? p.item?.artUrl,
    );
    final chromecast = cast.activeProtocol == CastProtocol.chromecast;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: busy ? null : onOpenRemote,
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: ColoredBox(
                          color: AppColors.bgDeep,
                          child: JavpArt(
                            url: art,
                            fit: BoxFit.cover,
                            decodeWidth: 160,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(color: AppColors.text),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.castingTo(cast.deviceName ?? ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.accentHi,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!live)
                    IconButton(
                      tooltip: l10n.rewind10Seconds,
                      onPressed: busy
                          ? null
                          : () => unawaited(
                              playback.seekTo(
                                playback.position - const Duration(seconds: 10),
                              ),
                            ),
                      icon: const Icon(Icons.replay_10_rounded),
                    ),
                  IconButton.filled(
                    tooltip: playing ? l10n.pause : l10n.play,
                    onPressed: busy ? null : playback.togglePlayPause,
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                    ),
                    icon: buffering && !playing
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                  ),
                  if (!live)
                    IconButton(
                      tooltip: l10n.forward10Seconds,
                      onPressed: busy
                          ? null
                          : () => unawaited(
                              playback.seekTo(
                                playback.position + const Duration(seconds: 10),
                              ),
                            ),
                      icon: const Icon(Icons.forward_10_rounded),
                    ),
                ],
              ),
              CastTransportExtras(
                playback: playback,
                live: live,
                enabled: !busy,
              ),
              if (chromecast) _CastVolumeSlider(cast: cast, enabled: !busy),
              Row(
                children: [
                  TextButton(
                    onPressed: busy ? null : onStop,
                    child: Text(l10n.stopCasting),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: busy ? null : onOpenRemote,
                    child: Text(l10n.nowPlaying),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CastVolumeSlider extends StatefulWidget {
  const _CastVolumeSlider({required this.cast, required this.enabled});

  final CastService cast;
  final bool enabled;

  @override
  State<_CastVolumeSlider> createState() => _CastVolumeSliderState();
}

class _CastVolumeSliderState extends State<_CastVolumeSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.cast,
      builder: (context, _) {
        final value = _drag ?? widget.cast.remoteVolume.clamp(0.0, 1.0);
        final muted = value <= 0;
        return Row(
          children: [
            Icon(
              muted ? Icons.volume_off_rounded : Icons.volume_down_rounded,
              size: 20,
              color: AppColors.textMuted,
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  value: value,
                  onChanged: widget.enabled
                      ? (v) => setState(() => _drag = v)
                      : null,
                  onChangeEnd: widget.enabled
                      ? (v) {
                          setState(() => _drag = null);
                          unawaited(widget.cast.setRemoteVolume(v));
                        }
                      : null,
                  activeColor: AppColors.accent,
                  inactiveColor: AppColors.border,
                ),
              ),
            ),
            const Icon(
              Icons.volume_up_rounded,
              size: 20,
              color: AppColors.textMuted,
            ),
          ],
        );
      },
    );
  }
}
