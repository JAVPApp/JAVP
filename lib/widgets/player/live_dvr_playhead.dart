import 'package:flutter/material.dart';
import 'package:javp/theme/app_theme.dart';

/// 0…1 position of the live/DVR playhead, matching the phone scrubber.
///
/// Timeline mode maps the catchup window (oldest → live). Programme mode maps
/// the current EPG show (start → end); the live edge sits partway along that
/// bar while the show is still airing. Live without DVR uses wall-clock
/// progress through the current programme when known.
double livePlayheadProgress({
  required bool canLiveDvr,
  required bool atLiveEdge,
  required bool useProgramScrub,
  required double liveDvrProgress,
  double? liveProgramProgress,
  double? epgNowProgress,
  bool pinAtLive = false,
}) {
  if (pinAtLive) return 1;
  if (useProgramScrub) {
    return (liveProgramProgress ?? epgNowProgress ?? 0).clamp(0.0, 1.0);
  }
  if (canLiveDvr) {
    if (atLiveEdge) return 1;
    return liveDvrProgress.clamp(0.0, 1.0);
  }
  if (epgNowProgress != null) return epgNowProgress.clamp(0.0, 1.0);
  return 1;
}

/// `h:mm:ss` or `m:ss` — same clock as the phone DVR delay label.
String formatPlayheadDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '${d.inMinutes}:$s';
}

/// VOD overlay left clock: elapsed, or remaining as `-m:ss` / `-h:mm:ss`.
String formatVodLeftClock({
  required Duration position,
  required Duration duration,
  required bool showRemaining,
}) {
  if (!showRemaining) return formatPlayheadDuration(position);
  var remaining = duration - position;
  if (remaining.isNegative) remaining = Duration.zero;
  return '-${formatPlayheadDuration(remaining)}';
}

String formatPlayheadDelay(Duration d, {required String liveBadge}) {
  if (d.inSeconds <= 0) return liveBadge;
  return '-${formatPlayheadDuration(d)}';
}

/// Timeline-mode scrub label (`DVR · title` at live, else delay + clock).
String formatLiveDvrScrubLabel({
  required Duration delay,
  required String clock,
  String? programTitle,
  required String dvrScrubHint,
  required String liveBadge,
}) {
  if (delay.inSeconds <= 0) {
    return programTitle != null ? 'DVR · $programTitle' : dvrScrubHint;
  }
  final delayPart = formatPlayheadDelay(delay, liveBadge: liveBadge);
  if (programTitle == null) return '$delayPart ($clock)';
  return '$delayPart · $programTitle ($clock)';
}

/// Programme-mode scrub label (`LIVE · title · clock` at the live edge).
String formatLiveProgramScrubLabel({
  required bool atLive,
  required Duration liveDelay,
  required String programTitle,
  required String clock,
  required String liveBadge,
}) {
  if (atLive || liveDelay.inSeconds <= 0) {
    return '$liveBadge · $programTitle · $clock';
  }
  final delayPart = formatPlayheadDelay(liveDelay, liveBadge: liveBadge);
  return '$delayPart · $programTitle · $clock';
}

/// Track + circular thumb used by the phone player and TV live overlay.
class LiveDvrPlayheadTrack extends StatelessWidget {
  const LiveDvrPlayheadTrack({
    super.key,
    required this.progress,
    required this.color,
    this.liveEdge,
    this.showThumb = true,
    this.trackHeight = 6,
    this.thumbRadius = 8,
  });

  final double progress;
  final Color color;

  /// Programme-mode live edge (0…1 of the current show). Null in timeline mode.
  final double? liveEdge;
  final bool showThumb;
  final double trackHeight;
  final double thumbRadius;

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);
    return SizedBox(
      height: (thumbRadius * 2 + 8).clamp(trackHeight + 8, 36),
      child: CustomPaint(
        painter: LiveDvrPlayheadPainter(
          progress: clamped,
          color: color,
          liveEdge: liveEdge,
          showThumb: showThumb,
          trackHeight: trackHeight,
          thumbRadius: thumbRadius,
        ),
      ),
    );
  }
}

class LiveDvrPlayheadPainter extends CustomPainter {
  const LiveDvrPlayheadPainter({
    required this.progress,
    required this.color,
    this.liveEdge,
    required this.showThumb,
    required this.trackHeight,
    required this.thumbRadius,
  });

  final double progress;
  final Color color;
  final double? liveEdge;
  final bool showThumb;
  final double trackHeight;
  final double thumbRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = showThumb ? thumbRadius : 0.0;
    final trackWidth = (size.width - inset * 2).clamp(0.0, size.width);
    final trackTop = (size.height - trackHeight) / 2;
    final track = RRect.fromLTRBR(
      inset,
      trackTop,
      inset + trackWidth,
      trackTop + trackHeight,
      Radius.circular(trackHeight / 2),
    );
    canvas.drawRRect(track, Paint()..color = Colors.white24);

    final thumbX = inset + trackWidth * progress.clamp(0.0, 1.0);
    if (progress > 0 && trackWidth > 0) {
      final filled = RRect.fromLTRBR(
        inset,
        trackTop,
        thumbX.clamp(inset, inset + trackWidth),
        trackTop + trackHeight,
        Radius.circular(trackHeight / 2),
      );
      canvas.drawRRect(filled, Paint()..color = color);
    }

    final edge = liveEdge;
    if (edge != null && trackWidth > 0) {
      final edgeX = inset + trackWidth * edge.clamp(0.0, 1.0);
      final edgePaint = Paint()
        ..color = AppColors.live
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(edgeX, trackTop - 3),
        Offset(edgeX, trackTop + trackHeight + 3),
        edgePaint,
      );
    }

    if (!showThumb) return;
    final center = Offset(thumbX, size.height / 2);
    canvas.drawCircle(
      center,
      thumbRadius + 1.5,
      Paint()
        ..color = color.withValues(alpha: 0.9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawCircle(center, thumbRadius, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant LiveDvrPlayheadPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.liveEdge != liveEdge ||
        oldDelegate.showThumb != showThumb ||
        oldDelegate.trackHeight != trackHeight ||
        oldDelegate.thumbRadius != thumbRadius;
  }
}

/// Accent for the playhead: green while timeshifted, brand red at live.
Color livePlayheadColor({required bool canLiveDvr, required bool atLiveEdge}) {
  return canLiveDvr && !atLiveEdge ? AppColors.live : AppColors.accent;
}
