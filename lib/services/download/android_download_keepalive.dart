import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/download/download_manager.dart';

/// Android foreground service so offline downloads survive backgrounding.
///
/// A local notification is not enough: Android 12+ freezes cached processes,
/// which leaves the download notification stuck while bytes stop landing.
class AndroidDownloadKeepAlive {
  AndroidDownloadKeepAlive({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(_channelName),
      _supportedOverride = supported;

  static const _channelName = 'javp/download_keepalive';

  static AndroidDownloadKeepAlive instance = AndroidDownloadKeepAlive();

  final MethodChannel _channel;
  final bool? _supportedOverride;
  bool _running = false;
  String? _lastKey;

  bool get isSupported {
    final override = _supportedOverride;
    if (override != null) return override;
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  bool get isRunning => _running;

  /// Start or refresh the keep-alive while a task is [DownloadStatus.downloading].
  Future<void> sync(
    DownloadManager manager, {
    String? title,
    String? body,
  }) async {
    if (!isSupported) return;
    DownloadTask? active;
    for (final task in manager.tasks) {
      if (task.status == DownloadStatus.downloading) {
        active = task;
        break;
      }
    }
    if (active == null) {
      await stop();
      return;
    }
    final pct = (active.progress.clamp(0.0, 1.0) * 100).round();
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : active.item.title;
    final detail = active.statusDetail?.trim();
    final resolvedBody = (body != null && body.trim().isNotEmpty)
        ? body.trim()
        : (detail != null && detail.isNotEmpty ? '$detail · $pct%' : '$pct%');
    await start(
      title: resolvedTitle,
      text: resolvedBody,
      progress: pct,
      indeterminate: pct <= 0,
    );
  }

  Future<void> start({
    required String title,
    required String text,
    required int progress,
    required bool indeterminate,
  }) async {
    if (!isSupported) return;
    final key = '$title|$text|$progress|$indeterminate';
    if (_running && _lastKey == key) return;
    try {
      await _channel.invokeMethod<void>('start', {
        'title': title,
        'text': text,
        'progress': progress.clamp(0, 100),
        'indeterminate': indeterminate,
      });
      _running = true;
      _lastKey = key;
    } catch (e) {
      JavpLog.w('download', 'keep-alive start failed: $e');
    }
  }

  Future<void> stop() async {
    if (!isSupported) return;
    // Always invoke native stop. Dart `_running` is lost on process death /
    // isolate restart, but a previously started FGS may still be alive.
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      JavpLog.w('download', 'keep-alive stop failed: $e');
    } finally {
      _running = false;
      _lastKey = null;
    }
  }
}
