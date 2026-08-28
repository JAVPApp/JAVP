import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/services/sync/profile_sync_service.dart';
import 'package:javp/services/trackers/tracker_sync_runner.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/mini_player_bar.dart';
import 'package:provider/provider.dart';

/// Thin non-blocking strip while profile sync (Drive / WebDAV / folder) runs.
///
/// Overlays the top of the app shell so auto-sync progress is visible while
/// browsing without shifting layout; Profiles → Sync also shows the same phase
/// text next to Sync now. Hidden when [SyncSettings.showActivityStatusBar] is
/// off (sync still runs).
///
/// On desktop/tablet rail shells the strip is inset to the content column so it
/// does not paint over the left nav (same rule as [PersistentMiniPlayer]).
///
/// Pointer events pass through — sync must never block clicks / scroll under
/// the strip (and must not leave a wait cursor over the shell).
class ProfileSyncBanner extends StatefulWidget {
  const ProfileSyncBanner({
    super.key,
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget? child;

  @override
  State<ProfileSyncBanner> createState() => _ProfileSyncBannerState();
}

class _ProfileSyncBannerState extends State<ProfileSyncBanner> {
  var _routeFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_onRouteChanged);
  }

  @override
  void didUpdateWidget(covariant ProfileSyncBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router.routerDelegate == widget.router.routerDelegate) {
      return;
    }
    oldWidget.router.routerDelegate.removeListener(_onRouteChanged);
    widget.router.routerDelegate.addListener(_onRouteChanged);
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  void _onRouteChanged() {
    if (!mounted || _routeFrameScheduled) return;
    _routeFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeFrameScheduled = false;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final profiles = context.watch<ProfileProvider>();
    final showBar = profiles.syncSettings.showActivityStatusBar;
    final running = profiles.syncStatus == SyncStatus.running;
    final phase = profiles.syncPhase;
    final l10n = context.l10n;

    final config = widget.router.routerDelegate.currentConfiguration;
    final path = config.matches.isEmpty ? '' : config.uri.path;
    final railInset =
        AdaptiveLayout.useRail(context) && isShellTabPath(path)
            ? AdaptiveLayout.railWidth(context)
            : 0.0;

    return Stack(
      children: [
        widget.child ?? const SizedBox.shrink(),
        if (running && showBar)
          Positioned(
            top: 0,
            left: railInset,
            right: 0,
            child: IgnorePointer(
              child: MouseRegion(
                cursor: SystemMouseCursors.basic,
                child: Material(
                  color: AppColors.surfaceHigh,
                  child: SafeArea(
                    bottom: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  phase != null
                                      ? syncPhaseLabel(l10n, phase)
                                      : l10n.syncing,
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const LinearProgressIndicator(
                          minHeight: 2,
                          backgroundColor: AppColors.borderSoft,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String syncPhaseLabel(AppLocalizations l10n, SyncPhase phase) {
  return switch (phase) {
    SyncPhase.downloading => l10n.syncPhaseDownloading,
    SyncPhase.readingLocal => l10n.syncPhaseReadingLocal,
    SyncPhase.merging => l10n.syncPhaseMerging,
    SyncPhase.uploading => l10n.syncPhaseUploading,
    SyncPhase.applyingLibrary => l10n.syncPhaseApplyingLibrary,
    SyncPhase.applyingPrefs => l10n.syncPhaseApplyingPrefs,
  };
}

String trackerSyncPhaseLabel(AppLocalizations l10n, TrackerSyncPhase? phase) {
  return switch (phase) {
    TrackerSyncPhase.fetching => l10n.trackerSyncFetching,
    TrackerSyncPhase.indexing => l10n.trackerSyncIndexing,
    TrackerSyncPhase.matching => l10n.trackerSyncMatching,
    TrackerSyncPhase.merging => l10n.trackerSyncMerging,
    null => l10n.syncing,
  };
}
