import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:javp/services/deep_links/javp_source_link.dart';

/// Registers `javp://` (and optional media open args) for Windows cold starts.
class WindowsProtocol {
  WindowsProtocol._();

  static String? _initialLink;

  /// Captures CLI args from [main] before [runApp].
  static void captureLaunchArgs(List<String> args) {
    for (final raw in args) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      final uri = Uri.tryParse(value);
      if (uri == null) continue;
      if (isExternalDeepLink(uri) || uri.scheme.toLowerCase() == 'magnet') {
        _initialLink = value;
        return;
      }
      // Bare local path dropped onto the exe / "Open with".
      if (!value.contains('://') &&
          (File(value).existsSync() || value.toLowerCase().endsWith('.torrent'))) {
        _initialLink = Uri.file(value).toString();
        return;
      }
    }
  }

  /// Whether [captureLaunchArgs] found a link (does not consume it).
  static bool get hasInitialLink =>
      _initialLink != null && _initialLink!.trim().isNotEmpty;

  static String? takeInitialLink() {
    final link = _initialLink;
    _initialLink = null;
    return link;
  }

  /// Best-effort HKCU protocol registration so `javp://add?…` opens the app.
  static Future<void> ensureRegistered() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      final exe = Platform.resolvedExecutable.replaceAll('"', '');
      final command = '"$exe" "%1"';
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Classes\javp',
        '/ve',
        '/d',
        'URL:JAVP Protocol',
        '/f',
      ]);
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Classes\javp',
        '/v',
        'URL Protocol',
        '/d',
        '',
        '/f',
      ]);
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Classes\javp\shell\open\command',
        '/ve',
        '/d',
        command,
        '/f',
      ]);
    } catch (e) {
      debugPrint('Windows protocol registration failed: $e');
    }
  }

  /// Whether [link] looks like something JAVP should open externally.
  static bool isLaunchLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return false;
    return isExternalDeepLink(uri) || uri.scheme.toLowerCase() == 'magnet';
  }
}
