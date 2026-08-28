import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/discord/discord_presence_service.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';

/// Discord Rich Presence toggles. Own [State] so enable/disable does not
/// rebuild the parent settings [ListView] on settle.
class DiscordPresenceSettings extends StatefulWidget {
  const DiscordPresenceSettings({super.key});

  @override
  State<DiscordPresenceSettings> createState() =>
      _DiscordPresenceSettingsState();
}

class _DiscordPresenceSettingsState extends State<DiscordPresenceSettings> {
  late bool _enabled = DiscordPresenceService.instance.enabled;
  late bool _hideTitle = DiscordPresenceService.instance.hideTitle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsSwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.sensors_rounded, color: AppColors.accent),
          title: Text(l10n.discordRichPresenceToggle),
          subtitle: Text(l10n.discordRichPresenceToggleSubtitle),
          value: _enabled,
          onWillChange: (v) => setState(() => _enabled = v),
          onChanged: (v) async {
            await DiscordPresenceService.instance.setEnabled(v);
            if (!mounted) return;
            final actual = DiscordPresenceService.instance.enabled;
            if (actual != _enabled) setState(() => _enabled = actual);
          },
        ),
        if (_enabled)
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(
              Icons.visibility_off_outlined,
              color: AppColors.accent,
            ),
            title: Text(l10n.discordRichPresenceHideTitle),
            subtitle: Text(l10n.discordRichPresenceHideTitleSubtitle),
            value: _hideTitle,
            onWillChange: (v) => setState(() => _hideTitle = v),
            onChanged: (v) async {
              await DiscordPresenceService.instance.setHideTitle(v);
              if (!mounted) return;
              final actual = DiscordPresenceService.instance.hideTitle;
              if (actual != _hideTitle) setState(() => _hideTitle = actual);
            },
          ),
      ],
    );
  }
}
