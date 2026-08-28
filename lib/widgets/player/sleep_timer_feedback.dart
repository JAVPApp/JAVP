import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:provider/provider.dart';

/// Shows a snackbar when the session sleep timer pauses playback.
///
/// Place once under a [ScaffoldMessenger] ancestor (player / TV overlay).
class SleepTimerFeedback extends StatelessWidget {
  const SleepTimerFeedback({super.key, this.child = const SizedBox.shrink()});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fired = context.select<PlaybackProvider, bool>(
      (p) => p.sleepTimerFired,
    );
    if (fired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final playback = context.read<PlaybackProvider>();
        if (!playback.sleepTimerFired) return;
        playback.acknowledgeSleepFired();
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.sleepTimerFired)),
        );
      });
    }
    return child;
  }
}
