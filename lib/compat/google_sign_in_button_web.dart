import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as google_sign_in_web;

/// Official Google Identity Services button (required on Flutter web).
Widget googleSignInButton() => google_sign_in_web.renderButton(
      configuration: google_sign_in_web.GSIButtonConfiguration(
        type: google_sign_in_web.GSIButtonType.standard,
        theme: google_sign_in_web.GSIButtonTheme.outline,
        size: google_sign_in_web.GSIButtonSize.large,
        text: google_sign_in_web.GSIButtonText.signinWith,
        shape: google_sign_in_web.GSIButtonShape.rectangular,
        logoAlignment: google_sign_in_web.GSIButtonLogoAlignment.left,
        minimumWidth: 280,
      ),
    );
