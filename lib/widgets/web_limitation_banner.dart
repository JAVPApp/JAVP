import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/platform/web_app_limitation.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';

/// Clear “browser limit, not JAVP” notice for the web companion.
class WebLimitationBanner extends StatelessWidget {
  const WebLimitationBanner({
    super.key,
    required this.title,
    required this.body,
    this.onDismiss,
    this.showDownload = true,
  });

  final String title;
  final String body;
  final VoidCallback? onDismiss;
  final bool showDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(
                Icons.public_off_rounded,
                color: AppColors.accent,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      height: 1.35,
                    ),
                  ),
                  if (showDownload) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () =>
                              unawaited(WebAppLimitation.openDownload()),
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text(l10n.webDownloadApp),
                        ),
                        if (onDismiss != null)
                          TextButton(
                            onPressed: onDismiss,
                            child: Text(l10n.webLimitationDismiss),
                          ),
                      ],
                    ),
                  ] else if (onDismiss != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: onDismiss,
                        child: Text(l10n.webLimitationDismiss),
                      ),
                    ),
                ],
              ),
            ),
            if (onDismiss != null)
              IconButton(
                tooltip: l10n.webLimitationDismiss,
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded, size: 20),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }
}
