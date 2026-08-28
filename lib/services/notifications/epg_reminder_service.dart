import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:javp/models/epg_reminder.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

typedef EpgReminderTapCallback = void Function(String mediaItemId);

/// Local notifications for upcoming EPG programmes.
class EpgReminderService {
  EpgReminderService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static final EpgReminderService instance = EpgReminderService();

  static const _channelId = 'epg_reminders';
  static const _channelName = 'EPG reminders';
  static const _channelDesc = 'Alerts when a scheduled TV programme starts';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;
  EpgReminderTapCallback? onNotificationTap;

  Future<void> ensureInitialized() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    final windows = (!kIsWeb && Platform.isWindows)
        ? const WindowsInitializationSettings(
            appName: 'JAVP',
            appUserModelId: 'com.javp.javp',
            guid: 'a8e4f0c2-6d1b-4f9e-9c3a-2b7d5e8f0146',
          )
        : null;
    final linux = (!kIsWeb && Platform.isLinux)
        ? LinuxInitializationSettings(
            defaultActionName: 'Open',
            defaultIcon: AssetsLinuxIcon('assets/branding/javp_logo.png'),
          )
        : null;
    await _plugin.initialize(
      InitializationSettings(
        android: android,
        iOS: ios,
        windows: windows,
        linux: linux,
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.high,
      ),
    );

    _initialized = true;

    final launch = await _plugin.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true &&
        response?.payload != null &&
        response!.payload!.isNotEmpty) {
      // Defer until the router is ready.
      scheduleMicrotask(() => onNotificationTap?.call(response.payload!));
    }
  }

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    onNotificationTap?.call(payload);
  }

  Future<bool> requestPermissions() async {
    await ensureInitialized();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final notif = await android.requestNotificationsPermission();
      return notif ?? true;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    // Windows / Linux plugins typically do not need an explicit prompt.
    return true;
  }

  Future<void> schedule(EpgReminder reminder) async {
    await ensureInitialized();
    if (!reminder.start.isAfter(DateTime.now())) return;

    final when = tz.TZDateTime.from(reminder.start.toLocal(), tz.local);
    final body = reminder.description?.trim().isNotEmpty == true
        ? reminder.description!.trim()
        : 'On ${reminder.channelTitle}';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: reminder.programTitle,
          summaryText: reminder.channelTitle,
        ),
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      windows: WindowsNotificationDetails(
        subtitle: reminder.channelTitle,
      ),
      linux: const LinuxNotificationDetails(),
    );

    // Inexact alarms avoid SCHEDULE_EXACT_ALARM / Play Console declaration.
    // Reminders may fire slightly late; boot receiver reschedules after reboot.
    await _plugin.zonedSchedule(
      reminder.notificationId,
      reminder.programTitle,
      'Starting now on ${reminder.channelTitle}',
      when,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: reminder.mediaItemId,
    );
  }

  Future<void> cancel(EpgReminder reminder) async {
    await ensureInitialized();
    await _plugin.cancel(reminder.notificationId);
  }

  Future<void> rescheduleAll(List<EpgReminder> reminders) async {
    await ensureInitialized();
    for (final reminder in reminders) {
      if (reminder.isPast) {
        await cancel(reminder);
        continue;
      }
      await schedule(reminder);
    }
  }
}
