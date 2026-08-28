import 'package:javp/models/profile.dart';
import 'package:javp/services/sync/profile_sync_service.dart';

/// Actions only the app shell can perform, handed down to screens.
///
/// Switching profiles rebuilds the library and playback providers, so it can't
/// be done from inside the widget tree that reads them.
class ShellActions {
  const ShellActions({
    required this.switchProfile,
    required this.syncNow,
    required this.restoreProfile,
  });

  /// [pinVerified] skips the lock-PIN prompt (caller already checked).
  final Future<void> Function(
    Profile profile, {
    bool pinVerified,
  }) switchProfile;

  /// Flushes pending writes, syncs the active profile, and reloads if needed.
  final Future<void> Function() syncNow;

  /// Adopts a profile from the sync folder, switches to it, and pulls its data.
  final Future<void> Function(RemoteProfileEntry entry) restoreProfile;
}
