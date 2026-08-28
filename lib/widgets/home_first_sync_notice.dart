import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';

/// Home copy while a newly added source is still doing its first catalog pull.
class HomeFirstSyncNotice extends StatelessWidget {
  const HomeFirstSyncNotice({super.key, this.compact = false, this.status});

  /// Tight strip above shelves. Full empty-home layout when false.
  final bool compact;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final phase = status?.trim();
    final hasPhase = phase != null && phase.isNotEmpty;
    if (compact) {
      return Material(
        color: AppColors.surfaceHigh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.homeFirstSyncTitle,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.homeFirstSyncHint,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        height: 1.35,
                      ),
                    ),
                    if (hasPhase) ...[
                      const SizedBox(height: 4),
                      Text(
                        phase,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textDim,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.homeFirstSyncTitle,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.homeFirstSyncHint,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (hasPhase) ...[
            const SizedBox(height: 12),
            Text(
              phase,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textDim),
            ),
          ],
        ],
      ),
    );
  }
}
