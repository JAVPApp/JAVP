import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:javp/models/app_update_info.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/update_provider.dart';
import 'package:javp/services/platform/external_browser.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:provider/provider.dart';

Future<void> showUpdateDialog(
  BuildContext context, {
  bool fromSettings = false,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    // Keep D-pad inside the sheet — otherwise Android TV leaks focus to the
    // shell rail / Home behind the modal ("remote still drives the back UI").
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    builder: (context) => UpdateAvailableDialog(fromSettings: fromSettings),
  );
}

class UpdateAvailableDialog extends StatefulWidget {
  const UpdateAvailableDialog({super.key, this.fromSettings = false});

  final bool fromSettings;

  @override
  State<UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<UpdateAvailableDialog> {
  final _scope = FocusScopeNode(debugLabel: 'updateDialog');
  final _laterNode = FocusNode(debugLabel: 'updateLater');
  final _ignoreNode = FocusNode(debugLabel: 'updateIgnore');
  final _primaryNode = FocusNode(debugLabel: 'updatePrimary');

  @override
  void initState() {
    super.initState();
    // Early handler runs before WidgetsApp DirectionalFocusIntent — needed on
    // Fire TV where FocusScope/CallbackShortcuts onKeyEvent still lose arrows.
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _primaryNode.requestFocus();
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    _scope.dispose();
    _laterNode.dispose();
    _ignoreNode.dispose();
    _primaryNode.dispose();
    super.dispose();
  }

  bool get _dialogOwnsFocus {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    return primary == _scope ||
        primary == _laterNode ||
        primary == _ignoreNode ||
        primary == _primaryNode ||
        primary.ancestors.contains(_scope);
  }

  bool _nodeAlive(FocusNode node) =>
      node.canRequestFocus && node.context != null;

  KeyEventResult _onEarlyKey(KeyEvent event) {
    if (!TvPlatform.isAndroidTv) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_dialogOwnsFocus) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final laterAlive = _nodeAlive(_laterNode);
    final ignoreAlive = _nodeAlive(_ignoreNode);
    final primaryAlive = _nodeAlive(_primaryNode);

    // Two-row layout: Later | Ignore on top, Download below. Do not require
    // _primaryNode.hasFocus — highlight can lie on TV.
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_ignoreNode.hasFocus && laterAlive) {
        _laterNode.requestFocus();
      } else if (laterAlive) {
        _laterNode.requestFocus();
      } else if (ignoreAlive) {
        _ignoreNode.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_laterNode.hasFocus && ignoreAlive) {
        _ignoreNode.requestFocus();
      } else if (primaryAlive) {
        _primaryNode.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (laterAlive) {
        _laterNode.requestFocus();
      } else if (ignoreAlive) {
        _ignoreNode.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (primaryAlive) _primaryNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final update = context.read<UpdateProvider>();
    final status = context.select<UpdateProvider, UpdateStatus>(
      (u) => u.status,
    );
    final info = context.select<UpdateProvider, AppUpdateInfo?>(
      (u) => u.available,
    );
    final forceRequired = context.select<UpdateProvider, bool>(
      (u) => u.forceRequired,
    );
    final downloading = status == UpdateStatus.downloading;
    final installing = status == UpdateStatus.installing;
    final ready = status == UpdateStatus.readyToInstall;
    final busy = downloading || installing || status == UpdateStatus.checking;
    final tv = TvPlatform.isAndroidTv;
    final showDismiss = !forceRequired && !busy;

    Future<void> dismiss() async {
      if (context.mounted) Navigator.pop(context);
    }

    Future<void> ignoreVersion() async {
      await update.skipAvailable();
      if (context.mounted) Navigator.pop(context);
    }

    Future<void> downloadOrInstall() async {
      try {
        if (!ready) await update.download();
        await update.install();
      } catch (_) {
        // Error surfaced via provider.
      }
    }

    final dismissLabel = widget.fromSettings ? l10n.close : l10n.later;

    if (!tv) {
      return AlertDialog(
        backgroundColor: AppColors.surface,
        scrollable: true,
        title: Text(forceRequired ? l10n.updateRequired : l10n.updateAvailable),
        content: _UpdateBody(
          info: info,
          currentLabel: update.currentLabel,
          currentVersionCode: update.currentVersionCode,
          currentVersionName: update.currentVersionName,
          downloading: downloading,
          installing: installing,
        ),
        actions: [
          if (showDismiss) ...[
            AppActionButton(
              variant: AppActionButtonVariant.text,
              onPressed: dismiss,
              label: dismissLabel,
            ),
            AppActionButton(
              variant: AppActionButtonVariant.text,
              onPressed: ignoreVersion,
              label: l10n.ignoreThisVersion,
            ),
          ],
          _UpdatePrimaryButton(
            busy: busy,
            ready: ready,
            downloading: downloading,
            installing: installing,
            onPressed: busy ? null : downloadOrInstall,
          ),
        ],
      );
    }

    // Custom card + explicit action rows — OverflowBar + Material buttons do
    // not traverse reliably with leanback D-pad on Fire TV.
    return FocusScope(
      node: _scope,
      child: Dialog(
        backgroundColor: AppColors.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  forceRequired ? l10n.updateRequired : l10n.updateAvailable,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                _UpdateBody(
                  info: info,
                  currentLabel: update.currentLabel,
                  currentVersionCode: update.currentVersionCode,
                  currentVersionName: update.currentVersionName,
                  downloading: downloading,
                  installing: installing,
                ),
                const SizedBox(height: 20),
                if (showDismiss) ...[
                  Row(
                    children: [
                      Expanded(
                        child: AppActionButton(
                          focusNode: _laterNode,
                          expand: true,
                          variant: AppActionButtonVariant.text,
                          onPressed: dismiss,
                          label: dismissLabel,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AppActionButton(
                          focusNode: _ignoreNode,
                          expand: true,
                          variant: AppActionButtonVariant.text,
                          onPressed: ignoreVersion,
                          label: l10n.ignoreThisVersion,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                _UpdatePrimaryButton(
                  focusNode: _primaryNode,
                  autofocus: true,
                  expand: true,
                  busy: busy,
                  ready: ready,
                  downloading: downloading,
                  installing: installing,
                  onPressed: busy ? null : downloadOrInstall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdatePrimaryButton extends StatelessWidget {
  const _UpdatePrimaryButton({
    required this.busy,
    required this.ready,
    required this.downloading,
    required this.installing,
    required this.onPressed,
    this.focusNode,
    this.expand = false,
    this.autofocus = false,
  });

  final bool busy;
  final bool ready;
  final bool downloading;
  final bool installing;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool expand;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isDesktopZip = context.select<UpdateProvider, bool>(
      (u) => u.isDesktopZipTarget,
    );
    final progress = context.select<UpdateProvider, double>(
      (u) => u.downloadProgress,
    );
    final String label;
    if (ready) {
      label = isDesktopZip ? l10n.installAndRestart : l10n.install;
    } else if (installing) {
      label = l10n.installingEllipsis;
    } else if (downloading) {
      label = progress <= 0
          ? l10n.downloadingEllipsis
          : l10n.downloadingPercent((progress * 100).round());
    } else {
      label = l10n.downloadAndInstall;
    }
    return AppActionButton(
      focusNode: focusNode,
      autofocus: autofocus,
      expand: expand,
      enabled: !busy,
      onPressed: onPressed,
      label: label,
    );
  }
}

class _UpdateBody extends StatelessWidget {
  const _UpdateBody({
    required this.info,
    required this.currentLabel,
    required this.currentVersionCode,
    required this.currentVersionName,
    required this.downloading,
    required this.installing,
  });

  final AppUpdateInfo? info;
  final String currentLabel;
  final int currentVersionCode;
  final String currentVersionName;
  final bool downloading;
  final bool installing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = context.select<UpdateProvider, String?>((u) => u.error);
    final notes =
        info
            ?.changelogFor(
              currentVersionCode: currentVersionCode,
              currentVersionName: currentVersionName,
            )
            .trim() ??
        '';
    final maxNotesHeight = (MediaQuery.sizeOf(context).height * 0.45).clamp(
      160.0,
      420.0,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          info == null
              ? l10n.newerBuildReady
              : l10n.updateVersionAvailable(
                  info!.versionName,
                  '${info!.versionCode}',
                  currentLabel,
                ),
          style: const TextStyle(color: AppColors.textMuted),
        ),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxNotesHeight),
            child: SingleChildScrollView(child: _ChangelogMarkdown(notes)),
          ),
        ],
        if (downloading || installing) const _UpdateProgressMeter(),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(
            error,
            style: const TextStyle(color: AppColors.accent, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _UpdateProgressMeter extends StatelessWidget {
  const _UpdateProgressMeter();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final installing = context.select<UpdateProvider, bool>(
      (u) => u.status == UpdateStatus.installing,
    );
    final progress = context.select<UpdateProvider, double>(
      (u) => u.downloadProgress,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: installing || progress <= 0 ? null : progress,
          color: AppColors.accent,
          backgroundColor: AppColors.border,
        ),
        const SizedBox(height: 8),
        Text(
          installing
              ? l10n.installingEllipsis
              : progress <= 0
              ? l10n.downloadingEllipsis
              : l10n.downloadingPercent((progress * 100).round()),
          style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      ],
    );
  }
}

/// Compact markdown for updater notes (`##` version, `###` section, lists, bold).
class _ChangelogMarkdown extends StatelessWidget {
  const _ChangelogMarkdown(this.data);

  final String data;

  static MarkdownStyleSheet _style(BuildContext context) {
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(color: AppColors.text, fontSize: 14, height: 1.35),
      h1: const TextStyle(
        color: AppColors.text,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      h2: const TextStyle(
        color: AppColors.text,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      h3: const TextStyle(
        color: AppColors.accentHi,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      h4: const TextStyle(
        color: AppColors.text,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      strong: const TextStyle(
        color: AppColors.text,
        fontWeight: FontWeight.w700,
      ),
      em: const TextStyle(color: AppColors.text, fontStyle: FontStyle.italic),
      listBullet: const TextStyle(color: AppColors.text, fontSize: 14),
      a: const TextStyle(
        color: AppColors.accentHi,
        decoration: TextDecoration.underline,
      ),
      blockSpacing: 8,
      listIndent: 20,
      h2Padding: const EdgeInsets.only(top: 4, bottom: 4),
      h3Padding: const EdgeInsets.only(top: 8, bottom: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: false,
      shrinkWrap: true,
      styleSheet: _style(context),
      onTapLink: (_, href, _) {
        if (href == null || href.isEmpty) return;
        ExternalBrowser.open(href);
      },
    );
  }
}
