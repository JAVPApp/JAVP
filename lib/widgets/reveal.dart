import 'dart:async';

import 'package:flutter/material.dart';

import 'package:javp/theme/app_tokens.dart';

/// Fades and lifts its child in on first build, like the scroll reveals on
/// javp.app.
///
/// Two deliberate departures from the site: it runs at 200ms rather than
/// 700ms, and it is meant for section-level chrome — shelf headers, hero
/// blocks, empty states — not for individual list items. One ticker per
/// poster in a scrolling shelf is a frame-budget problem, and content that
/// animates as you scroll toward it makes browsing feel slower, not richer.
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.index = 0,
    this.offsetY = 12,
  });

  final Widget child;

  /// Position among siblings; each step delays the start by
  /// [AppMotion.revealStagger], up to [AppMotion.revealStaggerCap].
  final int index;

  /// How far the child travels upward, in logical pixels.
  final double offsetY;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _curve;
  Timer? _startTimer;
  bool _settled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settled || _controller != null) return;

    if (MediaQuery.disableAnimationsOf(context)) {
      _settled = true;
      return;
    }

    final controller = AnimationController(
      vsync: this,
      duration: AppMotion.reveal,
    );
    _curve = CurvedAnimation(parent: controller, curve: AppMotion.ease);
    controller.addStatusListener(_onStatus);
    _controller = controller;

    final steps = widget.index.clamp(0, AppMotion.revealStaggerCap);
    final delay = AppMotion.revealStagger * steps;
    if (delay == Duration.zero) {
      controller.forward();
    } else {
      _startTimer = Timer(delay, () {
        if (mounted) controller.forward();
      });
    }
  }

  /// Once the reveal is done, drop the opacity and transform layers entirely
  /// rather than leaving them wrapped around the subtree forever.
  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() => _settled = true);
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = _curve;
    if (_settled || curve == null) return widget.child;

    return AnimatedBuilder(
      animation: curve,
      child: widget.child,
      builder: (context, child) {
        final t = curve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * widget.offsetY),
            child: child,
          ),
        );
      },
    );
  }
}
