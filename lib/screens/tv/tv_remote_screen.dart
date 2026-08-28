import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/screens/tv/tv_remote_ui_l10n.dart';
import 'package:javp/services/pairing/tv_remote_server.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Whether phone → TV / desktop remote typing is useful on this device.
bool get phoneRemoteEntryAvailable =>
    AppCapabilities.phoneRemote && (TvPlatform.isTvShell || DesktopUi.enabled);

/// Opens the QR remote session. Optional [onSearch] receives text from the phone.
Future<void> openPhoneRemote(
  BuildContext context, {
  ValueChanged<String>? onSearch,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(builder: (_) => TvRemoteScreen(onSearch: onSearch)),
  );
}

/// Full-screen QR remote for Android TV / desktop (phone browser on LAN).
class TvRemoteScreen extends StatefulWidget {
  const TvRemoteScreen({super.key, this.onSearch});

  /// When set, search text from the phone updates the calling screen.
  final ValueChanged<String>? onSearch;

  @override
  State<TvRemoteScreen> createState() => _TvRemoteScreenState();
}

class _TvRemoteScreenState extends State<TvRemoteScreen> {
  /// Optional: `--dart-define=JAVP_PAIRING_HOST=192.168.x.x` for emulator→phone.
  static const _hostDefine = String.fromEnvironment('JAVP_PAIRING_HOST');

  TvRemoteServer? _server;
  StreamSubscription<TvRemoteCommand>? _sub;
  String? _status;
  String? _error;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final locale = Localizations.localeOf(context);
    final server = TvRemoteServer(
      uiStrings: tvRemoteUiStringsFor(
        context.l10n,
        localeTag: locale.toLanguageTag(),
      ),
    );
    final host = _hostDefine.trim();
    if (host.isNotEmpty) server.hostOverride = host;
    try {
      await server.start();
      if (!mounted) {
        server.dispose();
        return;
      }
      // Assign before listen so dispose() always stops a started server.
      _server = server;
      _sub = server.onCommand.listen(_onCommand);
      setState(() {
        _starting = false;
        if (server.lanIp == null && server.effectiveHost == null) {
          _error =
              'Could not find a LAN IP. Connect Ethernet/Wi‑Fi and try again.';
        }
      });
    } catch (e) {
      server.dispose();
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = 'Could not start phone remote: $e';
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final server = _server;
    if (server == null) return;
    final locale = Localizations.localeOf(context);
    server.uiStrings = tvRemoteUiStringsFor(
      context.l10n,
      localeTag: locale.toLanguageTag(),
    );
  }

  Future<void> _onCommand(TvRemoteCommand command) async {
    if (!mounted) return;
    switch (command.kind) {
      case TvRemoteCommandKind.search:
        widget.onSearch?.call(command.value);
        setState(() {
          _status = context.l10n.phoneRemoteSearchReceived(command.value);
        });
      case TvRemoteCommandKind.channel:
        final n = int.tryParse(command.value);
        final playback = context.read<PlaybackProvider>();
        if (n == null) return;
        final ok = await playback.zapLiveByIndex(n);
        if (!mounted) return;
        setState(() {
          _status = ok
              ? context.l10n.phoneRemoteChannelTuned(n)
              : context.l10n.phoneRemoteChannelUnavailable(n);
        });
      case TvRemoteCommandKind.pasteUrl:
        final library = context.read<LibraryProvider>();
        try {
          await library.addNetworkUrl(title: '', url: command.value);
          if (!mounted) return;
          setState(() {
            _status = context.l10n.phoneRemoteUrlAdded;
          });
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _status = context.l10n.phoneRemoteUrlFailed('$e');
          });
        }
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _server?.dispose();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _status = 'Copied');
  }

  @override
  Widget build(BuildContext context) {
    final server = _server;
    final uri = server?.remoteUri;
    final emulator =
        TvPlatform.isEmulator || (server?.isEmulatorNetwork ?? false);
    final showQr = uri != null && !emulator;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(context.l10n.phoneRemoteTitle)),
      body: Center(
        child: _starting
            ? const CircularProgressIndicator()
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
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
                              data: uri.toString(),
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
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              emulator
                                  ? 'Emulator remote'
                                  : context.l10n.scanWithYourPhone,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              emulator
                                  ? 'The TV AVD is not on your Wi‑Fi. Run the '
                                        'adb forward command below, then open the '
                                        'URL in a browser on this PC.'
                                  : context.l10n.phoneRemoteHelp,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
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
                                  child: Text(context.l10n.copyAdbCommand),
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            Semantics(
                              label: uri?.toString() ?? '',
                              child: SelectableText(
                                uri?.toString() ?? '',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TvFocusable(
                              autofocus:
                                  !(emulator &&
                                      server?.adbForwardCommand != null),
                              onSelect: () {
                                if (uri != null) {
                                  unawaited(_copy(uri.toString()));
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                child: Text(context.l10n.copyUrl),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TvFocusable(
                              onSelect: () {
                                server?.rotateToken();
                                setState(() => _status = 'New code ready');
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Text(context.l10n.newCode),
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
                  ],
                ),
              ),
      ),
    );
  }
}
