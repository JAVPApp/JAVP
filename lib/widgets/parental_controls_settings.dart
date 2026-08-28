import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/parental_lock_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/parental_unlock.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:provider/provider.dart';

/// Settings → Parental controls: PIN, lock-on-resume, hidden Live groups / sources.
class ParentalControlsSettingsSection extends StatelessWidget {
  const ParentalControlsSettingsSection({super.key, this.showTitle = true});

  /// When false, skip the section headline (the settings subpage already has it).
  final bool showTitle;

  Future<void> _setOrChangePin(BuildContext context) async {
    final parental = context.read<ParentalLockProvider>();
    final l10n = context.l10n;
    final pin = await showParentalPinEditorDialog(
      context,
      title: parental.hasPin ? l10n.parentalChangePin : l10n.parentalSetPin,
      message: l10n.parentalPinHelp,
      requireCurrent: parental.hasPin,
    );
    if (pin == null || !context.mounted) return;
    await parental.setPin(pin);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.parentalPinSaved)));
  }

  Future<void> _removePin(BuildContext context) async {
    final parental = context.read<ParentalLockProvider>();
    final l10n = context.l10n;
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => _CurrentPinDialog(
        title: l10n.parentalRemovePin,
        message: l10n.parentalRemovePinHelp,
      ),
    );
    if (pin == null || !context.mounted) return;
    final cleared = await parental.clearPin(pin);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleared ? l10n.parentalPinRemoved : l10n.parentalPinIncorrect,
        ),
      ),
    );
  }

  Future<bool> _ensureUnlocked(BuildContext context) async {
    final parental = context.read<ParentalLockProvider>();
    final l10n = context.l10n;
    if (!parental.hasPin) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.parentalSetPinFirst)));
      return false;
    }
    if (!parental.isContentLocked) return true;
    return showParentalUnlockDialog(context);
  }

  Future<void> _pickHiddenGroups(BuildContext context) async {
    final library = context.read<LibraryProvider>();
    if (!await _ensureUnlocked(context) || !context.mounted) return;
    // Prefer Live DB group names (playlist display names); fall back to
    // category rows so Xtream-only installs still work.
    final names = await library.liveGroupNames();
    if (!context.mounted) return;
    final byName = <String, IptvCategory>{
      for (final c in library.categories)
        if (c.kind == IptvCategoryKind.live) c.name: c,
    };
    var cats = <IptvCategory>[
      for (final name in names)
        byName[name] ??
            IptvCategory(id: name, name: name, kind: IptvCategoryKind.live),
    ];
    if (cats.isEmpty) {
      cats = [
        for (final c in library.categories)
          if (c.kind == IptvCategoryKind.live) c,
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    if (!context.mounted) return;
    await showAppModal<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.7,
            child: _HiddenGroupsSheet(categories: cats),
          ),
        );
      },
    );
  }

  Future<void> _pickHiddenSources(BuildContext context) async {
    final library = context.read<LibraryProvider>();
    if (!await _ensureUnlocked(context) || !context.mounted) return;
    final sources = List<IptvSource>.from(library.sources)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!context.mounted) return;
    await showAppModal<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.7,
            child: _HiddenSourcesSheet(sources: sources),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final parental = context.watch<ParentalLockProvider>();
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle) ...[
          Text(
            l10n.parentalControls,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
        ],
        Text(
          l10n.parentalControlsBlurb,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.pin_rounded, color: AppColors.accent),
          title: Text(
            parental.hasPin ? l10n.parentalChangePin : l10n.parentalSetPin,
          ),
          subtitle: Text(
            parental.hasPin ? l10n.parentalPinConfigured : l10n.parentalPinHelp,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _setOrChangePin(context),
        ),
        if (parental.hasPin)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.lock_open_rounded,
              color: AppColors.accent,
            ),
            title: Text(l10n.parentalRemovePin),
            onTap: () => _removePin(context),
          ),
        SettingsSwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(
            Icons.phonelink_lock_rounded,
            color: AppColors.accent,
          ),
          title: Text(l10n.parentalLockOnResume),
          subtitle: Text(l10n.parentalLockOnResumeSubtitle),
          value: parental.lockOnResume,
          onChanged: parental.hasPin
              ? (v) => parental.setLockOnResume(v)
              : null,
        ),
        SettingsSwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.shield_rounded, color: AppColors.accent),
          title: Text(l10n.parentalHideSourceAdult),
          subtitle: Text(l10n.parentalHideSourceAdultSubtitle),
          value: parental.hideSourceAdult,
          onChanged: parental.hasPin
              ? (v) => parental.setHideSourceAdult(v)
              : null,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.dns_rounded, color: AppColors.accent),
          title: Text(l10n.parentalHiddenSources),
          subtitle: Text(
            parental.hiddenSourceIds.isEmpty
                ? l10n.parentalHiddenSourcesEmpty
                : l10n.parentalHiddenSourcesCount(
                    parental.hiddenSourceIds.length,
                  ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickHiddenSources(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.visibility_off_rounded,
            color: AppColors.accent,
          ),
          title: Text(l10n.parentalHiddenGroups),
          subtitle: Text(
            parental.hiddenLiveCategoryIds.isEmpty
                ? l10n.parentalHiddenGroupsEmpty
                : l10n.parentalHiddenGroupsCount(
                    parental.hiddenLiveCategoryIds.length,
                  ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _pickHiddenGroups(context),
        ),
        if (parental.hasPin && parental.sessionUnlocked)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: parental.lockSession,
              icon: const Icon(Icons.lock_rounded),
              label: Text(l10n.parentalLockNow),
            ),
          ),
      ],
    );
  }
}

class _HiddenGroupsSheet extends StatelessWidget {
  const _HiddenGroupsSheet({required this.categories});

  final List<IptvCategory> categories;

  @override
  Widget build(BuildContext context) {
    final parental = context.watch<ParentalLockProvider>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            context.l10n.parentalHiddenGroupsHelp,
            style: const TextStyle(color: AppColors.textMuted),
          ),
        ),
        Expanded(
          child: categories.isEmpty
              ? Center(child: Text(context.l10n.parentalNoLiveGroups))
              : ListView.builder(
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final cat = categories[index];
                    final hidden = parental.hiddenLiveCategoryIds.contains(
                      cat.id,
                    );
                    return CheckboxListTile(
                      value: hidden,
                      onChanged: (_) => parental.toggleHiddenLiveCategory(cat),
                      title: Text(cat.displayName),
                      subtitle: Text(
                        cat.sourceId ?? cat.id,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _HiddenSourcesSheet extends StatelessWidget {
  const _HiddenSourcesSheet({required this.sources});

  final List<IptvSource> sources;

  @override
  Widget build(BuildContext context) {
    final parental = context.watch<ParentalLockProvider>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            context.l10n.parentalHiddenSourcesHelp,
            style: const TextStyle(color: AppColors.textMuted),
          ),
        ),
        Expanded(
          child: sources.isEmpty
              ? Center(child: Text(context.l10n.parentalNoSources))
              : ListView.builder(
                  itemCount: sources.length,
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    final hidden = parental.hiddenSourceIds.contains(source.id);
                    return CheckboxListTile(
                      value: hidden,
                      onChanged: (_) =>
                          parental.toggleHiddenSourceId(source.id),
                      title: Text(source.name),
                      subtitle: Text(
                        source.type.name,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CurrentPinDialog extends StatefulWidget {
  const _CurrentPinDialog({required this.title, required this.message});

  final String title;
  final String message;

  @override
  State<_CurrentPinDialog> createState() => _CurrentPinDialogState();
}

class _CurrentPinDialogState extends State<_CurrentPinDialog> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.message,
            style: const TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
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
              labelText: context.l10n.parentalPinLabel,
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ],
      ),
      actions: [
        AppActionButton(
          variant: AppActionButtonVariant.text,
          onPressed: () => Navigator.pop(context),
          label: context.l10n.cancel,
        ),
        AppActionButton(
          onPressed: () => Navigator.pop(context, _pin.text),
          label: context.l10n.save,
        ),
      ],
    );
  }
}
