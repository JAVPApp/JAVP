import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/compat/window_manager.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// Chrome-style overlay for the desktop mini-window PiP.
///
/// Native Android PiP draws system controls; this window is still our HWND,
/// so we hide the player chrome and paint a hover bar (play, restore, close)
/// plus drag-to-move.
class DesktopPipChrome extends StatefulWidget {
  const DesktopPipChrome({super.key, this.onClose});

  /// Leave playback entirely (stop + pop `/player`). Defaults to [stop] only.
  final Future<void> Function()? onClose;

  @override
  State<DesktopPipChrome> createState() => _DesktopPipChromeState();
}

class _DesktopPipChromeState extends State<DesktopPipChrome> {
  final _focus = FocusNode(debugLabel: 'desktopPip');
  bool _hovered = false;
  bool _chrome = true;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _armHide({required bool playing}) {
    _hide?.cancel();
    if (!_hovered && playing) {
      _hide = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _chrome = false);
      });
    }
  }

  void _reveal({required bool playing}) {
    if (!_chrome) setState(() => _chrome = true);
    _armHide(playing: playing);
  }

  Future<void> _restore() async {
    if (!mounted) return;
    await context.read<PlaybackProvider>().expand();
  }

  Future<void> _close() async {
    if (!mounted) return;
    final onClose = widget.onClose;
    if (onClose != null) {
      await onClose();
      return;
    }
    await context.read<PlaybackProvider>().stop();
  }

  Future<void> _togglePlay() async {
    await context.read<PlaybackProvider>().togglePlayPause();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.keyP ||
        key == LogicalKeyboardKey.f11) {
      unawaited(_restore());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyK ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final playing = context.select<PlaybackProvider, bool>((p) => p.playing);
    final l10n = context.l10n;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        onEnter: (_) {
          _hovered = true;
          _hide?.cancel();
          _reveal(playing: playing);
        },
        onHover: (_) => _reveal(playing: playing),
        onExit: (_) {
          _hovered = false;
          _armHide(playing: playing);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _restore,
              onTap: () {
                _reveal(playing: playing);
                unawaited(_togglePlay());
              },
              onPanStart: (_) {
                if (isDesktopPlatform) {
                  unawaited(windowManager.startDragging());
                }
              },
              child: const SizedBox.expand(),
            ),
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _chrome ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x99000000),
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0x99000000),
                      ],
                      stops: [0, 0.28, 0.62, 1],
                    ),
                  ),
                ),
              ),
            ),
            if (_chrome) ...[
              Positioned(
                top: 4,
                left: 4,
                right: 4,
                child: Row(
                  children: [
                    _PipIconButton(
                      tooltip: l10n.exitPictureInPicture,
                      icon: Icons.picture_in_picture_alt_rounded,
                      onPressed: _restore,
                    ),
                    const Spacer(),
                    _PipIconButton(
                      tooltip: l10n.close,
                      icon: Icons.close_rounded,
                      onPressed: _close,
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PipIconButton(
                    tooltip: playing ? l10n.pause : l10n.play,
                    icon: playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    onPressed: _togglePlay,
                    large: true,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PipIconButton extends StatelessWidget {
  const _PipIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.large = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: large ? 36 : 22,
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: large ? Colors.black45 : Colors.transparent,
        hoverColor: AppColors.surfaceHigh.withValues(alpha: 0.35),
        minimumSize: Size(large ? 52 : 36, large ? 52 : 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon),
    );
  }
}
