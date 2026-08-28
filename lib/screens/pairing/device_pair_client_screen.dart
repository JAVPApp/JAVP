import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/screens/onboarding/sync_restore_screen.dart';
import 'package:javp/services/deep_links/javp_pair_link.dart';
import 'package:javp/services/pairing/device_pairing_client.dart';
import 'package:javp/services/pairing/pairing_sync_settings.dart';
import 'package:javp/services/storage/sources_export.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:provider/provider.dart';

/// Opens the LAN pair client after scanning / pasting a `javp://pair` link.
Future<void> openDevicePairClient(
  BuildContext context, {
  required JavpPairRequest request,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => DevicePairClientScreen(request: request),
    ),
  );
}

enum _PairDirection { send, receive }

class _TransferConfirm {
  const _TransferConfirm({
    required this.mode,
    required this.includeSyncSettings,
    this.addAsNewProfile = false,
  });

  final SourcesImportMode mode;
  final bool includeSyncSettings;
  final bool addAsNewProfile;
}

/// Phone/desktop guest UI: push local sources to a TV, or pull from it.
class DevicePairClientScreen extends StatefulWidget {
  const DevicePairClientScreen({
    super.key,
    required this.request,
  });

  final JavpPairRequest request;

  @override
  State<DevicePairClientScreen> createState() => _DevicePairClientScreenState();
}

class _DevicePairClientScreenState extends State<DevicePairClientScreen> {
  DevicePairingClient? _client;
  String? _status;
  String? _error;
  bool _busy = false;
  bool _ready = false;
  int? _hostSourceCount;
  List<DevicePairSourceInfo> _hostSources = const [];
  Set<String> _selectedLocalIds = {};
  Set<String> _selectedHostIds = {};
  _PairDirection? _direction;
  bool _hostSyncConfigured = false;
  bool _offerSyncSetup = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  Future<void> _connect() async {
    final client = DevicePairingClient(request: widget.request);
    try {
      final session = await client.fetchSession();
      if (!mounted) {
        client.close();
        return;
      }
      final localIds =
          context.read<LibraryProvider>().sources.map((s) => s.id).toSet();
      setState(() {
        _client = client;
        _ready = true;
        _hostSourceCount = session.sourceCount;
        _hostSources = session.sources;
        _hostSyncConfigured = session.syncConfigured;
        _selectedLocalIds = localIds;
        _selectedHostIds = session.sources.map((s) => s.id).toSet();
        _error = null;
      });
    } catch (e) {
      client.close();
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _ready = false;
      });
    }
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  /// Combined mode picker + impact preview + LAN secrets confirm.
  Future<_TransferConfirm?> _confirmTransfer({
    required bool sending,
    required int transferCount,
    required SourcesImportPreview mergePreview,
    required SourcesImportPreview replacePreview,
    required bool offerIncludeSync,
  }) {
    final l10n = context.l10n;
    return showDialog<_TransferConfirm>(
      context: context,
      builder: (context) {
        SourcesImportMode selected = SourcesImportMode.merge;
        var includeSync = offerIncludeSync;
        var addAsNewProfile = sending;
        return StatefulBuilder(
          builder: (context, setLocal) {
            final preview = selected == SourcesImportMode.merge
                ? mergePreview
                : replacePreview;
            return AlertDialog(
              backgroundColor: AppColors.surface,
              title: Text(
                sending
                    ? l10n.devicePairPushConfirmTitle
                    : l10n.devicePairPullConfirmTitle,
              ),
              content: SizedBox(
                width: 360,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        sending
                            ? (includeSync
                                ? l10n.devicePairPushConfirmBodyWithSync(
                                    transferCount,
                                  )
                                : l10n.devicePairPushConfirmBody(transferCount))
                            : (includeSync
                                ? l10n.devicePairPullConfirmBodyWithSync(
                                    transferCount,
                                  )
                                : l10n.devicePairPullConfirmBody(transferCount)),
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.devicePairImportModeTitle,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      _ModePreviewTile(
                        selected: selected == SourcesImportMode.merge,
                        title: l10n.importSourcesMerge,
                        subtitle: l10n.importSourcesMergeBody,
                        lines: _previewLines(
                          preview: mergePreview,
                          sending: sending,
                        ),
                        onTap: () => setLocal(
                          () => selected = SourcesImportMode.merge,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _ModePreviewTile(
                        selected: selected == SourcesImportMode.replace,
                        title: l10n.importSourcesReplace,
                        subtitle: l10n.importSourcesReplaceBody,
                        lines: _previewLines(
                          preview: replacePreview,
                          sending: sending,
                        ),
                        danger: replacePreview.removed > 0,
                        onTap: () => setLocal(
                          () => selected = SourcesImportMode.replace,
                        ),
                      ),
                      if (preview.removed > 0) ...[
                        const SizedBox(height: 12),
                        Text(
                          sending
                              ? l10n.devicePairPreviewReplaceWarningHost(
                                  preview.removed,
                                )
                              : l10n.devicePairPreviewReplaceWarningLocal(
                                  preview.removed,
                                ),
                          style: const TextStyle(
                            color: Color(0xFFFBBF24),
                            fontSize: 13,
                          ),
                        ),
                      ],
                      if (offerIncludeSync) ...[
                        const SizedBox(height: 16),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: includeSync,
                          onChanged: (v) =>
                              setLocal(() => includeSync = v ?? false),
                          title: Text(l10n.devicePairIncludeSyncSettings),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                      ],
                      if (sending) ...[
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: addAsNewProfile,
                          onChanged: (v) =>
                              setLocal(() => addAsNewProfile = v ?? false),
                          title: Text(l10n.devicePairAddAsNewProfile),
                          subtitle: Text(
                            l10n.devicePairAddAsNewProfileBlurb,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _TransferConfirm(
                      mode: selected,
                      includeSyncSettings: includeSync,
                      addAsNewProfile: addAsNewProfile,
                    ),
                  ),
                  child: Text(l10n.devicePairConfirmTransfer),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<String> _previewLines({
    required SourcesImportPreview preview,
    required bool sending,
  }) {
    final l10n = context.l10n;
    final lines = <String>[];
    if (preview.added > 0) {
      lines.add(l10n.devicePairPreviewAdded(preview.added));
    }
    if (preview.updated > 0) {
      lines.add(l10n.devicePairPreviewUpdated(preview.updated));
    }
    if (preview.mode == SourcesImportMode.merge && preview.kept > 0) {
      lines.add(l10n.devicePairPreviewKept(preview.kept));
    }
    if (preview.mode == SourcesImportMode.replace && preview.removed > 0) {
      lines.add(
        sending
            ? l10n.devicePairPreviewRemovedHost(preview.removed)
            : l10n.devicePairPreviewRemovedLocal(preview.removed),
      );
    }
    if (lines.isEmpty) {
      lines.add(l10n.devicePairPreviewNoChanges);
    }
    return lines;
  }

  Future<void> _push() async {
    final client = _client;
    if (client == null || _busy) return;
    final library = context.read<LibraryProvider>();
    final profiles = context.read<ProfileProvider>();
    final selected = library.sources
        .where((s) => _selectedLocalIds.contains(s.id))
        .toList(growable: false);
    final offerSync = profiles.syncSettings.isConfigured;
    if (selected.isEmpty && !offerSync) {
      setState(() => _status = library.sources.isEmpty
          ? context.l10n.devicePairNoLocalSources
          : context.l10n.devicePairNoneSelected);
      return;
    }
    final existingIds = _hostSources.map((s) => s.id);
    final incomingIds = selected.map((s) => s.id);
    final confirm = await _confirmTransfer(
      sending: true,
      transferCount: selected.length,
      mergePreview: previewSourcesImport(
        existingIds: existingIds,
        incomingIds: incomingIds,
        mode: SourcesImportMode.merge,
      ),
      replacePreview: previewSourcesImport(
        existingIds: existingIds,
        incomingIds: incomingIds,
        mode: SourcesImportMode.replace,
      ),
      offerIncludeSync: offerSync,
    );
    if (confirm == null || !mounted) return;
    if (selected.isEmpty &&
        !(confirm.addAsNewProfile && confirm.includeSyncSettings)) {
      setState(() => _status = context.l10n.devicePairNoneSelected);
      return;
    }

    setState(() {
      _busy = true;
      _status = null;
      _error = null;
      _offerSyncSetup = false;
    });
    try {
      final doc = await library.buildSourcesExport(
        secretsMode: SourcesSecretsMode.plaintext,
        sourceIds: selected.map((s) => s.id).toSet(),
      );
      final result = await client.pushSources(
        document: doc,
        mode: confirm.mode,
        syncSettings: confirm.includeSyncSettings
            ? profiles.syncSettings
            : null,
        addAsNewProfile: confirm.addAsNewProfile,
        profileName: profiles.activeProfile?.name,
      );
      if (!mounted) return;
      // Push applies sync on the host; guest may still need local setup if none.
      final offerSetup = !profiles.syncSettings.isConfigured;
      final sourcesDone = result.profileName != null
          ? context.l10n.devicePairPushDoneNewProfile(result.profileName!)
          : context.l10n.devicePairPushDone(result.count);
      try {
        final session = await client.fetchSession();
        if (!mounted) return;
        setState(() {
          _busy = false;
          _status = _statusAfterTransfer(
            sourcesDone: sourcesDone,
            syncApply: result.syncApply,
            onHost: true,
          );
          _hostSourceCount = session.sourceCount;
          _hostSources = session.sources;
          _hostSyncConfigured = session.syncConfigured;
          _selectedHostIds = session.sources.map((s) => s.id).toSet();
          _offerSyncSetup = offerSetup;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _status = _statusAfterTransfer(
            sourcesDone: sourcesDone,
            syncApply: result.syncApply,
            onHost: true,
          );
          _hostSourceCount = result.count;
          _offerSyncSetup = offerSetup;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _pull() async {
    final client = _client;
    if (client == null || _busy) return;
    if (_hostSources.isEmpty && (_hostSourceCount ?? 0) <= 0) {
      setState(() => _status = context.l10n.devicePairNoHostSources);
      return;
    }
    final selectedIds = Set<String>.from(_selectedHostIds);
    if (_hostSources.isNotEmpty && selectedIds.isEmpty) {
      setState(() => _status = context.l10n.devicePairNoneSelected);
      return;
    }
    final library = context.read<LibraryProvider>();
    final profiles = context.read<ProfileProvider>();
    final existingIds = library.sources.map((s) => s.id);
    final incomingIds = _hostSources.isNotEmpty
        ? selectedIds
        : <String>{}; // unknown ids — preview stays empty-ish
    final transferCount = _hostSources.isNotEmpty
        ? selectedIds.length
        : (_hostSourceCount ?? 0);
    final confirm = await _confirmTransfer(
      sending: false,
      transferCount: transferCount,
      mergePreview: previewSourcesImport(
        existingIds: existingIds,
        incomingIds: incomingIds,
        mode: SourcesImportMode.merge,
      ),
      replacePreview: previewSourcesImport(
        existingIds: existingIds,
        incomingIds: incomingIds,
        mode: SourcesImportMode.replace,
      ),
      offerIncludeSync: _hostSyncConfigured,
    );
    if (confirm == null || !mounted) return;

    setState(() {
      _busy = true;
      _status = null;
      _error = null;
      _offerSyncSetup = false;
    });
    try {
      final pulled = await client.pullSources(
        sourceIds: _hostSources.isEmpty ? null : selectedIds,
        includeSyncSettings: confirm.includeSyncSettings,
      );
      if (!mounted) return;
      final count = await library.importSourcesDocument(
        document: pulled.document,
        mode: confirm.mode,
      );
      if (!mounted) return;
      PairingSyncApplyResult? syncApply;
      if (pulled.syncSettings != null) {
        syncApply = await applyPairingSyncSettings(
          profiles: profiles,
          incoming: pulled.syncSettings!,
        );
      }
      if (!mounted) return;
      final offerSetup = syncApply?.needsLocalFolderSetup == true ||
          !profiles.syncSettings.isConfigured;
      setState(() {
        _busy = false;
        _status = _statusAfterTransfer(
          sourcesDone: context.l10n.devicePairPullDone(count),
          syncApply: syncApply,
          onHost: false,
        );
        _selectedLocalIds = library.sources.map((s) => s.id).toSet();
        _offerSyncSetup = offerSetup;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  String _statusAfterTransfer({
    required String sourcesDone,
    required PairingSyncApplyResult? syncApply,
    required bool onHost,
  }) {
    if (syncApply == null) return sourcesDone;
    final l10n = context.l10n;
    if (syncApply.needsLocalFolderSetup) {
      return '$sourcesDone\n${l10n.devicePairSyncNeedsFolder}';
    }
    if (syncApply.applied) {
      return onHost
          ? '$sourcesDone\n${l10n.devicePairSyncAppliedHost}'
          : '$sourcesDone\n${l10n.devicePairSyncAppliedLocal}';
    }
    return sourcesDone;
  }

  Future<void> _openSyncSetup() async {
    await showSyncRestoreScreen(context);
    if (!mounted) return;
    setState(() {
      _offerSyncSetup =
          !context.read<ProfileProvider>().syncSettings.isConfigured;
    });
  }

  void _setAllLocal(bool selected, List<IptvSource> sources) {
    setState(() {
      _selectedLocalIds =
          selected ? sources.map((s) => s.id).toSet() : <String>{};
    });
  }

  void _setAllHost(bool selected) {
    setState(() {
      _selectedHostIds =
          selected ? _hostSources.map((s) => s.id).toSet() : <String>{};
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final localSources =
        context.select<LibraryProvider, List<IptvSource>>((l) => l.sources);
    final req = widget.request;
    final canSend = localSources.isNotEmpty;
    final canReceive =
        _hostSources.isNotEmpty || (_hostSourceCount ?? 0) > 0;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(l10n.devicePairTitle),
        leading: _direction != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _direction = null;
                          _status = null;
                        }),
              )
            : null,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Text(
            l10n.devicePairClientBlurb,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textMuted,
                ),
          ),
          const SizedBox(height: 16),
          Text(
            '${req.host}:${req.port}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (_hostSourceCount != null) ...[
            const SizedBox(height: 6),
            Text(
              l10n.devicePairHostSources(_hostSourceCount!),
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            l10n.iptvSourcesCount(localSources.length),
            style: const TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: 24),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFF87171)),
              ),
            ),
          if (!_ready && _error == null)
            const Center(child: CircularProgressIndicator())
          else if (_ready && _direction == null) ...[
            Text(
              l10n.devicePairDirectionTitle,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            _DirectionCard(
              icon: Icons.upload_rounded,
              title: l10n.devicePairDirectionSend,
              blurb: l10n.devicePairDirectionSendBlurb,
              enabled: canSend && !_busy,
              onTap: () => setState(() {
                _direction = _PairDirection.send;
                _status = null;
              }),
            ),
            const SizedBox(height: 12),
            _DirectionCard(
              icon: Icons.download_rounded,
              title: l10n.devicePairDirectionReceive,
              blurb: l10n.devicePairDirectionReceiveBlurb,
              enabled: canReceive && !_busy,
              onTap: () => setState(() {
                _direction = _PairDirection.receive;
                _status = null;
              }),
            ),
            if (!canSend || !canReceive) ...[
              const SizedBox(height: 16),
              Text(
                !canSend && !canReceive
                    ? l10n.devicePairDirectionNeither
                    : !canSend
                        ? l10n.devicePairNoLocalSources
                        : l10n.devicePairNoHostSources,
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ],
          ] else if (_ready && _direction == _PairDirection.send) ...[
            _PairSectionHeader(
              title: l10n.devicePairSelectLocalTitle,
              selected: _selectedLocalIds.length,
              total: localSources.length,
              onSelectAll: () => _setAllLocal(true, localSources),
              onSelectNone: () => _setAllLocal(false, localSources),
            ),
            const SizedBox(height: 8),
            for (final source in localSources)
              _SourceCheckTile(
                name: source.name,
                type: source.type.name,
                icon: _iconForTypeName(source.type.name),
                selected: _selectedLocalIds.contains(source.id),
                enabled: !_busy,
                onChanged: (v) {
                  setState(() {
                    if (v) {
                      _selectedLocalIds = {..._selectedLocalIds, source.id};
                    } else {
                      _selectedLocalIds = {..._selectedLocalIds}
                        ..remove(source.id);
                    }
                  });
                },
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _push,
              icon: const Icon(Icons.upload_rounded),
              label: Text(l10n.devicePairPush),
            ),
          ] else if (_ready && _direction == _PairDirection.receive) ...[
            if (_hostSources.isNotEmpty) ...[
              _PairSectionHeader(
                title: l10n.devicePairSelectHostTitle,
                selected: _selectedHostIds.length,
                total: _hostSources.length,
                onSelectAll: () => _setAllHost(true),
                onSelectNone: () => _setAllHost(false),
              ),
              const SizedBox(height: 8),
              for (final source in _hostSources)
                _SourceCheckTile(
                  name: source.name,
                  type: source.type,
                  icon: _iconForTypeName(source.type),
                  selected: _selectedHostIds.contains(source.id),
                  enabled: !_busy,
                  onChanged: (v) {
                    setState(() {
                      if (v) {
                        _selectedHostIds = {..._selectedHostIds, source.id};
                      } else {
                        _selectedHostIds = {..._selectedHostIds}
                          ..remove(source.id);
                      }
                    });
                  },
                ),
              const SizedBox(height: 16),
            ] else
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  l10n.devicePairHostSources(_hostSourceCount ?? 0),
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pull,
              icon: const Icon(Icons.download_rounded),
              label: Text(l10n.devicePairPull),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_status != null) ...[
            const SizedBox(height: 20),
            Text(
              _status!,
              style: const TextStyle(
                color: AppColors.live,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (_offerSyncSetup && !_busy) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _openSyncSetup,
              icon: const Icon(Icons.cloud_sync_outlined),
              label: Text(l10n.devicePairSetupProfileSync),
            ),
          ],
        ],
      ),
    );
  }
}

class _DirectionCard extends StatelessWidget {
  const _DirectionCard({
    required this.icon,
    required this.title,
    required this.blurb,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String blurb;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: AppColors.accent, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        blurb,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModePreviewTile extends StatelessWidget {
  const _ModePreviewTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.lines,
    required this.onTap,
    this.danger = false,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final List<String> lines;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final border = selected
        ? (danger ? const Color(0xFFFBBF24) : AppColors.accent)
        : AppColors.border;
    return Material(
      color: selected
          ? AppColors.accent.withValues(alpha: 0.08)
          : AppColors.bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border, width: selected ? 1.5 : 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: selected ? border : AppColors.textMuted,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final line in lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '• $line',
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PairSectionHeader extends StatelessWidget {
  const _PairSectionHeader({
    required this.title,
    required this.selected,
    required this.total,
    required this.onSelectAll,
    required this.onSelectNone,
  });

  final String title;
  final int selected;
  final int total;
  final VoidCallback onSelectAll;
  final VoidCallback onSelectNone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.devicePairSelectedCount(selected, total),
                style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: onSelectAll,
              child: Text(l10n.devicePairSelectAll),
            ),
            TextButton(
              onPressed: onSelectNone,
              child: Text(l10n.devicePairSelectNone),
            ),
          ],
        ),
      ],
    );
  }
}

class _SourceCheckTile extends StatelessWidget {
  const _SourceCheckTile({
    required this.name,
    required this.type,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final String name;
  final String type;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      value: selected,
      onChanged: enabled ? (v) => onChanged(v ?? false) : null,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: AppColors.accent),
      title: Text(
        name,
        style: const TextStyle(
          color: AppColors.text,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        _typeLabel(type),
        style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
      ),
    );
  }
}

IconData _iconForTypeName(String type) {
  return switch (type) {
    'm3u' => Icons.playlist_play_rounded,
    'xtream' => Icons.cloud_outlined,
    'stalker' => Icons.router_outlined,
    'custom' => Icons.data_object_rounded,
    'jellyfin' => Icons.dashboard_customize_outlined,
    'emby' => Icons.live_tv_outlined,
    'plex' => Icons.grid_view_rounded,
    'xmltv' => Icons.event_note_outlined,
    _ => Icons.link_rounded,
  };
}

String _typeLabel(String type) {
  return switch (type) {
    'm3u' => 'M3U',
    'xtream' => 'Xtream',
    'stalker' => 'Stalker',
    'custom' => 'Catalog',
    'jellyfin' => 'Jellyfin',
    'emby' => 'Emby',
    'plex' => 'Plex',
    'xmltv' => 'XMLTV',
    _ => type,
  };
}

/// Manual host + PIN entry when the QR was not scanned into the app.
class DevicePairManualScreen extends StatefulWidget {
  const DevicePairManualScreen({super.key});

  @override
  State<DevicePairManualScreen> createState() => _DevicePairManualScreenState();
}

class _DevicePairManualScreenState extends State<DevicePairManualScreen> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '19287');
  final _pinCtrl = TextEditingController();

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  void _continue() {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 19287;
    final pin = _pinCtrl.text.trim().toUpperCase();
    if (host.isEmpty || pin.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.devicePairManualIncomplete)),
      );
      return;
    }
    final request = JavpPairRequest(
      host: host,
      port: port,
      token: '',
      pin: pin,
    );
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DevicePairClientScreen(request: request),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(l10n.devicePairManualTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Text(
            l10n.devicePairManualBlurb,
            style: const TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: 20),
          JavpTextField(
            controller: _hostCtrl,
            decoration: InputDecoration(labelText: l10n.devicePairHostHint),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          JavpTextField(
            controller: _portCtrl,
            decoration: InputDecoration(labelText: l10n.devicePairPortHint),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          JavpTextField(
            controller: _pinCtrl,
            decoration: InputDecoration(labelText: l10n.devicePairPinHint),
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _continue,
            child: Text(l10n.continueAction),
          ),
        ],
      ),
    );
  }
}
