import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/models/sync_settings.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/providers/shell_actions.dart';
import 'package:javp/screens/onboarding/sync_restore_screen.dart';
import 'package:javp/screens/pairing/device_pair_client_screen.dart';
import 'package:javp/screens/tv/tv_pairing_screen.dart';
import 'package:javp/services/storage/sources_export.dart';
import 'package:javp/services/sync/profile_sync_service.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/plain_text_field.dart';
import 'package:javp/widgets/profile_avatar.dart';
import 'package:javp/widgets/profile_lock.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:javp/widgets/sync/google_drive_sync_card.dart';
import 'package:javp/widgets/sync/profile_sync_banner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

/// Profiles and file-based sync.
class SettingsProfilesTab extends StatelessWidget {
  const SettingsProfilesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final profiles = context.watch<ProfileProvider>();
    final shell = context.read<ShellActions>();
    final l10n = context.l10n;
    if (!profiles.ready) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(
          l10n.settingsProfiles,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.profilesBlurb,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        for (final profile in profiles.profiles)
          _ProfileTile(
            profile: profile,
            isActive: profile.id == profiles.activeProfileId,
            onSwitch: () => shell.switchProfile(profile),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _addProfile(context),
            icon: const Icon(Icons.person_add_alt_rounded),
            label: Text(l10n.addProfile),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showSyncRestoreScreen(
              context,
              importAlongside: true,
            ),
            icon: const Icon(Icons.travel_explore_rounded),
            label: Text(l10n.addProfileFromOtherTarget),
          ),
        ),
        const SizedBox(height: 28),
        const _SourcesTransferSection(),
        const SizedBox(height: 28),
        const _SyncSection(),
      ],
    );
  }

  Future<void> _addProfile(BuildContext context) async {
    final profiles = context.read<ProfileProvider>();
    final shell = context.read<ShellActions>();
    final name = await _promptForName(context, title: context.l10n.newProfile);
    if (name == null) return;
    final profile = await profiles.createProfile(name);
    await shell.switchProfile(profile);
  }
}

Future<String?> _promptForName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final l10n = context.l10n;
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(title),
      content: JavpTextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.name),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(l10n.save),
        ),
      ],
    ),
  ).then((value) => (value == null || value.isEmpty) ? null : value);
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.isActive,
    required this.onSwitch,
  });

  final Profile profile;
  final bool isActive;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final profiles = context.watch<ProfileProvider>();
    final l10n = context.l10n;
    final locked = profiles.isProfileLocked(profile.id);
    final sync = profiles.syncSettingsFor(profile.id);
    final subtitle = [
      if (isActive) l10n.activeOnThisDevice else if (locked) l10n.tapToUnlock else l10n.tapToSwitch,
      if (sync.backend != SyncBackend.none) sync.backend.label(l10n),
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ProfileAvatar(
        profile: profile,
        radius: 22,
        highlighted: isActive,
      ),
      title: Text(profile.name),
      subtitle: Text(subtitle),
      onTap: isActive ? null : onSwitch,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (locked)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.lock_rounded, size: 18, color: AppColors.textMuted),
            ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'photo':
                  await _pickPhoto(context, profile);
                case 'remove_photo':
                  await profiles.clearProfilePhoto(profile.id);
                case 'rename':
                  final name = await _promptForName(
                    context,
                    title: l10n.renameProfile,
                    initial: profile.name,
                  );
                  if (name != null) await profiles.renameProfile(profile.id, name);
                case 'pin':
                  if (!context.mounted) return;
                  await _setOrChangePin(context, profile);
                case 'unpin':
                  if (!context.mounted) return;
                  await _removePin(context, profile);
                case 'delete':
                  if (!context.mounted) return;
                  if (locked &&
                      !profiles.syncSettingsFor(profile.id).isConfigured) {
                    final ok = await showProfileUnlockDialog(
                      context,
                      profileName: profile.name,
                      verify: (pin) => profiles.verifyLockPin(profile.id, pin),
                    );
                    if (!ok || !context.mounted) return;
                  }
                  final ok = await _confirmDelete(context, profile);
                  if (ok) await profiles.deleteProfile(profile.id);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'photo', child: Text(l10n.changeProfilePhoto)),
              if (profile.hasAvatar)
                PopupMenuItem(
                  value: 'remove_photo',
                  child: Text(l10n.removeProfilePhoto),
                ),
              PopupMenuItem(value: 'rename', child: Text(l10n.rename)),
              if (isActive)
                PopupMenuItem(
                  value: 'pin',
                  child: Text(
                    locked ? l10n.parentalChangePin : l10n.parentalSetPin,
                  ),
                ),
              if (isActive && locked)
                PopupMenuItem(
                  value: 'unpin',
                  child: Text(l10n.parentalRemovePin),
                ),
              if (!profile.isDefault)
                PopupMenuItem(value: 'delete', child: Text(l10n.delete)),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickPhoto(BuildContext context, Profile profile) async {
    final profiles = context.read<ProfileProvider>();
    final l10n = context.l10n;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    Uint8List? bytes = file.bytes;
    if ((bytes == null || bytes.isEmpty) && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (!context.mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.profilePhotoInvalid)));
      return;
    }
    final ok = await profiles.setProfilePhoto(profile.id, bytes);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.profilePhotoInvalid)));
    }
  }

  Future<void> _setOrChangePin(BuildContext context, Profile profile) async {
    final profiles = context.read<ProfileProvider>();
    final l10n = context.l10n;
    final locked = profiles.isProfileLocked(profile.id);
    final pin = await showProfilePinEditorDialog(
      context,
      title: locked ? l10n.parentalChangePin : l10n.parentalSetPin,
      message: l10n.profilePinHelp,
      verifyCurrent: locked
          ? (current) => profiles.verifyLockPin(profile.id, current)
          : null,
    );
    if (pin == null || !context.mounted) return;
    await profiles.setLockPin(profile.id, pin);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.parentalPinSaved)),
    );
  }

  Future<void> _removePin(BuildContext context, Profile profile) async {
    final profiles = context.read<ProfileProvider>();
    final l10n = context.l10n;
    final pin = await showProfilePinPromptDialog(
      context,
      title: l10n.parentalRemovePin,
      message: l10n.profilePinHelp,
    );
    if (pin == null || !context.mounted) return;
    final cleared = await profiles.clearLockPin(profile.id, pin);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleared ? l10n.parentalPinRemoved : l10n.parentalPinIncorrect,
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context, Profile profile) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.deleteProfileTitle(profile.name)),
        content: Text(l10n.deleteProfileBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    return ok == true;
  }
}

class _SyncSection extends StatefulWidget {
  const _SyncSection();

  @override
  State<_SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<_SyncSection> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _hydratedForProfile;
  bool _busy = false;

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _hydrate(ProfileProvider profiles) {
    final id = profiles.activeProfileId;
    if (_hydratedForProfile == id) return;
    _hydratedForProfile = id;
    final settings = profiles.syncSettings;
    _urlController.text = settings.webdavUrl;
    _userController.text = settings.username;
    _passwordController.text = settings.password;
  }

  @override
  Widget build(BuildContext context) {
    final profiles = context.watch<ProfileProvider>();
    final settings = profiles.syncSettings;
    final l10n = context.l10n;
    _hydrate(profiles);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.syncForProfile(profiles.activeProfile?.name ?? l10n.sync),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.syncBlurb,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        RadioGroup<SyncBackend>(
          groupValue: settings.backend,
          onChanged: (value) {
            if (value == null) return;
            profiles.updateSyncSettings(settings.copyWith(backend: value));
          },
          child: Column(
            children: [
              for (final backend in SyncBackend.values)
                if (backend != SyncBackend.googleDrive ||
                    AppCapabilities.googleDriveSync)
                  if (backend != SyncBackend.folder ||
                      AppCapabilities.localFilePicker)
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
        if (settings.backend == SyncBackend.folder) ...[
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.folder_open_rounded,
              color: AppColors.accent,
            ),
            title: Text(
              settings.folderPath.isEmpty
                  ? l10n.chooseFolder
                  : settings.folderPath,
            ),
            subtitle: Text(l10n.syncFolderSubtitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _pickFolder,
          ),
        ],
        if (settings.backend == SyncBackend.webdav) ...[
          const SizedBox(height: 8),
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
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _busy ? null : _saveWebdav,
              child: Text(l10n.saveAndTest),
            ),
          ),
        ],
        if (settings.backend == SyncBackend.googleDrive) ...[
          const SizedBox(height: 8),
          GoogleDriveSyncCard(
            settings: settings,
            busy: _busy,
            onBusy: (v) => setState(() => _busy = v),
            onToast: _toast,
          ),
        ],
        if (settings.backend != SyncBackend.none) ...[
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: settings.syncOnOpen,
            title: Text(l10n.automaticSync),
            subtitle: Text(
              l10n.automaticSyncSubtitle,
              style: const TextStyle(color: AppColors.textMuted),
            ),
            onChanged: (value) => profiles.updateSyncSettings(
              settings.copyWith(syncOnOpen: value),
            ),
          ),
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: settings.showActivityStatusBar,
            title: Text(l10n.showActivityStatusBar),
            subtitle: Text(
              l10n.showActivityStatusBarSubtitle,
              style: const TextStyle(color: AppColors.textMuted),
            ),
            onChanged: (value) => profiles.updateSyncSettings(
              settings.copyWith(showActivityStatusBar: value),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              FilledButton.icon(
                onPressed: !settings.isConfigured || _busy ? null : _syncNow,
                icon: profiles.syncStatus == SyncStatus.running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(
                  profiles.syncStatus == SyncStatus.running
                      ? l10n.syncing
                      : l10n.syncNow,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _statusLine(profiles, l10n),
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
          if (profiles.syncStatus == SyncStatus.running) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (settings.isConfigured) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : _findProfiles,
                icon: const Icon(Icons.travel_explore_rounded),
                label: Text(l10n.findProfilesOnTarget),
              ),
            ),
          ],
        ],
      ],
    );
  }

  String _statusLine(ProfileProvider profiles, AppLocalizations l10n) {
    if (profiles.syncStatus == SyncStatus.running) {
      final phase = profiles.syncPhase;
      return phase != null ? syncPhaseLabel(l10n, phase) : l10n.syncing;
    }
    if (profiles.syncStatus == SyncStatus.failed) {
      return profiles.syncError ?? l10n.syncFailed;
    }
    final at = profiles.lastSyncAt;
    if (at == null) return l10n.notSyncedYet;
    final local = at.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return l10n.lastSyncedAt('$hh:$mm');
  }

  Future<void> _pickFolder() async {
    final profiles = context.read<ProfileProvider>();
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: context.l10n.pickSyncFolder,
    );
    if (path == null) return;
    final next = profiles.syncSettings.copyWith(folderPath: path);
    final error = await profiles.testConnection(next);
    if (!mounted) return;
    if (error != null) {
      _toast(error);
      return;
    }
    await profiles.updateSyncSettings(next);
  }

  Future<void> _saveWebdav() async {
    final profiles = context.read<ProfileProvider>();
    setState(() => _busy = true);
    final next = profiles.syncSettings.copyWith(
      webdavUrl: _urlController.text.trim(),
      username: _userController.text.trim(),
      password: _passwordController.text,
    );
    final error = await profiles.testConnection(next);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      _toast(error);
      return;
    }
    await profiles.updateSyncSettings(next);
    if (mounted) _toast(context.l10n.connectedPeriod);
  }

  Future<void> _syncNow() async {
    final shell = context.read<ShellActions>();
    setState(() => _busy = true);
    await shell.syncNow();
    if (!mounted) return;
    setState(() => _busy = false);
    final error = context.read<ProfileProvider>().syncError;
    _toast(error ?? context.l10n.syncedPeriod);
  }

  Future<void> _findProfiles() async {
    final profiles = context.read<ProfileProvider>();
    final l10n = context.l10n;
    setState(() => _busy = true);
    final found = await profiles.discoverRemoteProfiles();
    if (!mounted) return;
    setState(() => _busy = false);
    if (found.isEmpty) {
      _toast(l10n.noOtherProfilesInFolder);
      return;
    }
    final entry = await showDialog<RemoteProfileEntry>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.addProfileFromFolder),
        children: [
          for (final e in found)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, e),
              child: Text(e.profileName),
            ),
        ],
      ),
    );
    if (entry == null) return;
    await profiles.adoptRemoteProfile(
      entry,
      targetSettings: profiles.syncSettings,
    );
    if (mounted) {
      _toast(l10n.profileAddedSwitchToSync(entry.profileName));
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Export / import library sources without Drive sync.
class _SourcesTransferSection extends StatefulWidget {
  const _SourcesTransferSection();

  @override
  State<_SourcesTransferSection> createState() =>
      _SourcesTransferSectionState();
}

class _SourcesTransferSectionState extends State<_SourcesTransferSection> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final count = context.select<LibraryProvider, int>((l) => l.sources.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.sourcesTransfer,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          l10n.sourcesTransferBlurb,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        if (AppCapabilities.sourcePairingServer) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.qr_code_2_rounded,
              color: AppColors.accent,
            ),
            title: Text(l10n.devicePairShowQr),
            subtitle: Text(l10n.devicePairShowQrBlurb),
            enabled: !_busy,
            onTap: _busy
                ? null
                : () {
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const TvPairingScreen(),
                      ),
                    );
                  },
          ),
          // Phone / tablet: enter host PIN when QR opened the browser instead.
          if (!TvPlatform.isTvShell)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.phonelink_rounded,
                color: AppColors.accent,
              ),
              title: Text(l10n.devicePairManualTitle),
              subtitle: Text(l10n.devicePairManualEntryBlurb),
              enabled: !_busy,
              onTap: _busy
                  ? null
                  : () {
                      Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const DevicePairManualScreen(),
                        ),
                      );
                    },
            ),
        ],
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.upload_file_rounded,
            color: AppColors.accent,
          ),
          title: Text(l10n.exportSources),
          subtitle: Text(l10n.iptvSourcesCount(count)),
          enabled: !_busy && count > 0,
          onTap: _busy || count == 0 ? null : _export,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_rounded, color: AppColors.accent),
          title: Text(l10n.importSources),
          enabled: !_busy,
          onTap: _busy ? null : _import,
        ),
      ],
    );
  }

  Future<void> _export() async {
    final l10n = context.l10n;
    final library = context.read<LibraryProvider>();
    final mode = await showDialog<SourcesSecretsMode>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.exportSourcesSecretsTitle),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              l10n.exportSourcesSecretsBody,
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, SourcesSecretsMode.omitted),
            child: Text(l10n.exportSecretsOmit),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(context, SourcesSecretsMode.encrypted),
            child: Text(l10n.exportSecretsEncrypt),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(context, SourcesSecretsMode.plaintext),
            child: Text(l10n.exportSecretsPlaintext),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    String? passphrase;
    if (mode == SourcesSecretsMode.plaintext) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(l10n.exportSecretsPlaintextConfirmTitle),
          content: Text(l10n.exportSecretsPlaintextConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.continueAction),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    } else if (mode == SourcesSecretsMode.encrypted) {
      passphrase = await _promptPassphrase(
        title: l10n.exportPassphraseTitle,
        body: l10n.exportPassphraseBody,
        confirm: true,
      );
      if (passphrase == null || !mounted) return;
    }

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final doc = await library.buildSourcesExport(
        secretsMode: mode,
        passphrase: passphrase,
      );
      final encoded = doc.encode();
      await _shareOrSaveExport(encoded);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.sourcesExported)));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.sourcesExportFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareOrSaveExport(String encoded) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    // Prefer a real save dialog on desktop; share sheet elsewhere.
    if (!Platform.isAndroid && !Platform.isIOS) {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: context.l10n.exportSources,
        fileName: SourcesExportDocument.defaultFileName,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: utf8.encode(encoded),
      );
      if (path == null) return;
      // Some platforms write [bytes] already; others need an explicit write.
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        await file.writeAsString(encoded, flush: true);
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${SourcesExportDocument.defaultFileName}');
    await file.writeAsString(encoded, flush: true);
    final sharePath = Platform.isWindows
        ? file.path.replaceAll('/', r'\')
        : file.path;
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            sharePath,
            mimeType: 'application/json',
            name: SourcesExportDocument.defaultFileName,
          ),
        ],
        text: Platform.isWindows ? 'JAVP sources export' : null,
        subject: 'JAVP sources',
        title: 'JAVP sources',
        sharePositionOrigin: origin,
      ),
    );
  }

  Future<void> _import() async {
    final l10n = context.l10n;
    final library = context.read<LibraryProvider>();
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final file = picked.files.first;
    String? raw = file.bytes != null ? utf8.decode(file.bytes!) : null;
    if (raw == null && file.path != null) {
      raw = await File(file.path!).readAsString();
    }
    if (!mounted) return;
    if (raw == null || raw.isEmpty) {
      _toast(l10n.sourcesImportFailed);
      return;
    }
    final doc = SourcesExportDocument.tryDecode(raw);
    if (doc == null) {
      _toast(l10n.sourcesImportInvalid);
      return;
    }

    final mode = await showDialog<SourcesImportMode>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.importSourcesTitle),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, SourcesImportMode.merge),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.importSourcesMerge),
              subtitle: Text(l10n.importSourcesMergeBody),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, SourcesImportMode.replace),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.importSourcesReplace),
              subtitle: Text(l10n.importSourcesReplaceBody),
            ),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    String? passphrase;
    if (doc.secretsMode == SourcesSecretsMode.encrypted) {
      passphrase = await _promptPassphrase(
        title: l10n.importPassphraseTitle,
        body: l10n.importPassphraseBody,
        confirm: false,
      );
      if (passphrase == null || !mounted) return;
    }

    setState(() => _busy = true);
    try {
      final count = await library.importSourcesDocument(
        document: doc,
        mode: mode,
        passphrase: passphrase,
      );
      if (!mounted) return;
      _toast(l10n.sourcesImported(count));
    } on SourcesExportPassphraseException {
      if (!mounted) return;
      _toast(l10n.wrongPassphrase);
    } catch (_) {
      if (!mounted) return;
      _toast(l10n.sourcesImportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _promptPassphrase({
    required String title,
    required String body,
    required bool confirm,
  }) async {
    final l10n = context.l10n;
    final pass = TextEditingController();
    final pass2 = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body, style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 12),
            JavpTextField(
              controller: pass,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.exportPassphraseHint),
            ),
            if (confirm) ...[
              const SizedBox(height: 8),
              JavpTextField(
                controller: pass2,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.exportPassphraseConfirmHint,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final a = pass.text;
              if (a.trim().isEmpty) return;
              if (confirm && a != pass2.text) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.passphrasesDoNotMatch)),
                );
                return;
              }
              Navigator.pop(context, a);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    pass.dispose();
    pass2.dispose();
    return result;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
