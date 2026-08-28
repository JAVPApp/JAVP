import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/desktop/desktop_pane.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Settings hub: a destination list with titles and short descriptions.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final destinations = [
      (
        icon: Icons.tune_rounded,
        title: l10n.settingsGeneral,
        subtitle: l10n.settingsGeneralSubtitle,
        path: '/settings/general',
      ),
      (
        icon: Icons.palette_outlined,
        title: l10n.settingsAppearance,
        subtitle: l10n.settingsAppearanceSubtitle,
        path: '/settings/appearance',
      ),
      (
        icon: Icons.shield_outlined,
        title: l10n.parentalControls,
        subtitle: l10n.settingsParentalSubtitle,
        path: '/settings/parental',
      ),
      (
        icon: Icons.people_alt_outlined,
        title: l10n.settingsProfiles,
        subtitle: l10n.settingsProfilesSubtitle,
        path: '/settings/profiles',
      ),
      (
        icon: Icons.hub_outlined,
        title: l10n.settingsIntegrations,
        subtitle: l10n.settingsIntegrationsSubtitle,
        path: '/settings/integrations',
      ),
      (
        icon: Icons.play_circle_outline_rounded,
        title: l10n.settingsPlayback,
        subtitle: l10n.settingsPlaybackSubtitle,
        path: '/settings/playback',
      ),
      (
        icon: Icons.lan_outlined,
        title: l10n.settingsNetwork,
        subtitle: l10n.settingsNetworkSubtitle,
        path: '/settings/network',
      ),
      (
        icon: Icons.sports_soccer_rounded,
        title: l10n.sportsSettings,
        subtitle: l10n.sportsSettingsSubtitle,
        path: '/settings/sports',
      ),
      (
        icon: Icons.bug_report_outlined,
        title: l10n.settingsDiagnostics,
        subtitle: l10n.settingsDiagnosticsSubtitle,
        path: '/settings/diagnostics',
      ),
    ];

    // Opaque fill (not transparent over AppBackdrop): nested settings routes
    // use the default Material zoom, and a transparent scaffold would stack the
    // hub under the subpage (overlap flash). AppColors.bg matches the shell base.
    //
    // Shell already parks bottom nav / mini dock under this branch and sets
    // resizeToAvoidBottomInset: false. Resizing here again by the full IME
    // over-pads by that chrome height (blank strip above the keyboard).
    return Scaffold(
      backgroundColor: AppColors.bg,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(l10n.navSettings)),
      body: DesktopPane(
        child: ListView(
          padding: AppLayout.pagePadding(),
          children: [
            for (var i = 0; i < destinations.length; i++) ...[
              if (i > 0) const SizedBox(height: 4),
              SettingsDestinationTile(
                icon: destinations[i].icon,
                title: destinations[i].title,
                subtitle: destinations[i].subtitle,
                autofocus: i == 0,
                onTap: () => context.push(destinations[i].path),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Full-screen settings section with a back affordance to the hub.
class SettingsSubpage extends StatelessWidget {
  const SettingsSubpage({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Same as [SettingsScreen]: shell chrome already owns the bottom inset.
    return Scaffold(
      backgroundColor: AppColors.bg,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(title)),
      body: DesktopPane(child: child),
    );
  }
}

class SettingsDestinationTile extends StatelessWidget {
  const SettingsDestinationTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.autofocus = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: Icon(icon, color: AppColors.accent),
      title: Text(title, style: const TextStyle(color: AppColors.text)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppColors.textMuted, height: 1.35),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: TvPlatform.isAndroidTv ? null : onTap,
    );

    if (!TvPlatform.isAndroidTv) return tile;

    return TvFocusable(
      autofocus: autofocus,
      borderRadius: 12,
      onSelect: onTap,
      child: tile,
    );
  }
}
