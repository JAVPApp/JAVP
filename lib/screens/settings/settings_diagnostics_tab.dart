import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

/// Settings → Diagnostics: the user-facing half of [JavpLog].
///
/// A sideloaded TV build has no reachable console, so this is the only way a
/// user can hand over what the app saw. Share (temp file) is preferred for
/// Discord attach; copy remains for quick paste. Nothing is uploaded by JAVP.
class SettingsDiagnosticsTab extends StatefulWidget {
  const SettingsDiagnosticsTab({super.key});

  @override
  State<SettingsDiagnosticsTab> createState() => _SettingsDiagnosticsTabState();
}

class _SettingsDiagnosticsTabState extends State<SettingsDiagnosticsTab> {
  final JavpLog _log = JavpLog.instance;
  bool _enabled = true;
  bool _verboseHitch = false;
  int _usage = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _enabled = _log.enabled;
    _verboseHitch = _log.verboseHitch;
    _log.revision.addListener(_syncFromLog);
    _refreshUsage();
    // Prefs restore finishes after start(); refresh so the toggle matches.
    unawaited(_log.ensureVerboseHitchReady().then((_) => _syncFromLog()));
  }

  @override
  void dispose() {
    _log.revision.removeListener(_syncFromLog);
    super.dispose();
  }

  void _syncFromLog() {
    if (!mounted) return;
    setState(() {
      _enabled = _log.enabled;
      _verboseHitch = _log.verboseHitch;
    });
  }

  void _refreshUsage() {
    _log.diskUsage().then((bytes) {
      if (!mounted) return;
      setState(() => _usage = bytes);
    });
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _enabled = value);
    await _log.setEnabled(value);
    if (!mounted) return;
    _refreshUsage();
  }

  Future<void> _setVerboseHitch(bool value) async {
    setState(() => _verboseHitch = value);
    await _log.setVerboseHitch(value);
  }

  Future<void> _share() async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = context.l10n.diagnosticsShareFailed;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _busy = true);
    try {
      // Linux share_plus cannot attach files; fall back to redacted text.
      if (Platform.isLinux) {
        final text = await _log.exportText();
        await SharePlus.instance.share(
          ShareParams(
            text: text.isEmpty ? '(empty log)' : text,
            subject: 'JAVP diagnostics log',
            title: 'JAVP diagnostics',
            sharePositionOrigin: origin,
          ),
        );
      } else {
        final file = await _log.exportShareFile();
        // Windows DataTransfer fails with "Try that again" when the share has
        // no text and GetFileFromPathAsync rejects Dart-style '/' in temp
        // paths — so normalize separators and always send a short text body.
        final sharePath = Platform.isWindows
            ? file.path.replaceAll('/', r'\')
            : file.path;
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile(
                sharePath,
                mimeType: 'text/plain',
                name: 'javp-diagnostics.log',
              ),
            ],
            text: Platform.isWindows ? 'JAVP diagnostics log' : null,
            subject: 'JAVP diagnostics log',
            title: 'JAVP diagnostics',
            sharePositionOrigin: origin,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    final copied = context.l10n.diagnosticsLogCopied;
    setState(() => _busy = true);
    final text = await _log.exportText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(content: Text(copied)));
  }

  Future<void> _openFolder() async {
    final path = await _log.directoryPath();
    if (path.isEmpty) return;
    await OpenFilex.open(path);
  }

  Future<void> _clear() async {
    final messenger = ScaffoldMessenger.of(context);
    final cleared = context.l10n.diagnosticsLogsCleared;
    setState(() => _busy = true);
    await _log.clear();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _usage = 0;
    });
    messenger.showSnackBar(SnackBar(content: Text(cleared)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(l10n.diagnosticsLogging, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          l10n.diagnosticsPrivacyNotice,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        SettingsSwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.diagnosticsLogging),
          subtitle: Text(l10n.diagnosticsLoggingSubtitle),
          value: _enabled,
          onChanged: _busy ? null : (v) => _setEnabled(v),
        ),
        SettingsSwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.diagnosticsVerboseHitch),
          subtitle: Text(l10n.diagnosticsVerboseHitchSubtitle),
          value: _verboseHitch,
          onChanged: !_enabled || _busy ? null : (v) => _setVerboseHitch(v),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.diagnosticsStorageUsed(_formatBytes(_usage)),
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _share,
              icon: const Icon(Icons.share_outlined, size: 18),
              label: Text(l10n.diagnosticsShareLog),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _copy,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: Text(l10n.diagnosticsCopyLog),
            ),
            if (DesktopUi.enabled)
              OutlinedButton.icon(
                onPressed: _busy ? null : _openFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: Text(l10n.diagnosticsOpenFolder),
              ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _clear,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(l10n.diagnosticsClearLogs),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.diagnosticsShareHint,
          style: const TextStyle(color: AppColors.textDim, fontSize: 12),
        ),
        const SizedBox(height: 20),
        Text(
          l10n.diagnosticsRecentEntries,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        // Reads the in-memory ring buffer, which is bumped once per flush, so
        // opening this screen never touches the log files.
        ValueListenableBuilder<int>(
          valueListenable: _log.revision,
          builder: (context, _, _) => _Viewer(lines: _log.recentLines),
        ),
      ],
    );
  }
}

class _Viewer extends StatelessWidget {
  const _Viewer({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(AppRadius.md),
    );
    if (lines.isEmpty) {
      return Container(
        width: double.infinity,
        decoration: decoration,
        padding: const EdgeInsets.all(16),
        child: Text(
          context.l10n.diagnosticsNoEntries,
          style: const TextStyle(color: AppColors.textDim),
        ),
      );
    }
    // Newest first: the reason someone opened this screen just happened.
    final ordered = lines.reversed.toList(growable: false);
    return Container(
      decoration: decoration,
      constraints: const BoxConstraints(maxHeight: 360),
      padding: const EdgeInsets.all(12),
      child: Scrollbar(
        child: ListView.builder(
          primary: false,
          shrinkWrap: true,
          itemCount: ordered.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              ordered[index],
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.35,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 10 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
