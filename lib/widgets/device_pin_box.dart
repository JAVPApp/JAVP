import 'package:flutter/material.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Device / PIN code shown while waiting for SIMKL, Trakt, or BetaSeries.
///
/// On TV and desktop, a QR encodes [scanUri] so a phone can open the
/// sign-in page without typing the URL. The code stays on screen to enter
/// after the page opens (unless the provider already baked it into the URL).
class DevicePinBox extends StatelessWidget {
  const DevicePinBox({
    super.key,
    required this.code,
    required this.onCopy,
    required this.onOpen,
    this.scanUri,
    this.debugShowQr,
  });

  final String code;
  final VoidCallback onCopy;
  final VoidCallback onOpen;
  final Uri? scanUri;

  /// Test override for QR visibility. Production uses TV / desktop detection.
  final bool? debugShowQr;

  bool get _showQr {
    final uri = scanUri;
    if (uri == null || !uri.hasScheme) return false;
    if (debugShowQr != null) return debugShowQr!;
    return TvPlatform.isTvShell || DesktopUi.enabled;
  }

  bool get _tv => TvPlatform.isTvShell;

  @override
  Widget build(BuildContext context) {
    final showQr = _showQr;
    final qrSize = _tv ? 220.0 : 168.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final sideBySide = showQr && constraints.maxWidth >= 420;
            final qr = showQr ? _QrPad(data: scanUri!.toString(), size: qrSize) : null;
            final details = _PinDetails(
              code: code,
              showQr: showQr,
              showActions: !_tv,
              onCopy: onCopy,
              onOpen: onOpen,
            );
            if (!showQr) return details;
            if (sideBySide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  qr!,
                  const SizedBox(width: 20),
                  Expanded(child: details),
                ],
              );
            }
            return Column(
              children: [
                qr!,
                const SizedBox(height: 16),
                details,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QrPad extends StatelessWidget {
  const _QrPad({required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.scanWithYourPhone,
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: QrImageView(
          data: data,
          version: QrVersions.auto,
          backgroundColor: Colors.white,
        ),
      ),
    );
  }
}

class _PinDetails extends StatelessWidget {
  const _PinDetails({
    required this.code,
    required this.showQr,
    required this.showActions,
    required this.onCopy,
    required this.onOpen,
  });

  final String code;
  final bool showQr;
  final bool showActions;
  final VoidCallback onCopy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment:
          showQr ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        if (showQr) ...[
          Text(
            l10n.scanWithYourPhone,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.devicePinScanHelp,
            style: const TextStyle(color: AppColors.textMuted, height: 1.35),
          ),
          const SizedBox(height: 12),
        ],
        SelectableText(
          code,
          textAlign: showQr ? TextAlign.start : TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                letterSpacing: 6,
                fontWeight: FontWeight.w700,
              ),
        ),
        if (showActions) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: showQr ? WrapAlignment.start : WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(l10n.copy),
              ),
              OutlinedButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                label: Text(l10n.openBrowser),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
