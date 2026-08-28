import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens HTTPS URLs in a real browser package (not App-Link hijacked apps).
///
/// On Android this forces Chrome / the default browser so `app.plex.tv` does not
/// open the Plex app. Falls back to [launchUrl] elsewhere.
class ExternalBrowser {
  static const _channel = MethodChannel('javp/browser');

  static Future<bool> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final ok = await _channel.invokeMethod<bool>(
          'openInBrowser',
          {'url': url},
        );
        if (ok == true) return true;
      } catch (_) {}
    }

    try {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
