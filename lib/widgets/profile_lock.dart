import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/providers/shell_actions.dart';
import 'package:javp/services/storage/pin_hash.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:provider/provider.dart';

/// PIN entry to open a locked profile.
Future<bool> showProfileUnlockDialog(
  BuildContext context, {
  required String profileName,
  required Future<bool> Function(String pin) verify,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ProfilePinDialog(
      title: context.l10n.profilePinUnlockTitle(profileName),
      message: context.l10n.profilePinUnlockMessage,
      confirmLabel: context.l10n.unlock,
      verify: verify,
    ),
  );
  return result == true;
}

/// Set / change a profile lock PIN. Returns the new PIN, or null if cancelled.
Future<String?> showProfilePinEditorDialog(
  BuildContext context, {
  required String title,
  String? message,
  Future<bool> Function(String current)? verifyCurrent,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ProfilePinDialog(
      title: title,
      message: message,
      confirmLabel: context.l10n.save,
      verifyCurrent: verifyCurrent,
      returnPin: true,
    ),
  );
}

Future<String?> showProfilePinPromptDialog(
  BuildContext context, {
  required String title,
  String? message,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ProfilePinDialog(
      title: title,
      message: message,
      confirmLabel: context.l10n.unlock,
      returnEnteredPin: true,
    ),
  );
}

/// Blocks the shell until the active locked profile is unlocked, and lets the
/// user pick a different (possibly unlocked) profile instead.
class ProfileLockOverlay extends StatelessWidget {
  const ProfileLockOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final locked = context.select<ProfileProvider, bool>(
      (p) => p.needsProfileUnlock,
    );
    if (!locked) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          child: IgnorePointer(child: child),
        ),
        const ColoredBox(color: Color(0xE60B0C0F)),
        const Center(child: _ProfileGateCard()),
      ],
    );
  }
}

class _ProfileGateCard extends StatefulWidget {
  const _ProfileGateCard();

  @override
  State<_ProfileGateCard> createState() => _ProfileGateCardState();
}

class _ProfileGateCardState extends State<_ProfileGateCard> {
  Profile? _pending;
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _select(Profile profile) async {
    final profiles = context.read<ProfileProvider>();
    final shell = context.read<ShellActions>();
    if (!profiles.isProfileLocked(profile.id)) {
      if (profile.id == profiles.activeProfileId) {
        profiles.markProfileUnlocked();
        return;
      }
      await shell.switchProfile(profile, pinVerified: true);
      return;
    }
    if (profile.id == profiles.activeProfileId && _pending?.id == profile.id) {
      await _submit();
      return;
    }
    setState(() {
      _pending = profile;
      _error = null;
      _pin.clear();
    });
  }

  Future<void> _submit() async {
    final profile = _pending;
    if (profile == null) return;
    final profiles = context.read<ProfileProvider>();
    final shell = context.read<ShellActions>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await profiles.verifyLockPin(profile.id, _pin.text);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = context.l10n.parentalPinIncorrect;
      });
      return;
    }
    _pin.clear();
    if (profile.id == profiles.activeProfileId) {
      profiles.markProfileUnlocked();
      return;
    }
    await shell.switchProfile(profile, pinVerified: true);
  }

  @override
  Widget build(BuildContext context) {
    final profiles = context.watch<ProfileProvider>();
    final l10n = context.l10n;
    final pending = _pending ??
        (profiles.hasMultipleProfiles ? null : profiles.activeProfile);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
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
                profiles.hasMultipleProfiles
                    ? l10n.chooseProfile
                    : l10n.profilePinUnlockTitle(
                        profiles.activeProfile?.name ?? '',
                      ),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                profiles.hasMultipleProfiles
                    ? l10n.chooseProfileBlurb
                    : l10n.profilePinUnlockMessage,
                style: const TextStyle(color: AppColors.textMuted),
              ),
              if (profiles.hasMultipleProfiles) ...[
                const SizedBox(height: 16),
                for (final profile in profiles.profiles)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: profile.id == profiles.activeProfileId
                          ? AppColors.accent
                          : AppColors.accent.withValues(alpha: .2),
                      child: Text(
                        profile.name.characters.first.toUpperCase(),
                        style: TextStyle(
                          color: profile.id == profiles.activeProfileId
                              ? Colors.black
                              : AppColors.text,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(profile.name),
                    subtitle: Text(
                      profiles.isProfileLocked(profile.id)
                          ? l10n.tapToUnlock
                          : l10n.tapToSwitch,
                    ),
                    trailing: profiles.isProfileLocked(profile.id)
                        ? const Icon(Icons.lock_rounded, size: 18)
                        : null,
                    selected: pending?.id == profile.id,
                    onTap: _busy ? null : () => _select(profile),
                  ),
              ],
              if (pending != null &&
                  profiles.isProfileLocked(pending.id)) ...[
                const SizedBox(height: 12),
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
                    labelText: l10n.parentalPinLabel,
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),
                AppActionButton(
                  expand: true,
                  onPressed: _busy ? null : _submit,
                  label: l10n.unlock,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfilePinDialog extends StatefulWidget {
  const _ProfilePinDialog({
    required this.title,
    required this.confirmLabel,
    this.message,
    this.verify,
    this.verifyCurrent,
    this.returnPin = false,
    this.returnEnteredPin = false,
  });

  final String title;
  final String? message;
  final String confirmLabel;
  final Future<bool> Function(String pin)? verify;
  final Future<bool> Function(String current)? verifyCurrent;
  final bool returnPin;
  final bool returnEnteredPin;

  @override
  State<_ProfilePinDialog> createState() => _ProfilePinDialogState();
}

class _ProfilePinDialogState extends State<_ProfilePinDialog> {
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
    try {
      if (widget.returnEnteredPin) {
        final pin = _pin.text.trim();
        PinHash.assertShape(pin);
        if (!mounted) return;
        Navigator.pop(context, pin);
        return;
      }
      if (widget.returnPin) {
        final pin = _pin.text.trim();
        if (pin != _confirm.text.trim()) {
          setState(() {
            _error = context.l10n.parentalPinMismatch;
            _busy = false;
          });
          return;
        }
        if (widget.verifyCurrent != null) {
          final ok = await widget.verifyCurrent!(_current.text);
          if (!ok) {
            setState(() {
              _error = context.l10n.parentalPinIncorrect;
              _busy = false;
            });
            return;
          }
        }
        PinHash.assertShape(pin);
        if (!mounted) return;
        Navigator.pop(context, pin);
        return;
      }
      final verify = widget.verify;
      if (verify == null) return;
      final ok = await verify(_pin.text);
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
          if (widget.verifyCurrent != null) ...[
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
