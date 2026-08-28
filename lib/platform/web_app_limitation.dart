import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/web_limitation_banner.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shared “browser / web companion limit” UX — blame the web app, not the
/// user’s playlist, account, or JAVP itself.
abstract final class WebAppLimitation {
  static const downloadUrl = 'https://updater.javp.app/';

  /// English fallbacks for call sites without [BuildContext] (e.g. playback).
  static const httpStreamTitle = 'Can’t play over HTTP in the web app';
  static const httpStreamBody =
      'Browsers block insecure (HTTP) media on https://web.javp.app. '
      'This is a browser limit on the web companion — not a JAVP bug. '
      'Your playlist is fine in the native app.';

  static String featureUnavailablePlaybackMessage(String feature) =>
      '$feature isn’t available in the web app (browser limit — not a JAVP bug). '
      'Download the native app: $downloadUrl';

  /// Session dismiss for the Home / Sources HTTP notice (resets on reload).
  static bool httpSourcesBannerDismissed = false;

  static Future<void> openDownload() async {
    final uri = Uri.parse(downloadUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Whether [url] is plain HTTP (mixed content risk on https origins).
  static bool isInsecureHttpUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url.trim());
    return uri != null && uri.scheme.toLowerCase() == 'http';
  }

  /// Playlist / server / EPG endpoints that browsers block on HTTPS pages.
  static bool sourceUsesInsecureHttp(IptvSource source) {
    return isInsecureHttpUrl(source.playlistUrl) ||
        isInsecureHttpUrl(source.serverUrl) ||
        isInsecureHttpUrl(source.alternateServerUrl) ||
        isInsecureHttpUrl(source.epgUrl);
  }

  static List<IptvSource> insecureHttpSources(Iterable<IptvSource> sources) {
    return [
      for (final s in sources)
        if (s.enabled && sourceUsesInsecureHttp(s)) s,
    ];
  }

  /// Prefer https candidates; used when picking among stream variants on web.
  static String? preferHttpsUrl(Iterable<String> urls) {
    String? httpFallback;
    for (final raw in urls) {
      final u = raw.trim();
      if (u.isEmpty) continue;
      final uri = Uri.tryParse(u);
      if (uri == null) continue;
      final scheme = uri.scheme.toLowerCase();
      if (scheme == 'https' || scheme == 'blob') return u;
      if (scheme == 'http' && httpFallback == null) httpFallback = u;
    }
    return httpFallback;
  }

  /// Show a dialog for a gated feature. No-op off web.
  static Future<void> showFeatureUnavailable(
    BuildContext context, {
    String? detail,
  }) async {
    if (!kIsWeb) return;
    final l10n = context.l10n;
    final body = (detail == null || detail.isEmpty)
        ? l10n.webFeatureUnavailableBody
        : '$detail\n\n${l10n.webBrowserLimitBlame}';
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.webFeatureUnavailableTitle),
          content: Text(
            body,
            style: const TextStyle(color: AppColors.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () async {
                await openDownload();
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: Text(l10n.webDownloadApp),
            ),
          ],
        );
      },
    );
  }

  /// HTTP / mixed-content dialog with optional Chromium insecure-content steps.
  static Future<bool> showHttpStreamBlocked(BuildContext context) async {
    if (!kIsWeb) return false;
    final l10n = context.l10n;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.webHttpStreamTitle),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.webHttpStreamBody,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.webBrowserLimitBlame,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.webHttpInsecureContentTip,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('cancel'),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('retry'),
              child: Text(l10n.retry),
            ),
            FilledButton(
              onPressed: () async {
                await openDownload();
                if (ctx.mounted) Navigator.of(ctx).pop('download');
              },
              child: Text(l10n.webDownloadApp),
            ),
          ],
        );
      },
    );
    return result == 'retry';
  }

  /// Inline Home / Sources notice when enabled sources use HTTP endpoints.
  static Widget? httpSourcesBanner({
    required BuildContext context,
    required List<IptvSource> sources,
    VoidCallback? onDismissed,
  }) {
    if (!kIsWeb || httpSourcesBannerDismissed) return null;
    final httpSources = insecureHttpSources(sources);
    if (httpSources.isEmpty) return null;
    final l10n = context.l10n;
    final names = httpSources.take(3).map((s) => s.name).join(', ');
    final extra = httpSources.length > 3
        ? l10n.webHttpSourcesMore(httpSources.length - 3)
        : '';
    return WebLimitationBanner(
      title: l10n.webHttpSourcesTitle,
      body: '${l10n.webHttpSourcesBody}\n\n'
          '${l10n.webBrowserLimitBlame}\n\n'
          '${l10n.webHttpSourcesList('$names$extra')}',
      onDismiss: () {
        httpSourcesBannerDismissed = true;
        onDismissed?.call();
      },
    );
  }
}
