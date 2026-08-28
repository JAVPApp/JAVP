import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/widgets/app_scaffold_messenger.dart';

/// App-wide desktop hotkeys: search, settings, and going back.
///
/// The [router] is passed in rather than looked up: this sits above the Router
/// in `MaterialApp.builder`, where `GoRouter.of(context)` has nothing to find.
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({
    super.key,
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DesktopUi.enabled) return child;
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            OpenSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            OpenSearchIntent(),
        SingleActivator(LogicalKeyboardKey.comma, control: true):
            OpenSettingsIntent(),
        // This Shortcuts widget wraps the Navigator, so it sees Escape before
        // WidgetsApp's DismissIntent mapping. Forward dismissible dialogs and
        // sheets first; the player still handles Escape via its own Focus.
        SingleActivator(LogicalKeyboardKey.escape): GoBackIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            GoBackIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          OpenSearchIntent: CallbackAction<OpenSearchIntent>(
            onInvoke: (_) {
              router.push('/search');
              return null;
            },
          ),
          OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
            onInvoke: (_) {
              router.go('/settings');
              return null;
            },
          ),
          GoBackIntent: CallbackAction<GoBackIntent>(
            onInvoke: (_) {
              final focused = FocusManager.instance.primaryFocus?.context;
              if (focused != null && focused.mounted) {
                const dismiss = DismissIntent();
                final action = Actions.maybeFind<DismissIntent>(
                  focused,
                  intent: dismiss,
                );
                if (action != null && action.isEnabled(dismiss)) {
                  return Actions.invoke(focused, dismiss);
                }
              }
              final snackMessenger = context
                  .findAncestorStateOfType<AppScaffoldMessengerState>();
              if (snackMessenger != null && snackMessenger.isShowingSnackBar) {
                snackMessenger.hideCurrentSnackBar();
                return null;
              }
              if (router.canPop()) {
                router.pop();
                return null;
              }
              final path = router.routerDelegate.currentConfiguration.uri.path;
              if (path == '/player' || path == '/cast') {
                router.go('/home');
              }
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class OpenSearchIntent extends Intent {
  const OpenSearchIntent();
}

class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

class GoBackIntent extends Intent {
  const GoBackIntent();
}
