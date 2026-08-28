import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/screens/onboarding/sync_restore_screen.dart';
import 'package:javp/screens/sources_screen.dart';
import 'package:javp/screens/tv/tv_pairing_screen.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/app_button.dart';
import 'package:javp/widgets/app_logo.dart';
import 'package:javp/widgets/tracker_link_prompt.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  Future<void> _finish(BuildContext context) async {
    final library = context.read<LibraryProvider>();
    // Capture before completeOnboarding: that marks setup done and GoRouter
    // redirects /welcome → /home, which disposes this route and any dialog
    // still tied to the pre-redirect stack.
    final rootNav = Navigator.of(context, rootNavigator: true);
    await library.completeOnboarding();
    await WidgetsBinding.instance.endOfFrame;
    if (!rootNav.mounted) return;
    final navContext = rootNav.context;
    if (!navContext.mounted) return;
    // Soft "Set up trackers?" is deferred until Home settles and ≥1 source
    // exists (see JavpApp._maybePromptTrackerLink). Only the restore-style
    // link-on-device prompt still runs here when needed.
    if (library.needsTrackerDeviceLink) {
      await offerTrackerLinkFlow(
        navContext,
        library,
        kind: TrackerLinkPromptKind.linkOnDevice,
        respectDismiss: false,
      );
      return;
    }
    if (navContext.mounted) navContext.go('/home');
  }

  /// A restored profile arrives with its sources already in place, so there is
  /// nothing left to onboard.
  Future<void> _restoreFromSync(BuildContext context) async {
    final restored = await showSyncRestoreScreen(context);
    if (!restored || !context.mounted) return;
    final library = context.read<LibraryProvider>();
    if (library.needsTrackerDeviceLink) {
      await offerTrackerLinkFlow(
        context,
        library,
        kind: TrackerLinkPromptKind.linkOnDevice,
        respectDismiss: false,
      );
      return;
    }
    if (context.mounted) context.go('/home');
  }

  Future<void> _tryDemo(BuildContext context) async {
    final library = context.read<LibraryProvider>();
    try {
      await library.loadDemoCatalog();
      if (!context.mounted) return;
      await _finish(context);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.couldNotLoadDemo('$e'))),
      );
    }
  }

  Future<void> _pairDevice(BuildContext context) async {
    final result = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const TvPairingScreen()),
    );
    if (!context.mounted) return;
    final library = context.read<LibraryProvider>();
    if (result == true || library.sources.isNotEmpty) {
      await _finish(context);
    }
  }

  Future<void> _addSourceManual(BuildContext context) async {
    final saved = await showAddSourceSheet(context);
    if (!context.mounted) return;
    if (saved) {
      await _finish(context);
    }
  }

  Future<void> _addSource(BuildContext context) async {
    if (TvPlatform.isAndroidTv) {
      await _pairDevice(context);
      return;
    }
    await _addSourceManual(context);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isTv = TvPlatform.isAndroidTv;
    final l10n = context.l10n;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(isTv ? 48 : 24, 28, isTv ? 48 : 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  descendantsAreFocusable: false,
                  descendantsAreTraversable: false,
                  child: ListView(
                  children: [
                    Row(
                      children: [
                        const AppLogo(size: 44),
                        const SizedBox(width: 14),
                        Text(
                          'JAVP',
                          style: textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                            color: AppColors.text,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    Text(
                      l10n.bringYourOwnMedia,
                      style: textTheme.headlineSmall?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      isTv ? l10n.welcomeBodyTv : l10n.welcomeBodyPhone,
                      style: textTheme.bodyLarge?.copyWith(
                        color: AppColors.textMuted,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 28),
                    _CapabilityRow(
                      icon: Icons.dns_outlined,
                      title: l10n.capabilityMediaServers,
                      subtitle: l10n.capabilityMediaServersSubtitle,
                    ),
                    _CapabilityRow(
                      icon: Icons.live_tv_outlined,
                      title: l10n.capabilityIptv,
                      subtitle: l10n.capabilityIptvSubtitle,
                    ),
                    _CapabilityRow(
                      icon: Icons.data_object_rounded,
                      title: l10n.capabilityJsonCatalogs,
                      subtitle: l10n.capabilityJsonCatalogsSubtitle,
                    ),
                    _CapabilityRow(
                      icon: Icons.folder_open_rounded,
                      title: l10n.capabilityLocalFiles,
                      subtitle: l10n.capabilityLocalFilesSubtitle,
                    ),
                    _CapabilityRow(
                      icon: Icons.sync_rounded,
                      title: l10n.alreadySetUpElsewhere,
                      subtitle: l10n.restoreSourcesHistoryBlurb,
                    ),
                  ],
                ),
                ),
              ),
              if (isTv)
                _TvWelcomeActions(
                  onPair: () => _pairDevice(context),
                  onAddOnTv: () => _addSourceManual(context),
                  onDemo: () => _tryDemo(context),
                  onRestore: () => _restoreFromSync(context),
                  onSkip: () => _finish(context),
                )
              else
                _PhoneWelcomeActions(
                  onAddSource: () => _addSource(context),
                  onDemo: () => _tryDemo(context),
                  onRestore: () => _restoreFromSync(context),
                  onSkip: () => _finish(context),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(icon, color: AppColors.accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Primary CTA full-width; secondary actions share a row so the capability
/// list above stays visible instead of being crushed by a tall button stack.
class _PhoneWelcomeActions extends StatelessWidget {
  const _PhoneWelcomeActions({
    required this.onAddSource,
    required this.onDemo,
    required this.onRestore,
    required this.onSkip,
  });

  final VoidCallback onAddSource;
  final VoidCallback onDemo;
  final VoidCallback onRestore;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppButton(
          onPressed: onAddSource,
          icon: Icons.add_rounded,
          label: l10n.addASource,
          size: AppButtonSize.lg,
          expand: true,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: AppActionButton(
                expand: true,
                variant: AppActionButtonVariant.outlined,
                icon: Icons.movie_filter_outlined,
                onPressed: onDemo,
                label: l10n.tryDemo,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppActionButton(
                expand: true,
                variant: AppActionButtonVariant.outlined,
                icon: Icons.sync_rounded,
                onPressed: onRestore,
                label: l10n.restoreFromSync,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        AppActionButton(
          expand: true,
          variant: AppActionButtonVariant.text,
          onPressed: onSkip,
          label: l10n.skipForNow,
        ),
      ],
    );
  }
}

class _TvWelcomeActions extends StatelessWidget {
  const _TvWelcomeActions({
    required this.onPair,
    required this.onAddOnTv,
    required this.onDemo,
    required this.onRestore,
    required this.onSkip,
  });

  final VoidCallback onPair;
  final VoidCallback onAddOnTv;
  final VoidCallback onDemo;
  final VoidCallback onRestore;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Column(
        children: [
          FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: TvFocusable(
              autofocus: true,
              onSelect: onPair,
              borderRadius: 28,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.qr_code_2_rounded, color: Colors.white),
                    const SizedBox(width: 10),
                    Text(
                      l10n.devicePairTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: _TvSecondaryAction(
                    label: l10n.devicePairAddOnTv,
                    onSelect: onAddOnTv,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(3),
                  child: _TvSecondaryAction(
                    label: l10n.tryDemo,
                    onSelect: onDemo,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FocusTraversalOrder(
            order: const NumericFocusOrder(4),
            child: _TvSecondaryAction(
              label: l10n.restoreFromSync,
              onSelect: onRestore,
            ),
          ),
          const SizedBox(height: 4),
          FocusTraversalOrder(
            order: const NumericFocusOrder(5),
            child: TvFocusable(
              onSelect: onSkip,
              borderRadius: 12,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    l10n.skipForNow,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TvSecondaryAction extends StatelessWidget {
  const _TvSecondaryAction({
    required this.label,
    required this.onSelect,
  });

  final String label;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onSelect: onSelect,
      borderRadius: 12,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
          color: AppColors.surfaceHigh.withValues(alpha: 0.35),
        ),
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
