import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/media_item.dart';
import 'package:url_launcher/url_launcher.dart';

/// Result of launching the current stream outside JAVP.
enum ExternalPlayerLaunch {
  opened,
  failed,
  unavailable,
}

/// Opens a playable URL in an external app (system “Open with” / chooser).
/// Progress is not tracked.
class ExternalPlayer {
  ExternalPlayer._();

  static const _channel = MethodChannel('javp/external_player');

  /// Prefer VLC package names on Android (stable + debug).
  static const androidVlcPackages = <String>[
    'org.videolan.vlc',
    'org.videolan.vlc.debug',
  ];

  /// Whether [url] looks openable outside JAVP (http(s), file, content, rtsp…).
  static bool canOpenUrl(String? url) {
    final raw = url?.trim() ?? '';
    if (raw.isEmpty) return false;
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme.isEmpty) {
      // Local filesystem path without a scheme.
      return !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    }
    return scheme == 'http' ||
        scheme == 'https' ||
        scheme == 'file' ||
        scheme == 'content' ||
        scheme == 'rtsp' ||
        scheme == 'rtsps' ||
        scheme == 'udp' ||
        scheme == 'rtp';
  }

  static bool canOpenItem(MediaItem? item, {String? playUrl}) {
    return canOpenUrl(playUrl ?? item?.playUrl);
  }

  /// Guess a media MIME for Android ACTION_VIEW.
  static String mimeForUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('format=m3u8')) {
      return 'application/x-mpegURL';
    }
    if (lower.contains('.mpd')) return 'application/dash+xml';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.ts') || lower.endsWith('.m2ts')) {
      return 'video/mp2t';
    }
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.startsWith('rtsp')) return 'video/*';
    return 'video/*';
  }

  /// Infuse x-callback play URL (iOS / macOS when Infuse is installed).
  static Uri? infusePlayUri(String url) {
    final encoded = Uri.encodeComponent(url);
    return Uri.tryParse('infuse://x-callback-url/play?url=$encoded');
  }

  /// VLC intent / deep-link style URI used as a soft preference hint.
  static Uri? vlcStreamUri(String url) {
    final encoded = Uri.encodeComponent(url);
    return Uri.tryParse('vlc://$encoded');
  }

  static Future<ExternalPlayerLaunch> open({
    required String url,
    String? title,
  }) async {
    final trimmed = url.trim();
    if (!canOpenUrl(trimmed)) return ExternalPlayerLaunch.unavailable;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final ok = await _channel.invokeMethod<bool>('openMedia', {
          'url': trimmed,
          'title': title,
          'mime': mimeForUrl(trimmed),
        });
        return ok == true
            ? ExternalPlayerLaunch.opened
            : ExternalPlayerLaunch.failed;
      } catch (_) {
        // Fall through to url_launcher.
      }
    }

    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      final infuse = infusePlayUri(trimmed);
      if (infuse != null) {
        try {
          if (await canLaunchUrl(infuse)) {
            final ok = await launchUrl(
              infuse,
              mode: LaunchMode.externalApplication,
            );
            if (ok) return ExternalPlayerLaunch.opened;
          }
        } catch (_) {}
      }
    }

    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final desktop = await _openDesktop(trimmed, title: title);
      if (desktop != null) return desktop;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return ExternalPlayerLaunch.failed;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return ok ? ExternalPlayerLaunch.opened : ExternalPlayerLaunch.failed;
    } catch (_) {
      return ExternalPlayerLaunch.failed;
    }
  }

  /// Playlist body handed to Windows “Open with” for http(s) / rtsp streams.
  @visibleForTesting
  static String playlistM3u({required String url, String? title}) {
    final name = (title ?? 'Stream')
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .replaceAll(',', ' ')
        .trim();
    return '#EXTM3U\n#EXTINF:-1,${name.isEmpty ? 'Stream' : name}\n$url\n';
  }

  /// Commands that open the Windows “Open with” dialog for [filePath].
  @visibleForTesting
  static List<List<String>> windowsOpenWithCommands(String filePath) => [
    ['OpenWith.exe', filePath],
    [r'C:\Windows\System32\OpenWith.exe', filePath],
    ['rundll32', 'shell32.dll,OpenAs_RunDLL', filePath],
  ];

  static Future<ExternalPlayerLaunch?> _openDesktop(
    String url, {
    String? title,
  }) async {
    if (Platform.isWindows) {
      return _openWindowsChooser(url, title: title);
    }
    if (Platform.isLinux) {
      try {
        final result = await Process.start(
          'xdg-open',
          [url],
          mode: ProcessStartMode.detached,
        );
        if (result.pid > 0) return ExternalPlayerLaunch.opened;
      } catch (_) {}
      return null;
    }
    // macOS: Infuse (above) or url_launcher — do not force VLC.
    return null;
  }

  static Future<ExternalPlayerLaunch?> _openWindowsChooser(
    String url, {
    String? title,
  }) async {
    final target = await _windowsOpenWithTarget(url, title: title);
    if (target == null) return null;
    for (final cmd in windowsOpenWithCommands(target)) {
      try {
        final result = await Process.start(
          cmd.first,
          cmd.sublist(1),
          mode: ProcessStartMode.detached,
        );
        if (result.pid > 0) return ExternalPlayerLaunch.opened;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static Future<String?> _windowsOpenWithTarget(
    String url, {
    String? title,
  }) async {
    final local = _windowsLocalPath(url);
    if (local != null) return local;
    try {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}javp-external.m3u',
      );
      await file.writeAsString(
        playlistM3u(url: url, title: title),
        flush: true,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static String? windowsLocalPath(String url) => _windowsLocalPath(url);

  static String? _windowsLocalPath(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return null;
    if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(raw) || raw.startsWith(r'\\')) {
      return raw;
    }
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.scheme.toLowerCase() == 'file') {
      try {
        return uri.toFilePath();
      } catch (_) {
        return null;
      }
    }
    if (uri != null && uri.scheme.isNotEmpty) return null;
    return null;
  }
}
