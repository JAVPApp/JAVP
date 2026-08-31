import 'dart:io';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/download/download_manager.dart';
import 'package:javp/services/notifications/epg_reminder_service.dart';

/// Ongoing / progress notifications for offline downloads.
class DownloadNotificationService {
  DownloadNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static final DownloadNotificationService instance =
      DownloadNotificationService();

  static const _channelId = 'downloads';

  /// Keep clear of EPG reminder notification ids.
  static const _idBase = 0x44000000;

  final FlutterLocalNotificationsPlugin _plugin;
  bool _channelReady = false;
  final Set<String> _activeIds = {};
  final Map<String, int> _lastProgressPct = {};

  AppLocalizations _resolveL10n(AppLocalizations? l10n) {
    if (l10n != null) return l10n;
    final code = PlatformDispatcher.instance.locale.languageCode;
    final locale = LocaleController.supportedLocales.firstWhere(
      (l) => l.languageCode == code,
      orElse: () => const Locale('en'),
    );
    return lookupAppLocalizations(locale);
  }

  Future<void> ensureInitialized({AppLocalizations? l10n}) async {
    // Reuse EPG init so the platform plugin is configured once.
    await EpgReminderService.instance.ensureInitialized();
    if (_channelReady) return;

    final loc = _resolveL10n(l10n);
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        _channelId,
        loc.downloads,
        description: loc.downloadsChannelDesc,
        importance: Importance.low,
      ),
    );
    _channelReady = true;
  }

  Future<void> requestPermissionsIfNeeded() async {
    await ensureInitialized();
    await EpgReminderService.instance.requestPermissions();
  }

  int _notificationId(String taskId) =>
      _idBase + (taskId.hashCode & 0x0fffffff);

  static final _bareEpisodeTitleRe = RegExp(
    r'^(episode|épisode|ep)\s*\d+$',
    caseSensitive: false,
  );

  /// Notification title for a download. Series episodes lead with SxxExx so
  /// the episode code is scannable, followed by the show name
  /// (e.g. `"S01E07 · Show"`).
  ///
  /// Also used by [AndroidDownloadKeepAlive] so Android's foreground
  /// progress notification stays consistent with queued/complete/failed.
  static String titleFor(MediaItem item) {
    final season = item.seasonNumber;
    final ep = item.episodeNumber;
    final isEpisode = item.isEpisode || season != null || ep != null;
    final epCode = (season != null || ep != null)
        ? 'S${(season ?? 1).toString().padLeft(2, '0')}'
              'E${(ep ?? 0).toString().padLeft(2, '0')}'
        : null;
    final seriesName = _seriesNameFor(item);

    if (isEpisode && seriesName != null) {
      return epCode != null ? '$epCode · $seriesName' : seriesName;
    }
    if (isEpisode && epCode != null) {
      final title = item.title.trim();
      if (_bareEpisodeTitleRe.hasMatch(title)) return epCode;
      return '$epCode · $title';
    }
    return item.title;
  }

  /// Show name from the `"Show title · S01E01"` subtitle pattern that
  /// [LibraryProvider.episodeMediaItem] writes for series episode rows.
  static String? _seriesNameFor(MediaItem item) {
    final sub = item.subtitle?.trim();
    if (sub != null && sub.contains(' · ')) {
      final head = sub.split(' · ').first.trim();
      if (head.isNotEmpty && !_bareEpisodeTitleRe.hasMatch(head)) {
        return head;
      }
    }
    return null;
  }

  Future<void> sync(DownloadManager manager, {AppLocalizations? l10n}) async {
    if (kIsWeb) return;
    if (!(Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isLinux ||
        Platform.isWindows ||
        Platform.isMacOS)) {
      return;
    }

    final loc = _resolveL10n(l10n);
    try {
      await ensureInitialized(l10n: loc);
    } catch (e) {
      debugPrint('Download notifications init failed: $e');
      return;
    }

    final seen = <String>{};
    for (final task in manager.tasks) {
      switch (task.status) {
        case DownloadStatus.queued:
        case DownloadStatus.downloading:
          seen.add(task.id);
          await _showActive(task, loc);
        case DownloadStatus.completed:
          if (_activeIds.contains(task.id)) {
            seen.add(task.id);
            await _showCompleted(task, loc);
            _activeIds.remove(task.id);
            _lastProgressPct.remove(task.id);
          }
        case DownloadStatus.failed:
          if (_activeIds.contains(task.id) || task.error != null) {
            // Only notify failure when we were already showing progress,
            // or the task just failed (tracked via active set from downloading).
            if (_activeIds.contains(task.id)) {
              seen.add(task.id);
              await _showFailed(task, loc);
              _activeIds.remove(task.id);
              _lastProgressPct.remove(task.id);
            }
          }
        case DownloadStatus.paused:
          await cancel(task.id);
      }
    }

    // Cancel notifications for tasks removed from the queue.
    final stale = _activeIds.difference(seen).toList();
    for (final id in stale) {
      await cancel(id);
    }
  }

  Future<void> _showActive(DownloadTask task, AppLocalizations l10n) async {
    final pct = (task.progress.clamp(0.0, 1.0) * 100).round();
    final prev = _lastProgressPct[task.id];
    final isDownloading = task.status == DownloadStatus.downloading;

    // Android: the dataSync foreground service owns the ongoing download
    // notification so the process is not frozen when the UI is backgrounded.
    // Cancel any prior queued "waiting" local notification for this task.
    if (!kIsWeb && Platform.isAndroid && isDownloading) {
      _lastProgressPct[task.id] = pct;
      _activeIds.add(task.id);
      try {
        await _plugin.cancel(id: _notificationId(task.id));
      } catch (_) {}
      return;
    }

    // Throttle progress updates; always publish status transitions.
    if (prev != null &&
        prev == pct &&
        _activeIds.contains(task.id) &&
        isDownloading &&
        task.statusDetail == null) {
      return;
    }
    // Coarser throttle while downloading (every 5%).
    if (isDownloading &&
        prev != null &&
        (pct - prev).abs() < 5 &&
        pct != 100 &&
        prev != 0) {
      return;
    }
    _lastProgressPct[task.id] = pct;
    _activeIds.add(task.id);

    final title = titleFor(task.item);
    final body = task.status == DownloadStatus.queued
        ? (task.statusDetail?.trim().isNotEmpty == true
              ? task.statusDetail!
              : l10n.waitingEllipsis)
        : (task.statusDetail?.trim().isNotEmpty == true
              ? '${task.statusDetail} · $pct%'
              : l10n.downloadingPercent(pct));

    await _plugin.show(
      id: _notificationId(task.id),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          l10n.downloads,
          channelDescription: l10n.downloadsChannelDesc,
          category: AndroidNotificationCategory.progress,
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          ongoing: isDownloading,
          showProgress: true,
          maxProgress: 100,
          progress: pct,
          indeterminate: isDownloading && pct <= 0,
          playSound: false,
          enableVibration: false,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: false,
          presentBadge: false,
          presentSound: false,
          // iOS has no native determinate progress bar for local notifs.
          subtitle: body,
        ),
        windows: WindowsNotificationDetails(subtitle: body),
        linux: const LinuxNotificationDetails(),
      ),
      payload: 'download:${task.item.id}',
    );
  }

  Future<void> _showCompleted(DownloadTask task, AppLocalizations l10n) async {
    await _plugin.show(
      id: _notificationId(task.id),
      title: titleFor(task.item),
      body: l10n.downloadComplete,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          l10n.downloads,
          channelDescription: l10n.downloadsChannelDesc,
          category: AndroidNotificationCategory.status,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
          ongoing: false,
          autoCancel: true,
          playSound: false,
          enableVibration: false,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
          subtitle: l10n.downloadComplete,
        ),
        windows: WindowsNotificationDetails(subtitle: l10n.downloadComplete),
        linux: const LinuxNotificationDetails(),
      ),
      payload: 'download:${task.item.id}',
    );
  }

  Future<void> _showFailed(DownloadTask task, AppLocalizations l10n) async {
    final err = task.error?.trim();
    final body = (err != null && err.isNotEmpty)
        ? l10n.downloadFailedWithError(err)
        : l10n.downloadFailed;
    final title = titleFor(task.item);
    await _plugin.show(
      id: _notificationId(task.id),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          l10n.downloads,
          channelDescription: l10n.downloadsChannelDesc,
          category: AndroidNotificationCategory.error,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
          ongoing: false,
          autoCancel: true,
          playSound: false,
          enableVibration: false,
          styleInformation: BigTextStyleInformation(body, contentTitle: title),
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
          subtitle: body,
        ),
        windows: WindowsNotificationDetails(subtitle: body),
        linux: const LinuxNotificationDetails(),
      ),
      payload: 'download:${task.item.id}',
    );
  }

  Future<void> cancel(String taskId) async {
    _activeIds.remove(taskId);
    _lastProgressPct.remove(taskId);
    try {
      await ensureInitialized();
      await _plugin.cancel(id: _notificationId(taskId));
    } catch (_) {}
  }
}
