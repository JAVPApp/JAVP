import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/diagnostics/library_work_debug.dart';
import 'package:provider/provider.dart';

/// Debug-only sampler: writes [workdbg] while a named library job is latched.
///
/// No on-screen HUD — Dev / `flutter run` must stay usable. Stall logs still
/// include [LibraryProvider.debugWorkSnapshot].
class LibraryWorkDebugOverlay extends StatefulWidget {
  const LibraryWorkDebugOverlay({super.key, required this.child});

  final Widget child;

  static bool get enabled => kDebugMode;

  @override
  State<LibraryWorkDebugOverlay> createState() =>
      _LibraryWorkDebugOverlayState();
}

class _LibraryWorkDebugOverlayState extends State<LibraryWorkDebugOverlay> {
  Timer? _timer;
  LibraryWorkDebugSnapshot? _snap;
  DateTime _lastHeartbeat = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    final snap = context.read<LibraryProvider>().debugWorkSnapshot();
    if (!snap.hasLatchedJob) {
      _snap = snap;
      return;
    }
    if (_snap != null &&
        _snap!.playlistSync.join() == snap.playlistSync.join() &&
        _snap!.epgPending.join() == snap.epgPending.join() &&
        _snap!.vodPrefetch.join() == snap.vodPrefetch.join() &&
        _snap!.liveFill.join() == snap.liveFill.join() &&
        _snap!.deepSync.join() == snap.deepSync.join() &&
        _snap!.status == snap.status &&
        _snap!.syncPhase == snap.syncPhase &&
        DateTime.now().difference(_lastHeartbeat) <
            const Duration(seconds: 2)) {
      return;
    }
    _snap = snap;
    _lastHeartbeat = DateTime.now();
    JavpLog.i('workdbg', snap.toLogLine());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
