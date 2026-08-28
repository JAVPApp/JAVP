import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';

/// Result of [SourceAddConfirmDialog].
enum SourceAddConfirmAction { cancel, edit, completed }

/// Add/sync confirmation that stays open with a spinner until the work
/// finishes — so a slow catalog probe does not look like a no-op.
class SourceAddConfirmDialog extends StatefulWidget {
  const SourceAddConfirmDialog({
    super.key,
    required this.title,
    required this.summary,
    required this.primaryLabel,
    required this.busyLabel,
    required this.onConfirm,
    this.showEdit = false,
  });

  final String title;
  final String summary;
  final String primaryLabel;
  final String busyLabel;
  final Future<void> Function() onConfirm;
  final bool showEdit;

  @override
  State<SourceAddConfirmDialog> createState() => _SourceAddConfirmDialogState();
}

class _SourceAddConfirmDialogState extends State<SourceAddConfirmDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm();
      if (!mounted) return;
      Navigator.pop(context, SourceAddConfirmAction.completed);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _busy) return;
        Navigator.pop(context, SourceAddConfirmAction.cancel);
      },
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.summary),
            if (_busy) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.busyLabel,
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                widget.showEdit ? l10n.couldNotAddSource(_error!) : _error!,
                style: const TextStyle(color: AppColors.accent),
              ),
            ],
          ],
        ),
        actions: [
          AppActionButton(
            variant: AppActionButtonVariant.text,
            enabled: !_busy,
            onPressed: () =>
                Navigator.pop(context, SourceAddConfirmAction.cancel),
            label: l10n.back,
          ),
          if (widget.showEdit)
            AppActionButton(
              variant: AppActionButtonVariant.text,
              enabled: !_busy,
              onPressed: () =>
                  Navigator.pop(context, SourceAddConfirmAction.edit),
              label: l10n.editEllipsis,
            ),
          AppActionButton(
            busy: _busy,
            onPressed: _busy ? null : _run,
            label: _busy ? widget.busyLabel : widget.primaryLabel,
          ),
        ],
      ),
    );
  }
}
