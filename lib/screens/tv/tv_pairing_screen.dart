import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/screens/onboarding/sync_restore_screen.dart';
import 'package:javp/services/pairing/source_pairing_server.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Full-screen LAN pairing host for Android TV / desktop.
///
/// Shows a `javp://pair` QR so a phone with JAVP can push or pull sources;
/// browser form URL remains available as a fallback.
class TvPairingScreen extends StatefulWidget {
  const TvPairingScreen({super.key});

  @override
  State<TvPairingScreen> createState() => _TvPairingScreenState();
}

class _TvPairingScreenState extends State<TvPairingScreen> {
  /// Optional: `--dart-define=JAVP_PAIRING_HOST=192.168.x.x` for emulator→phone.
  static const _hostDefine = String.fromEnvironment('JAVP_PAIRING_HOST');

  SourcePairingServer? _server;
  StreamSubscription<SourcePairingAdded>? _addedSub;
  StreamSubscription<SourcePairingImported>? _importedSub;
  String? _status;
  String? _error;
  bool _starting = true;
  bool _sourcesReady = false;
  bool _offerSyncSetup = false;
  Timer? _autoContinueTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final library = context.read<LibraryProvider>();
    final profiles = context.read<ProfileProvider>();
    final server = SourcePairingServer(library: library, profiles: profiles);
    final host = _hostDefine.trim();
    if (host.isNotEmpty) server.hostOverride = host;
    try {
      await server.start();
      _addedSub = server.onSourceAdded.listen((added) {
        if (!mounted) return;
        _onSourcesLanded(context.l10n.devicePairHostAdded(added.name));
      });
      _importedSub = server.onSourcesImported.listen((imported) {
        if (!mounted) return;
        final profilesNow = context.read<ProfileProvider>();
        final apply = imported.syncApply;
        final offerSync =
            imported.profileName == null &&
            (apply?.needsLocalFolderSetup == true ||
                !profilesNow.syncSettings.isConfigured);
        _onSourcesLanded(
          imported.profileName != null
              ? context.l10n.devicePairHostAddedProfile(imported.profileName!)
              : context.l10n.devicePairHostImported(imported.count),
          offerSyncSetup: offerSync,
        );
      });
      if (!mounted) {
        server.dispose();
        return;
      }
      setState(() {
        _server = server;
        _starting = false;
        if (server.lanIp == null && server.effectiveHost == null) {
          _error = context.l10n.devicePairNoLanIp;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = context.l10n.devicePairHostStartFailed('$e');
      });
    }
  }

  void _onSourcesLanded(String status, {bool offerSyncSetup = false}) {
    setState(() {
      _status = status;
      _sourcesReady = true;
      _offerSyncSetup = offerSyncSetup;
    });
    // During Welcome, leave pairing automatically so onboarding can finish —
    // sitting on "Imported…" with Continue below the fold felt stuck.
    // Keep the pane if profile sync still needs a local folder / setup.
    final library = context.read<LibraryProvider>();
    if (library.onboardingCompleted || offerSyncSetup) return;
    _autoContinueTimer?.cancel();
    _autoContinueTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || !_sourcesReady) return;
      _continue();
    });
  }

  Future<void> _openSyncSetup() async {
    await showSyncRestoreScreen(context);
    if (!mounted) return;
    setState(() {
      _offerSyncSetup = !context
          .read<ProfileProvider>()
          .syncSettings
          .isConfigured;
    });
  }

  @override
  void dispose() {
    _autoContinueTimer?.cancel();
    unawaited(_addedSub?.cancel() ?? Future<void>.value());
    unawaited(_importedSub?.cancel() ?? Future<void>.value());
    _server?.dispose();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _status = 'Copied');
  }

  void _continue() {
    _autoContinueTimer?.cancel();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final server = _server;
    final qrUri = server?.qrPayloadUri;
    final browserUri = server?.pairingUri;
    final homeUri = server?.pairingHomeUri;
    final pin = server?.pin;
    final emulator =
        TvPlatform.isEmulator || (server?.isEmulatorNetwork ?? false);
    final showQr = qrUri != null && !emulator;
    final defaultAutofocus =
        !_sourcesReady && !(emulator && server?.adbForwardCommand != null);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(l10n.devicePairTitle)),
      body: Center(
        child: _starting
            ? const CircularProgressIndicator()
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              )
            : _sourcesReady
            ? _ReadyPane(
                status: _status ?? l10n.devicePairHostReady,
                syncLater: l10n.devicePairHostSyncLater,
                continueLabel: l10n.continueAction,
                onContinue: _continue,
                setupSyncLabel: _offerSyncSetup
                    ? l10n.devicePairSetupProfileSync
                    : null,
                onSetupSync: _offerSyncSetup ? _openSyncSetup : null,
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Row(
                  children: [
                    if (showQr)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: QrImageView(
                              data: qrUri.toString(),
                              version: QrVersions.auto,
                              backgroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      flex: showQr ? 1 : 2,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: _ScrollFit(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                emulator
                                    ? l10n.devicePairEmulatorTitle
                                    : l10n.scanWithYourPhone,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                emulator
                                    ? l10n.devicePairEmulatorHelp
                                    : l10n.devicePairHostHelp,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              if (pin != null) ...[
                                const SizedBox(height: 20),
                                Text(
                                  l10n.devicePairPinLabel,
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                SelectableText(
                                  pin,
                                  style: const TextStyle(
                                    fontSize: 36,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 4,
                                    color: AppColors.accent,
                                  ),
                                ),
                                if (server?.effectiveHost != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      '${server!.effectiveHost}:${server.boundPort}',
                                      style: const TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                              ],
                              if (emulator &&
                                  server?.adbForwardCommand != null) ...[
                                const SizedBox(height: 16),
                                SelectableText(
                                  server!.adbForwardCommand!,
                                  style: const TextStyle(
                                    fontFamily: 'Consolas',
                                    fontSize: 13,
                                    color: AppColors.accent,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TvFocusable(
                                  autofocus: true,
                                  onSelect: () =>
                                      _copy(server.adbForwardCommand!),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    child: Text(l10n.copyAdbCommand),
                                  ),
                                ),
                              ],
                              if (homeUri != null || browserUri != null) ...[
                                const SizedBox(height: 20),
                                Text(
                                  l10n.devicePairBrowserFallback,
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                                if (homeUri != null) ...[
                                  const SizedBox(height: 6),
                                  Semantics(
                                    label: homeUri.toString(),
                                    child: SelectableText(
                                      homeUri.toString(),
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.text,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.devicePairBrowserEnterPin,
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                                if (browserUri != null) ...[
                                  const SizedBox(height: 8),
                                  Semantics(
                                    label: browserUri.toString(),
                                    child: SelectableText(
                                      browserUri.toString(),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                              const SizedBox(height: 12),
                              TvFocusable(
                                autofocus: defaultAutofocus,
                                onSelect: () {
                                  final copy = homeUri ?? qrUri ?? browserUri;
                                  if (copy != null) {
                                    unawaited(_copy(copy.toString()));
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  child: Text(l10n.copyUrl),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TvFocusable(
                                onSelect: () {
                                  server?.rotateToken();
                                  setState(
                                    () => _status = l10n.devicePairNewCode,
                                  );
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  child: Text(l10n.newCode),
                                ),
                              ),
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
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Lets a centered column grow past a short Fire TV body without a RenderFlex overflow.
class _ScrollFit extends StatelessWidget {
  const _ScrollFit({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: child,
          ),
        );
      },
    );
  }
}

/// Full-bleed success handoff so Continue is never clipped under the QR UI.
class _ReadyPane extends StatelessWidget {
  const _ReadyPane({
    required this.status,
    required this.syncLater,
    required this.continueLabel,
    required this.onContinue,
    this.setupSyncLabel,
    this.onSetupSync,
  });

  final String status;
  final String syncLater;
  final String continueLabel;
  final VoidCallback onContinue;
  final String? setupSyncLabel;
  final VoidCallback? onSetupSync;

  @override
  Widget build(BuildContext context) {
    final offerSync = setupSyncLabel != null && onSetupSync != null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: _ScrollFit(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.check_circle_outline_rounded,
                color: AppColors.live,
                size: 64,
              ),
              const SizedBox(height: 20),
              Text(
                status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                syncLater,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 28),
              if (offerSync) ...[
                TvFocusable(
                  autofocus: true,
                  onSelect: onSetupSync!,
                  borderRadius: 28,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Center(
                      child: Text(
                        setupSyncLabel!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TvFocusable(
                  onSelect: onContinue,
                  borderRadius: 28,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Center(
                      child: Text(
                        continueLabel,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                TvFocusable(
                  autofocus: true,
                  onSelect: onContinue,
                  borderRadius: 28,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Center(
                      child: Text(
                        continueLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
