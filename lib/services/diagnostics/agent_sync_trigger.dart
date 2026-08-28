import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/storage/app_documents.dart';
import 'package:path/path.dart' as p;

/// Headless agent / overnight hook: drop an empty file to start Synchroniser.
///
/// Path: `{Documents}/JAVP/.agent/sync_xtream`
/// Optional contents: a source id (otherwise first enabled Xtream source).
/// The file is deleted as soon as the sync is claimed.
class AgentSyncTrigger {
  AgentSyncTrigger({
    required this.sources,
    required this.syncSource,
  });

  final List<IptvSource> Function() sources;
  final Future<void> Function(
    String sourceId, {
    bool refreshVod,
    bool blockUi,
    String reason,
  })
  syncSource;

  Timer? _timer;
  bool _busy = false;

  void start() {
    if (kIsWeb || !DesktopUi.isDesktopOs) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_poll());
    });
    JavpLog.i(
      'agent',
      'sync trigger watching Documents/JAVP/.agent/sync_xtream',
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_busy) return;
    late final File trigger;
    try {
      final root = await AppDocuments.directory();
      trigger = File(p.join(root.path, '.agent', 'sync_xtream'));
      if (!await trigger.exists()) return;
    } catch (_) {
      return;
    }

    _busy = true;
    try {
      var sourceId = (await trigger.readAsString()).trim();
      try {
        await trigger.delete();
      } catch (_) {}

      final list = sources();
      if (sourceId.isEmpty) {
        IptvSource? xtream;
        for (final s in list) {
          if (s.enabled && s.type == IptvSourceType.xtream) {
            xtream = s;
            break;
          }
        }
        sourceId = xtream?.id ?? '';
      }
      if (sourceId.isEmpty) {
        JavpLog.w('agent', 'sync trigger: no xtream source');
        return;
      }
      JavpLog.i('agent', 'sync trigger firing source=$sourceId');
      await syncSource(
        sourceId,
        refreshVod: true,
        blockUi: false,
        reason: 'manual',
      );
      JavpLog.i('agent', 'sync trigger finished source=$sourceId');
    } catch (e, st) {
      JavpLog.e('agent', 'sync trigger failed: $e', stack: st);
    } finally {
      _busy = false;
    }
  }
}
