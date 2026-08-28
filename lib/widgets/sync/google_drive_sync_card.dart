import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:javp/compat/google_sign_in_button.dart';
import 'package:javp/models/sync_settings.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/services/sync/google_drive_auth.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// Shared Google Drive sign-in control for Settings and welcome restore.
///
/// Mobile uses Google Sign-In. Web uses the GIS button (required by Google).
/// Desktop opens the system browser and finishes on a loopback redirect with
/// PKCE (token exchange via javp.app). Tokens land on [ProfileProvider] after a
/// successful connection test either way.
class GoogleDriveSyncCard extends StatefulWidget {
  const GoogleDriveSyncCard({
    super.key,
    required this.settings,
    required this.busy,
    required this.onBusy,
    this.onToast,
    this.onConnected,
    this.persistSettings,
    this.showDisconnect = true,
  });

  final SyncSettings settings;
  final bool busy;
  final ValueChanged<bool> onBusy;

  /// Optional toast / snackbar (Settings). Errors also surface inline.
  final ValueChanged<String>? onToast;

  /// Fired after tokens are saved (restore uses this to list profiles).
  final ValueChanged<SyncSettings>? onConnected;

  /// When set, used instead of writing to the active profile. Import-from-
  /// another-target keeps Drive tokens on the draft until a profile is adopted.
  final Future<void> Function(SyncSettings next)? persistSettings;

  /// Settings shows Disconnect; restore usually does not.
  final bool showDisconnect;

  @override
  State<GoogleDriveSyncCard> createState() => _GoogleDriveSyncCardState();
}

class _GoogleDriveSyncCardState extends State<GoogleDriveSyncCard> {
  final _auth = GoogleDriveAuth();
  String? _status;
  bool _cancelled = false;
  bool _webReady = false;
  bool _needsDriveScopeClick = false;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _webAuthSub;

  @override
  void initState() {
    super.initState();
    if (_auth.usesGisSignInButton) {
      unawaited(_prepareWebSignIn());
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    unawaited(_webAuthSub?.cancel() ?? Future<void>.value());
    _auth.close();
    super.dispose();
  }

  bool get _usesLoopback =>
      !_auth.supportsGoogleSignIn && _auth.supportsLoopbackPkce;

  bool get _signedIn =>
      widget.settings.googleAccessToken.isNotEmpty ||
      widget.settings.googleRefreshToken.isNotEmpty;

  Future<void> _prepareWebSignIn() async {
    try {
      await _auth.ensureSignInInitialized(
        serverClientId: GoogleDriveAuth.bundledClientId,
      );
      if (!mounted || _cancelled) return;
      _webAuthSub = GoogleSignIn.instance.authenticationEvents.listen(
        (event) {
          if (event is GoogleSignInAuthenticationEventSignIn) {
            unawaited(_onWebSignedIn(event.user));
          }
        },
        onError: (Object e) {
          if (!mounted || _cancelled) return;
          setState(() {
            _status = '$e'
                .replaceFirst('StateError: ', '')
                .replaceFirst('GoogleSignInException: ', '');
          });
          widget.onBusy(false);
        },
      );
      setState(() => _webReady = true);
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() => _status = '$e'.replaceFirst('StateError: ', ''));
    }
  }

  Future<void> _onWebSignedIn(GoogleSignInAccount _) async {
    if (!mounted || _cancelled || _signedIn) return;
    final l10n = context.l10n;
    widget.onBusy(true);
    setState(() {
      _status = l10n.openingGoogleSignIn;
      _needsDriveScopeClick = false;
    });
    try {
      // Prefer a silent grant if Drive was already authorized for this account.
      // Do NOT call authorizeScopes here — browsers block that popup outside a
      // direct click (GIS identity callback is async).
      final silent = await _auth.authorizationForDriveScopesIfGranted(
        serverClientId: GoogleDriveAuth.bundledClientId,
      );
      if (!mounted || _cancelled) return;
      if (silent != null) {
        await _finish(silent);
        return;
      }
      setState(() {
        _needsDriveScopeClick = true;
        _status = l10n.googleDriveNeedsGestureBlurb;
      });
      widget.onBusy(false);
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _needsDriveScopeClick = true;
        _status = l10n.googleDriveNeedsGestureBlurb;
      });
      widget.onBusy(false);
      debugPrint('Drive scope after GIS identity: $e');
    }
  }

  Future<void> _authorizeDriveScopes() async {
    final l10n = context.l10n;
    widget.onBusy(true);
    setState(() => _status = l10n.openingGoogleSignIn);
    try {
      final tokens = await _auth.authorizeDriveScopes(
        serverClientId: GoogleDriveAuth.bundledClientId,
      );
      if (!mounted || _cancelled) return;
      setState(() => _needsDriveScopeClick = false);
      await _finish(tokens);
    } catch (e) {
      if (!mounted || _cancelled) return;
      final raw = '$e'.replaceFirst('StateError: ', '');
      final message = raw == 'popup_blocked'
          ? l10n.googleDrivePopupBlocked
          : raw.replaceFirst('GoogleSignInException: ', '');
      setState(() {
        _needsDriveScopeClick = true;
        _status = message;
      });
      widget.onBusy(false);
    }
  }

  Future<void> _connect() async {
    final l10n = context.l10n;
    if (_auth.usesGisSignInButton) {
      // Web: official GIS button drives sign-in; optional scope button below.
      if (_needsDriveScopeClick) {
        await _authorizeDriveScopes();
      }
      return;
    }
    if (_auth.supportsGoogleSignIn) {
      await _connectWithGoogleSignIn();
      return;
    }
    if (_usesLoopback) {
      await _connectWithLoopback();
      return;
    }
    final message = l10n.googleDriveApiUnavailable;
    setState(() => _status = message);
    widget.onToast?.call(message);
  }

  Future<void> _connectWithGoogleSignIn() async {
    final l10n = context.l10n;
    widget.onBusy(true);
    setState(() => _status = l10n.openingGoogleSignIn);
    try {
      final tokens = await _auth.signInWithGoogle(
        serverClientId: GoogleDriveAuth.bundledClientId,
      );
      if (!mounted) return;
      await _finish(tokens);
    } catch (e) {
      if (!mounted) return;
      final message = '$e'
          .replaceFirst('StateError: ', '')
          .replaceFirst('GoogleSignInException: ', '');
      setState(() => _status = message);
      widget.onBusy(false);
    }
  }

  Future<void> _connectWithLoopback() async {
    final l10n = context.l10n;
    if (_auth.effectiveDesktopClientId(null).isEmpty) {
      setState(() => _status = l10n.googleClientIdMissing);
      return;
    }

    widget.onBusy(true);
    _cancelled = false;
    setState(() => _status = l10n.openingGoogleSignIn);
    try {
      final tokens = await _auth.signInWithLoopbackPkce(
        isCancelled: () => _cancelled || !mounted,
      );
      if (!mounted || _cancelled) return;
      await _finish(tokens);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$e'.replaceFirst('StateError: ', ''));
      widget.onBusy(false);
    }
  }

  Future<void> _finish(GoogleOAuthTokens tokens) async {
    final profiles = context.read<ProfileProvider>();
    final l10n = context.l10n;
    final next = widget.settings.copyWith(
      backend: SyncBackend.googleDrive,
      googleClientId: _usesLoopback
          ? _auth.effectiveDesktopClientId(null)
          : GoogleDriveAuth.bundledClientId,
      googleClientSecret: '',
      googleAccessToken: tokens.accessToken,
      googleRefreshToken: tokens.refreshToken,
      googleTokenExpiresAt: tokens.expiresAt,
    );
    final error = await profiles.testConnection(next);
    if (!mounted) return;
    if (error != null) {
      setState(() => _status = error);
      widget.onBusy(false);
      widget.onToast?.call(error);
      return;
    }
    if (widget.persistSettings != null) {
      await widget.persistSettings!(next);
    } else {
      await profiles.updateSyncSettings(next);
    }
    if (!mounted) return;
    setState(() {
      _status = null;
      _needsDriveScopeClick = false;
    });
    widget.onBusy(false);
    widget.onToast?.call(l10n.googleDriveConnected);
    widget.onConnected?.call(next);
  }

  Future<void> _disconnect() async {
    final profiles = context.read<ProfileProvider>();
    _cancelled = true;
    try {
      await _auth.signOutGoogle();
    } catch (_) {}
    final next = widget.settings.copyWith(
      googleClientId: GoogleDriveAuth.bundledClientId,
      googleClientSecret: '',
      clearGoogleTokens: true,
    );
    if (widget.persistSettings != null) {
      await widget.persistSettings!(next);
    } else {
      await profiles.updateSyncSettings(next);
    }
    if (!mounted) return;
    setState(() {
      _status = null;
      _needsDriveScopeClick = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final supports = _auth.supportsGoogleSignIn || _usesLoopback;
    final useGis = _auth.usesGisSignInButton && !_signedIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _signedIn
              ? l10n.googleDriveSignedInBlurb
              : _usesLoopback
                  ? l10n.googleDriveDesktopBlurb
                  : l10n.googleDriveSignInBlurb,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(_status!, style: const TextStyle(color: AppColors.accent)),
        ],
        if (!supports) ...[
          const SizedBox(height: 8),
          Text(
            l10n.googleSignInNeedsMobile,
            style: const TextStyle(color: AppColors.accent),
          ),
        ],
        const SizedBox(height: 12),
        if (_signedIn && widget.showDisconnect)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: widget.busy ? null : _disconnect,
              child: Text(l10n.disconnectGoogle),
            ),
          )
        else if (useGis) ...[
          if (!_webReady)
            const Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: googleSignInButton(),
            ),
            if (_needsDriveScopeClick) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: widget.busy ? null : _authorizeDriveScopes,
                  icon: widget.busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_outlined),
                  label: Text(
                    widget.busy ? l10n.signingIn : l10n.googleDriveAllowAccess,
                  ),
                ),
              ),
            ],
          ],
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: widget.busy || !supports ? null : _connect,
              icon: widget.busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_outlined),
              label: Text(
                widget.busy
                    ? l10n.signingIn
                    : _signedIn
                        ? l10n.signInAgain
                        : l10n.signInWithGoogle,
              ),
            ),
          ),
      ],
    );
  }
}
