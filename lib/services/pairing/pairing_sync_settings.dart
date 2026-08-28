import 'package:javp/models/sync_settings.dart';
import 'package:javp/providers/profile_provider.dart';

/// Outcome of applying [SyncSettings] received over LAN pairing.
class PairingSyncApplyResult {
  const PairingSyncApplyResult({
    required this.applied,
    required this.needsLocalFolderSetup,
    required this.backend,
  });

  /// True when WebDAV / Google Drive (or none→noop with configured skip) was written.
  final bool applied;

  /// Folder backend cannot use a foreign path — destination must pick a folder.
  final bool needsLocalFolderSetup;

  final SyncBackend backend;

  bool get offerSetupCta =>
      needsLocalFolderSetup || backend == SyncBackend.none || !applied;
}

/// Apply pairing-transferred sync settings on this device.
///
/// WebDAV / Google Drive credentials are device-portable and applied as-is.
/// Folder paths are device-local and never overwritten from the peer.
/// Pass [profileId] to attach the target to a newly created profile instead of
/// whoever is open on the host.
Future<PairingSyncApplyResult> applyPairingSyncSettings({
  required ProfileProvider profiles,
  required SyncSettings incoming,
  String? profileId,
}) async {
  final id = profileId ?? profiles.activeProfileId;
  switch (incoming.backend) {
    case SyncBackend.none:
      return const PairingSyncApplyResult(
        applied: false,
        needsLocalFolderSetup: false,
        backend: SyncBackend.none,
      );
    case SyncBackend.folder:
      // Keep local folder path; peer path is useless on another machine.
      return const PairingSyncApplyResult(
        applied: false,
        needsLocalFolderSetup: true,
        backend: SyncBackend.folder,
      );
    case SyncBackend.webdav:
    case SyncBackend.googleDrive:
      await profiles.updateSyncSettingsFor(id, incoming);
      return PairingSyncApplyResult(
        applied: true,
        needsLocalFolderSetup: false,
        backend: incoming.backend,
      );
  }
}

/// Non-secret session summary for the pairing guest UI.
Map<String, dynamic> pairingSyncSessionSummary(SyncSettings settings) => {
      'syncBackend': settings.backend.name,
      'syncConfigured': settings.isConfigured,
    };
