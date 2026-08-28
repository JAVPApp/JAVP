import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/models/stream_stats_snapshot.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/compat/media_kit.dart';

/// Monospace card with resolution / codec / fps / bitrate / buffer.
class StreamStatsOverlay extends StatefulWidget {
  const StreamStatsOverlay({super.key, required this.player});

  final Player player;

  @override
  State<StreamStatsOverlay> createState() => _StreamStatsOverlayState();
}

class _StreamStatsOverlayState extends State<StreamStatsOverlay> {
  Timer? _timer;
  StreamStatsSnapshot _stats = const StreamStatsSnapshot();

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void didUpdateWidget(covariant StreamStatsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    final next = StreamStatsSnapshot.fromPlayer(widget.player);
    if (!mounted) return;
    setState(() => _stats = next);
  }

  @override
  Widget build(BuildContext context) {
    final lines = _stats.lines;
    if (lines.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCC0B0C0F),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 12,
              height: 1.35,
              fontFeatures: [FontFeature.tabularFigures()],
              fontFamily: 'monospace',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [for (final line in lines) Text(line)],
            ),
          ),
        ),
      ),
    );
  }
}
