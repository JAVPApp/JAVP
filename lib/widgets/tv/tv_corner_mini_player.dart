import 'package:flutter/material.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/services/tv/tv_mini_player_corner.dart';

/// Overlay host that slides the TV mini player off a focused tile it covers.
class TvCornerMiniPlayer extends StatefulWidget {
  const TvCornerMiniPlayer({
    super.key,
    required this.child,
    this.inset = AppLayout.tvOverscan,
  });

  final Widget child;
  final double inset;

  @override
  State<TvCornerMiniPlayer> createState() => _TvCornerMiniPlayerState();
}

class _TvCornerMiniPlayerState extends State<TvCornerMiniPlayer> {
  static const _focusPad = 16.0;
  static const _moveDuration = Duration(milliseconds: 280);

  final _pipKey = GlobalKey();
  TvMiniPlayerCorner _corner = TvMiniPlayerCorner.bottomRight;
  bool _relocateScheduled = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _relocateIfNeeded());
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted || _relocateScheduled) return;
    _relocateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _relocateScheduled = false;
      _relocateIfNeeded();
    });
  }

  bool _focusIsPip(BuildContext? focusContext) {
    if (focusContext == null) return false;
    return focusContext.findAncestorWidgetOfExactType<_TvMiniPlayerDodgeHost>() !=
        null;
  }

  void _relocateIfNeeded() {
    if (!mounted) return;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (_focusIsPip(focusContext)) return;

    final pipBox = _pipKey.currentContext?.findRenderObject() as RenderBox?;
    if (pipBox == null || !pipBox.hasSize || pipBox.size.isEmpty) return;

    final hostBox = context.findRenderObject() as RenderBox?;
    if (hostBox == null || !hostBox.hasSize || hostBox.size.isEmpty) return;

    final screen = hostBox.size;
    final pip = pipBox.size;
    var next = TvMiniPlayerCorner.bottomRight;
    if (focusContext != null) {
      final focusBox = focusContext.findRenderObject() as RenderBox?;
      if (focusBox != null && focusBox.hasSize && focusBox.attached) {
        final focusGlobal =
            focusBox.localToGlobal(Offset.zero) & focusBox.size;
        final hostOrigin = hostBox.localToGlobal(Offset.zero);
        final focusLocal = focusGlobal.shift(-hostOrigin).inflate(_focusPad);
        next = tvMiniPlayerCornerForFocus(
          focus: focusLocal,
          screen: screen,
          pip: pip,
          inset: widget.inset,
        );
      }
    }
    if (next == _corner) return;
    setState(() => _corner = next);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedAlign(
      alignment: tvMiniPlayerAlignment(_corner),
      duration: _moveDuration,
      curve: Curves.easeOutCubic,
      child: Padding(
        padding: EdgeInsets.all(widget.inset),
        child: KeyedSubtree(
          key: _pipKey,
          child: _TvMiniPlayerDodgeHost(child: widget.child),
        ),
      ),
    );
  }
}

class _TvMiniPlayerDodgeHost extends StatelessWidget {
  const _TvMiniPlayerDodgeHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
