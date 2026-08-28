import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/services/sync/google_drive_auth.dart';
import 'package:javp/services/sync/google_drive_remote.dart';
import 'package:javp/services/sync/sync_remote.dart';

/// Where a profile's snapshot file lives.
enum SyncBackend {
  /// Sync is off; everything stays on this device.
  none,

  /// A folder on this device that something else keeps in sync — Syncthing, a
  /// Google Drive / Dropbox / Nextcloud desktop folder, or a mounted share.
  folder,

  /// A WebDAV server (Nextcloud, ownCloud, most NAS boxes).
  webdav,

  /// Google Drive via OAuth (works on phone/TV without a mirrored local path).
  googleDrive,
}

extension SyncBackendX on SyncBackend {
  String label(AppLocalizations l10n) => switch (this) {
        SyncBackend.none => l10n.off,
        SyncBackend.folder => l10n.syncBackendFolder,
        SyncBackend.webdav => 'WebDAV',
        SyncBackend.googleDrive => 'Google Drive',
      };

  String description(AppLocalizations l10n) => switch (this) {
        SyncBackend.none => l10n.syncBackendOffDesc,
        SyncBackend.folder => l10n.syncBackendFolderDesc,
        SyncBackend.webdav => l10n.syncBackendWebdavDesc,
        SyncBackend.googleDrive => l10n.syncBackendGoogleDriveDesc,
      };

  static SyncBackend fromName(String? name) =>
      SyncBackend.values.asNameMap()[name ?? ''] ?? SyncBackend.none;
}

/// Per-profile sync configuration on this device. Not part of a profile
/// snapshot: where the files live (and Drive / WebDAV tokens) stay local, so
/// two profiles on the same phone can use different folders or accounts.
class SyncSettings {
  const SyncSettings({
    this.backend = SyncBackend.none,
    this.folderPath = '',
    this.webdavUrl = '',
    this.username = '',
    this.password = '',
    this.syncOnOpen = true,
    this.showActivityStatusBar = false,
    this.googleClientId = '',
    this.googleClientSecret = '',
    this.googleAccessToken = '',
    this.googleRefreshToken = '',
    this.googleTokenExpiresAt,
  });

  static const disabled = SyncSettings();

  final SyncBackend backend;
  final String folderPath;
  final String webdavUrl;
  final String username;
  final String password;

  /// Automatic sync: on open, on resume, and after local changes.
  final bool syncOnOpen;

  /// Thin top [ProfileSyncBanner] while Drive / WebDAV / folder sync runs.
  final bool showActivityStatusBar;

  /// Optional override; otherwise [GoogleDriveAuth.bundledClientId].
  final String googleClientId;

  /// Optional override; otherwise [GoogleDriveAuth.bundledClientSecret].
  final String googleClientSecret;
  final String googleAccessToken;
  final String googleRefreshToken;
  final DateTime? googleTokenExpiresAt;

  String get effectiveGoogleClientId {
    final custom = googleClientId.trim();
    if (custom.isNotEmpty) return custom;
    return GoogleDriveAuth.bundledClientId;
  }

  String get effectiveGoogleClientSecret {
    final custom = googleClientSecret.trim();
    if (custom.isNotEmpty) return custom;
    return GoogleDriveAuth.bundledClientSecret;
  }

  bool get isConfigured => switch (backend) {
        SyncBackend.none => false,
        SyncBackend.folder => folderPath.trim().isNotEmpty,
        SyncBackend.webdav => Uri.tryParse(webdavUrl.trim())?.hasScheme ?? false,
        SyncBackend.googleDrive =>
          effectiveGoogleClientId.isNotEmpty &&
              (googleAccessToken.isNotEmpty || googleRefreshToken.isNotEmpty),
      };

  /// A connected remote, or null when sync isn't set up. Callers own closing it.
  SyncRemote? createRemote({
    void Function(SyncSettings updated)? onAuthRefresh,
  }) {
    if (!isConfigured) return null;
    return switch (backend) {
      SyncBackend.none => null,
      SyncBackend.folder => LocalFolderRemote(folderPath.trim()),
      SyncBackend.webdav => WebDavRemote(
          baseUrl: Uri.parse(webdavUrl.trim()),
          username: username.trim().isEmpty ? null : username.trim(),
          password: password.isEmpty ? null : password,
        ),
      SyncBackend.googleDrive => GoogleDriveRemote(
          accessToken: googleAccessToken,
          refreshToken: googleRefreshToken,
          tokenExpiry: googleTokenExpiresAt,
          clientId: effectiveGoogleClientId,
          clientSecret: effectiveGoogleClientSecret,
          onTokensUpdated: onAuthRefresh == null
              ? null
              : (tokens) => onAuthRefresh(
                    copyWith(
                      googleAccessToken: tokens.accessToken,
                      googleRefreshToken: tokens.refreshToken,
                      googleTokenExpiresAt: tokens.expiresAt,
                    ),
                  ),
        ),
    };
  }

  String targetLabel(AppLocalizations l10n) => switch (backend) {
        SyncBackend.none => l10n.syncNotSetUp,
        SyncBackend.folder => folderPath,
        SyncBackend.webdav => webdavUrl,
        SyncBackend.googleDrive => googleAccessToken.isEmpty &&
                googleRefreshToken.isEmpty
            ? l10n.syncNotSignedIn
            : l10n.syncSignedIn,
      };

  SyncSettings copyWith({
    SyncBackend? backend,
    String? folderPath,
    String? webdavUrl,
    String? username,
    String? password,
    bool? syncOnOpen,
    bool? showActivityStatusBar,
    String? googleClientId,
    String? googleClientSecret,
    String? googleAccessToken,
    String? googleRefreshToken,
    DateTime? googleTokenExpiresAt,
    bool clearGoogleTokens = false,
  }) {
    return SyncSettings(
      backend: backend ?? this.backend,
      folderPath: folderPath ?? this.folderPath,
      webdavUrl: webdavUrl ?? this.webdavUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      syncOnOpen: syncOnOpen ?? this.syncOnOpen,
      showActivityStatusBar:
          showActivityStatusBar ?? this.showActivityStatusBar,
      googleClientId: googleClientId ?? this.googleClientId,
      googleClientSecret: googleClientSecret ?? this.googleClientSecret,
      googleAccessToken: clearGoogleTokens
          ? ''
          : (googleAccessToken ?? this.googleAccessToken),
      googleRefreshToken: clearGoogleTokens
          ? ''
          : (googleRefreshToken ?? this.googleRefreshToken),
      googleTokenExpiresAt: clearGoogleTokens
          ? null
          : (googleTokenExpiresAt ?? this.googleTokenExpiresAt),
    );
  }

  Map<String, dynamic> toJson() => {
        'backend': backend.name,
        'folderPath': folderPath,
        'webdavUrl': webdavUrl,
        'username': username,
        'password': password,
        'syncOnOpen': syncOnOpen,
        'showActivityStatusBar': showActivityStatusBar,
        'googleClientId': googleClientId,
        'googleClientSecret': googleClientSecret,
        'googleAccessToken': googleAccessToken,
        'googleRefreshToken': googleRefreshToken,
        'googleTokenExpiresAt': googleTokenExpiresAt?.toIso8601String(),
      };

  factory SyncSettings.fromJson(Map<String, dynamic> json) {
    return SyncSettings(
      backend: SyncBackendX.fromName(json['backend'] as String?),
      folderPath: json['folderPath'] as String? ?? '',
      webdavUrl: json['webdavUrl'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      syncOnOpen: json['syncOnOpen'] as bool? ?? true,
      showActivityStatusBar: json['showActivityStatusBar'] as bool? ?? false,
      googleClientId: json['googleClientId'] as String? ?? '',
      googleClientSecret: json['googleClientSecret'] as String? ?? '',
      googleAccessToken: json['googleAccessToken'] as String? ?? '',
      googleRefreshToken: json['googleRefreshToken'] as String? ?? '',
      googleTokenExpiresAt:
          DateTime.tryParse(json['googleTokenExpiresAt'] as String? ?? ''),
    );
  }
}
