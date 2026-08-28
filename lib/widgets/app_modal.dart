import 'package:flutter/material.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/theme/app_theme.dart';

/// Widest a desktop picker dialog grows before it centres.
const double kAppModalDesktopMaxWidth = 560;

/// Phone: modal bottom sheet. Desktop: centred dialog.
///
/// Android TV / desktop TV layout keep the sheet so D-pad chrome stays put.
/// Barrier dismiss and Escape still pop unless [isDismissible] is false.
Future<T?> showAppModal<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool showDragHandle = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  Color? backgroundColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
  double desktopMaxWidth = kAppModalDesktopMaxWidth,
}) {
  final color = backgroundColor ?? AppColors.surface;
  final useDialog = DesktopUi.enabled && !TvPlatform.isAndroidTv;
  final screen = MediaQuery.sizeOf(context);
  final maxHeight = screen.height * 0.9;

  Widget wrap(BuildContext context) {
    return LayoutBuilder(
      builder: (context, incoming) {
        // Prefer the overlay's real max (dialog inset / sheet layout) so a
        // MediaQuery-based cap cannot size the body taller than the window.
        // That made Add Source grow off-screen with nothing to scroll.
        final height = incoming.maxHeight.isFinite
            ? incoming.maxHeight.clamp(0.0, maxHeight)
            : maxHeight;
        final width = useDialog
            ? desktopMaxWidth
            : (incoming.maxWidth.isFinite
                  ? incoming.maxWidth
                  : double.infinity);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height, maxWidth: width),
          child: builder(context),
        );
      },
    );
  }

  if (useDialog) {
    return showDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      barrierDismissible: isDismissible,
      builder: (context) {
        return Dialog(
          backgroundColor: color,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          constraints: BoxConstraints(
            minWidth: 280,
            maxWidth: desktopMaxWidth,
            maxHeight: maxHeight,
          ),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
          clipBehavior: Clip.antiAlias,
          child: wrap(context),
        );
      },
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    backgroundColor: color,
    constraints:
        constraints ?? BoxConstraints(maxWidth: 640, maxHeight: maxHeight),
    shape:
        shape ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
    builder: wrap,
  );
}

/// Phone-sheet grabber. Hidden on desktop so a dialog does not look like a
/// stretched bottom sheet.
class AppModalDragHandle extends StatelessWidget {
  const AppModalDragHandle({
    super.key,
    this.top = 10,
    this.bottom = 0,
    this.width = 40,
  });

  final double top;
  final double bottom;
  final double width;

  @override
  Widget build(BuildContext context) {
    if (DesktopUi.enabled && !TvPlatform.isAndroidTv) {
      return SizedBox(height: top > 0 ? 8 : 0);
    }
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom),
      child: Center(
        child: Container(
          width: width,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
      ),
    );
  }
}
