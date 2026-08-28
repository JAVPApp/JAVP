import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/parental_lock_provider.dart';
import 'package:javp/services/storage/parental_controls_store.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:provider/provider.dart';

/// Dialog PIN entry for parental unlock.
Future<bool> showParentalUnlockDialog(
  BuildContext context, {
  String? title,
  String? message,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ParentalPinDialog(
      title: title ?? context.l10n.parentalUnlockTitle,
      message: message ?? context.l10n.parentalUnlockMessage,
      confirmLabel: context.l10n.unlock,
    ),
  );
  return result == true;
}

/// When parental content is locked, prompt for PIN before source management.
///
/// Returns true when unlocked (or no PIN / already unlocked).
Future<bool> ensureParentalUnlockedForSources(BuildContext context) async {
  final parental = context.read<ParentalLockProvider>();
  if (!parental.hasPin || !parental.isContentLocked) return true;
  final ok = await showParentalUnlockDialog(context);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.parentalUnlockToManageSources)),
    );
  }
  return ok;
}

Future<String?> showParentalPinEditorDialog(
  BuildContext context, {
  required String title,
  String? message,
  bool requireCurrent = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ParentalPinDialog(
      title: title,
      message: message,
      confirmLabel: context.l10n.save,
      requireCurrent: requireCurrent,
      returnPin: true,
    ),
  );
}

class ParentalUnlockOverlay extends StatelessWidget {
  const ParentalUnlockOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final locked = context.select<ParentalLockProvider, bool>(
      (p) => p.isAppLocked,
    );
    if (!locked) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Keep the tree mounted for state, but block pointer + focus passthrough.
        ExcludeFocus(
          child: IgnorePointer(child: child),
        ),
        const ColoredBox(color: Color(0xE60B0C0F)),
        const Center(child: _InlineUnlockCard()),
      ],
    );
  }
}

class _InlineUnlockCard extends StatefulWidget {
  const _InlineUnlockCard();

  @override
  State<_InlineUnlockCard> createState() => _InlineUnlockCardState();
}

class _InlineUnlockCardState extends State<_InlineUnlockCard> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await context.read<ParentalLockProvider>().unlock(_pin.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _error = context.l10n.parentalPinIncorrect;
    });
    if (ok) _pin.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.parentalAppLockedTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.parentalAppLockedMessage,
                style: const TextStyle(color: AppColors.textMuted),
              ),
              const SizedBox(height: 16),
              JavpTextField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                autofocus: true,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: InputDecoration(
                  labelText: context.l10n.parentalPinLabel,
                  errorText: _error,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              AppActionButton(
                expand: true,
                onPressed: _busy ? null : _submit,
                label: context.l10n.unlock,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParentalPinDialog extends StatefulWidget {
  const _ParentalPinDialog({
    required this.title,
    required this.confirmLabel,
    this.message,
    this.requireCurrent = false,
    this.returnPin = false,
  });

  final String title;
  final String? message;
  final String confirmLabel;
  final bool requireCurrent;
  final bool returnPin;

  @override
  State<_ParentalPinDialog> createState() => _ParentalPinDialogState();
}

class _ParentalPinDialogState extends State<_ParentalPinDialog> {
  final _current = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final parental = context.read<ParentalLockProvider>();
    try {
      if (widget.returnPin) {
        final pin = _pin.text.trim();
        if (pin != _confirm.text.trim()) {
          setState(() {
            _error = context.l10n.parentalPinMismatch;
            _busy = false;
          });
          return;
        }
        if (widget.requireCurrent) {
          final ok = await parental.verifyOnly(_current.text);
          if (!ok) {
            setState(() {
              _error = context.l10n.parentalPinIncorrect;
              _busy = false;
            });
            return;
          }
        }
        ParentalControlsStore.assertPinShape(pin);
        if (!mounted) return;
        Navigator.pop(context, pin);
        return;
      }

      final ok = await parental.unlock(_pin.text);
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _error = context.l10n.parentalPinIncorrect;
          _busy = false;
        });
        return;
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ArgumentError ? '${e.message}' : '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.message != null) ...[
            Text(
              widget.message!,
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.requireCurrent) ...[
            JavpTextField(
              controller: _current,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: context.l10n.parentalCurrentPinLabel,
              ),
            ),
            const SizedBox(height: 10),
          ],
          JavpTextField(
            controller: _pin,
            obscureText: true,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(8),
            ],
            decoration: InputDecoration(
              labelText: widget.returnPin
                  ? context.l10n.parentalNewPinLabel
                  : context.l10n.parentalPinLabel,
              errorText: _error,
            ),
            onSubmitted: widget.returnPin ? null : (_) => _submit(),
          ),
          if (widget.returnPin) ...[
            const SizedBox(height: 10),
            JavpTextField(
              controller: _confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: context.l10n.parentalConfirmPinLabel,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ],
      ),
      actions: [
        AppActionButton(
          variant: AppActionButtonVariant.text,
          onPressed: _busy ? null : () => Navigator.pop(context),
          label: context.l10n.cancel,
        ),
        AppActionButton(
          onPressed: _busy ? null : _submit,
          label: widget.confirmLabel,
        ),
      ],
    );
  }
}
