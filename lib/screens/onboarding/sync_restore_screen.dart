import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/sync_settings.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/providers/shell_actions.dart';
import 'package:javp/services/sync/profile_sync_service.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/plain_text_field.dart';
import 'package:javp/widgets/sync/google_drive_sync_card.dart';
import 'package:provider/provider.dart';

/// First-run path for a device that isn't the first one.
///
/// Point it at the folder your other device already syncs to, pick a profile,
/// and the sources, history, and preferences arrive instead of being set up
/// again by hand.
Future<bool> showSyncRestoreScreen(
  BuildContext context, {
  bool importAlongside = false,
}) async {
  final restored = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      builder: (_) => SyncRestoreScreen(importAlongside: importAlongside),
    ),
  );
  return restored ?? false;
}

class SyncRestoreScreen extends StatefulWidget {
  const SyncRestoreScreen({super.key, this.importAlongside = false});

  /// When true, the chosen target is stored on the adopted profile only —
  /// the active profile's sync settings are left alone.
  final bool importAlongside;

  @override
  State<SyncRestoreScreen> createState() => _SyncRestoreScreenState();
}

class _SyncRestoreScreenState extends State<SyncRestoreScreen> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  SyncBackend _backend = SyncBackend.webdav;
  String _folderPath = '';
  SyncSettings _driveSettings = const SyncSettings(backend: SyncBackend.googleDrive);
  List<RemoteProfileEntry>? _found;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (AppCapabilities.localFilePicker) {
      _backend = SyncBackend.folder;
    } else if (AppCapabilities.googleDriveSync) {
      _backend = SyncBackend.googleDrive;
    } else {
      _backend = SyncBackend.webdav;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Draft settings for folder / WebDAV / Drive.
  ///
  /// Welcome restore may persist onto the active profile. Import-alongside
  /// keeps this draft local until a remote profile is adopted.
  SyncSettings get _draftSettings {
    if (_backend == SyncBackend.googleDrive) {
      return _driveSettings.copyWith(backend: SyncBackend.googleDrive);
    }
    return SyncSettings(
      backend: _backend,
      folderPath: _folderPath,
      webdavUrl: _urlController.text.trim(),
      username: _userController.text.trim(),
      password: _passwordController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.importAlongside
              ? l10n.addProfileFromOtherTarget
              : l10n.restoreFromSync,
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text(
              l10n.restoreFromSyncBlurb,
              style: const TextStyle(color: AppColors.textMuted, height: 1.4),
            ),
            const SizedBox(height: 20),
            if (_found == null)
              ..._connectStep()
            else
              ..._pickStep(),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: AppColors.accent)),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _connectStep() {
    final l10n = context.l10n;
    final googleSettings = _driveSettings.copyWith(
      backend: SyncBackend.googleDrive,
    );
    return [
      RadioGroup<SyncBackend>(
        groupValue: _backend,
        onChanged: (value) {
          if (value == null) return;
          setState(() => _backend = value);
        },
        child: Column(
          children: [
            for (final backend in [
              if (AppCapabilities.localFilePicker) SyncBackend.folder,
              SyncBackend.webdav,
              if (AppCapabilities.googleDriveSync) SyncBackend.googleDrive,
            ])
              RadioListTile<SyncBackend>(
                contentPadding: EdgeInsets.zero,
                value: backend,
                activeColor: AppColors.accent,
                title: Text(backend.label(l10n)),
                subtitle: Text(
                  backend.description(l10n),
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      if (_backend == SyncBackend.folder)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              const Icon(Icons.folder_open_rounded, color: AppColors.accent),
          title: Text(
            _folderPath.isEmpty ? l10n.chooseFolder : _folderPath,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _busy ? null : _pickFolder,
        )
      else if (_backend == SyncBackend.webdav) ...[
        PlainTextField(
          controller: _urlController,
          decoration: InputDecoration(
            labelText: l10n.serverUrl,
            hintText: 'https://cloud.example.com/remote.php/dav/files/me',
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 8),
        PlainTextField(
          controller: _userController,
          decoration: InputDecoration(labelText: l10n.username),
        ),
        const SizedBox(height: 8),
        PlainTextField(
          controller: _passwordController,
          decoration: InputDecoration(labelText: l10n.password),
          obscureText: true,
        ),
      ] else
        GoogleDriveSyncCard(
          settings: googleSettings,
          busy: _busy,
          onBusy: (v) => setState(() => _busy = v),
          persistSettings: widget.importAlongside
              ? (next) async {
                  setState(() => _driveSettings = next);
                }
              : null,
          onConnected: (next) {
            setState(() => _driveSettings = next);
            _discoverProfiles();
          },
          showDisconnect: false,
        ),
      if (_backend != SyncBackend.googleDrive) ...[
        const SizedBox(height: 20),
        FilledButton(
          onPressed:
              _busy || !_draftSettings.isConfigured ? null : _discoverProfiles,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.lookForProfiles),
        ),
      ] else if (googleSettings.isConfigured) ...[
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _discoverProfiles,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.lookForProfiles),
        ),
      ],
    ];
  }

  List<Widget> _pickStep() {
    final l10n = context.l10n;
    final found = _found!;
    if (found.isEmpty) {
      return [
        Text(
          l10n.noProfilesOnTargetYet,
          style: const TextStyle(color: AppColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.continueAction),
        ),
        TextButton(
          onPressed: () => setState(() => _found = null),
          child: Text(l10n.pickDifferentTarget),
        ),
      ];
    }

    return [
      Text(
        found.length == 1
            ? l10n.foundOneProfile
            : l10n.foundNProfiles(found.length),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      for (final entry in found)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(
            backgroundColor: AppColors.surfaceHigh,
            child: Icon(Icons.cloud_download_rounded, color: AppColors.accent),
          ),
          title: Text(entry.profileName),
          subtitle: Text(
            l10n.lastUpdatedAgo(_agoLocalized(l10n, entry.updatedAt)),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _busy ? null : () => _restore(entry),
        ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: _busy ? null : () => setState(() => _found = null),
        child: Text(l10n.pickDifferentTarget),
      ),
    ];
  }

  static String _agoLocalized(AppLocalizations l10n, DateTime at) {
    final delta = DateTime.now().toUtc().difference(at);
    if (delta.inMinutes < 2) return l10n.justNow;
    if (delta.inHours < 1) return l10n.minutesAgo('${delta.inMinutes}');
    if (delta.inDays < 1) return l10n.hoursAgo('${delta.inHours}');
    return l10n.daysAgo('${delta.inDays}');
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: context.l10n.pickSyncFolder,
    );
    if (path == null || !mounted) return;
    setState(() => _folderPath = path);
  }

  Future<void> _discoverProfiles() async {
    final profiles = context.read<ProfileProvider>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final settings = _draftSettings;
    // Restore only reads snapshots — don't fail Android folders that aren't writable.
    final error = await profiles.testConnection(
      settings,
      requireWrite: false,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    try {
      // Welcome restore saves up front so "Continue" with an empty folder still
      // leaves this device syncing. Import-alongside must not overwrite the
      // active profile's backend. Google Drive is persisted by the shared card
      // unless [importAlongside] keeps tokens on the draft.
      if (!widget.importAlongside &&
          settings.backend != SyncBackend.googleDrive) {
        await profiles.updateSyncSettings(settings);
      }
      final found = await profiles.discoverRemoteProfiles(
        includeKnown: true,
        settings: settings,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _found = found;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _restore(RemoteProfileEntry entry) async {
    final profiles = context.read<ProfileProvider>();
    final shell = context.read<ShellActions>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.importAlongside) {
        await profiles.adoptRemoteProfile(
          entry,
          targetSettings: _draftSettings,
        );
      } else {
        await shell.restoreProfile(entry);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }
}
