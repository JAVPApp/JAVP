import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show ContentType, HttpRequest, HttpServer, InternetAddress, Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:javp/services/update/update_channel.dart';
import 'package:url_launcher/url_launcher.dart';

/// Google OAuth device-code session (TV / limited-input flow).
class GoogleDeviceCodeSession {
  const GoogleDeviceCodeSession({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int expiresIn;
  final int interval;

  Uri get verificationUri => Uri.parse(verificationUrl);

  factory GoogleDeviceCodeSession.fromJson(Map<String, dynamic> json) {
    return GoogleDeviceCodeSession(
      deviceCode: json['device_code'] as String? ?? '',
      userCode: json['user_code'] as String? ?? '',
      verificationUrl: json['verification_url'] as String? ??
          json['verification_uri'] as String? ??
          'https://www.google.com/device',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 1800,
      interval: (json['interval'] as num?)?.toInt() ?? 5,
    );
  }
}

/// Tokens returned by Google OAuth / Google Sign-In.
class GoogleOAuthTokens {
  const GoogleOAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;

  /// Classic OAuth refresh token, or [playServicesRefreshMarker] when tokens
  /// come from Google Sign-In (no client secret; refresh via Play Services).
  final String refreshToken;
  final DateTime expiresAt;

  bool get usesPlayServices => refreshToken == playServicesRefreshMarker;
}

/// Sentinel stored instead of a refresh token when using Google Sign-In.
const playServicesRefreshMarker = 'google_sign_in';

/// Google Drive auth for Android / web Sign-In and desktop loopback OAuth.
///
/// **Android (phone / most TVs with Play Services):** [signInWithGoogle] uses
/// `google_sign_in` + an **Android** OAuth client registered in Cloud Console
/// (package name + SHA-1). Play Services matches that client by signing cert —
/// the Android client id is **not** passed to [GoogleSignIn.initialize]
/// (`clientId` is unsupported on Android). [bundledClientId] is the public
/// **Web** client used as `serverClientId` for both stable and Dev.
///
/// **Web (`web.javp.app`):** same [bundledClientId] as `clientId` for Google
/// Identity Services. Interactive sign-in must use the GIS button
/// ([GoogleSignIn.supportsAuthenticate] is false on web); then call
/// [authorizeDriveScopes] / [tokensFromGoogleAccount]. Add
/// `https://web.javp.app` under Authorized JavaScript origins in Cloud Console.
///
/// **Desktop (Windows / Linux / macOS):** [signInWithLoopbackPkce] opens the
/// system browser and completes OAuth on `http://127.0.0.1:<port>/` with PKCE.
/// Needs a **Desktop** OAuth client id ([bundledDesktopClientId]). Google still
/// requires `client_secret` at token exchange even with PKCE — public builds
/// POST the code/refresh to [tokenProxyUrl] on javp.app (secret stays server-
/// side). Private builds may still pass `--dart-define=GOOGLE_OAUTH_CLIENT_SECRET=…`
/// to talk to Google directly.
///
/// **Device-code flow** remains for limited-input / private builds that Google
/// forces through a TV client — that path also needs a secret at token exchange.
class GoogleDriveAuth {
  GoogleDriveAuth({http.Client? httpClient})
      : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// Public Web client id — `serverClientId` for Google Sign-In on Android.
  /// Shared by stable (`com.javp.javp`) and Dev (`com.javp.javp.dev`).
  static const bundledClientId = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_ID',
    defaultValue:
        '965786633149-037sok3u5nfo74lvlo7pfjhpg0tdm78t.apps.googleusercontent.com',
  );

  /// Dev Android OAuth client id (`com.javp.javp.dev` + release SHA-1).
  ///
  /// Registered in Cloud Console only — not used as [bundledClientId] /
  /// `serverClientId`. Override with
  /// `--dart-define=GOOGLE_OAUTH_ANDROID_CLIENT_ID_DEV=…` if needed.
  static const bundledAndroidClientIdDev = String.fromEnvironment(
    'GOOGLE_OAUTH_ANDROID_CLIENT_ID_DEV',
    defaultValue:
        '965786633149-2har3dj0ofrecqidbmpqcvptcfmggmll.apps.googleusercontent.com',
  );

  /// Android application id expected for Google Sign-In on this build channel.
  static String get expectedAndroidPackage => UpdateChannel.current.isDev
      ? 'com.javp.javp.dev'
      : 'com.javp.javp';

  /// Public Desktop client id for loopback + PKCE. Falls back to
  /// [bundledClientId] when unset — create a Desktop OAuth client in Cloud
  /// Console and pass `--dart-define=GOOGLE_OAUTH_DESKTOP_CLIENT_ID=…` (or
  /// change the default) if the Web client rejects loopback redirects.
  static const bundledDesktopClientId = String.fromEnvironment(
    'GOOGLE_OAUTH_DESKTOP_CLIENT_ID',
    defaultValue:
        '965786633149-a8dpg66i131mms8gh2ce09fo67hdgk9u.apps.googleusercontent.com',
  );

  /// Optional private-build override. Public desktop builds leave this empty
  /// and use [tokenProxyUrl] instead of embedding the Desktop secret.
  static const bundledClientSecret = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_SECRET',
    defaultValue: '',
  );

  /// javp.app PHP proxy that adds the Desktop client_secret server-side.
  static const tokenProxyUrl = String.fromEnvironment(
    'GOOGLE_OAUTH_TOKEN_PROXY_URL',
    defaultValue: 'https://javp.app/api/google-oauth.php',
  );

  static const scope = 'https://www.googleapis.com/auth/drive.file';
  static const scopes = <String>[scope];

  static const _authUrl = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _codeUrl = 'https://oauth2.googleapis.com/device/code';
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';

  final http.Client _http;
  final bool _ownsClient;
  bool _signInReady = false;

  String effectiveClientId(String? custom) {
    final trimmed = custom?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    return bundledClientId;
  }

  /// Client id for desktop loopback / device-code (Desktop OAuth client).
  String effectiveDesktopClientId(String? custom) {
    final trimmed = custom?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    if (bundledDesktopClientId.isNotEmpty) return bundledDesktopClientId;
    return bundledClientId;
  }

  String effectiveClientSecret(String? custom) {
    final trimmed = custom?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    return bundledClientSecret;
  }

  bool get hasBundledClientId => bundledClientId.isNotEmpty;

  bool get hasBundledClientSecret => bundledClientSecret.isNotEmpty;

  /// True when this platform can use Google Sign-In (no client secret).
  ///
  /// On web, GIS still requires the official sign-in button — see
  /// [usesGisSignInButton] — then [authorizeDriveScopes].
  bool get supportsGoogleSignIn {
    if (kIsWeb) return hasBundledClientId;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Web must show Google's button; [signInWithGoogle] / `authenticate` throw.
  bool get usesGisSignInButton => kIsWeb && supportsGoogleSignIn;

  /// Desktop browsers + local redirect (preferred Windows / Linux / macOS path).
  bool get supportsLoopbackPkce {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  /// Limited-input fallback when Play Services Sign-In is unavailable.
  ///
  /// Needs a client secret at token exchange (bundled via dart-define for
  /// private builds). Prefer [signInWithLoopbackPkce] on desktop.
  bool get supportsDeviceCodeFlow {
    if (kIsWeb) return false;
    return !supportsGoogleSignIn &&
        (Platform.isWindows ||
            Platform.isLinux ||
            Platform.isMacOS ||
            Platform.isAndroid);
  }

  bool get canStartDeviceCode {
    return supportsDeviceCodeFlow &&
        (hasBundledClientId || bundledClientSecret.isNotEmpty);
  }

  Future<void> ensureSignInInitialized({String? serverClientId}) =>
      _ensureSignInInitialized(serverClientId: serverClientId);

  Future<void> _ensureSignInInitialized({String? serverClientId}) async {
    if (_signInReady) return;
    final webClientId = effectiveClientId(serverClientId);
    if (kIsWeb) {
      // Web GIS requires the OAuth Web client as [clientId].
      await GoogleSignIn.instance.initialize(
        clientId: webClientId.isEmpty ? null : webClientId,
      );
    } else {
      await GoogleSignIn.instance.initialize(
        // Web client id (public). Required on Android without google-services.json.
        serverClientId: webClientId.isEmpty ? null : webClientId,
      );
    }
    _signInReady = true;
  }

  /// Interactive Google Sign-In + Drive file scope. Preferred on Android/iOS.
  ///
  /// On web, use the GIS button + [tokensFromGoogleAccount] instead —
  /// [GoogleSignIn.authenticate] is unsupported there.
  Future<GoogleOAuthTokens> signInWithGoogle({String? serverClientId}) async {
    if (!supportsGoogleSignIn) {
      throw StateError(
        'Google Sign-In is not available on this platform.',
      );
    }
    if (usesGisSignInButton) {
      throw StateError(
        'On web, use the Google sign-in button, then authorize Drive access.',
      );
    }
    await _ensureSignInInitialized(serverClientId: serverClientId);
    // Clear any stale Credential Manager session first. A previous failed
    // attempt (or switching debug→release signing) otherwise often fails with
    // "[16] Account reauth failed" on every subsequent authenticate().
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    try {
      final account = await GoogleSignIn.instance.authenticate();
      return tokensFromGoogleAccount(account);
    } on GoogleSignInException catch (e) {
      final detail = e.description ?? e.toString();
      if (detail.toLowerCase().contains('reauth')) {
        throw StateError(
          'Google Sign-In failed (account reauth). '
          'Confirm the release SHA-1 is registered for '
          '$expectedAndroidPackage in Google Cloud Console, then try again.',
        );
      }
      throw StateError(detail);
    }
  }

  /// Requests Drive file scope and returns tokens for [account].
  Future<GoogleOAuthTokens> tokensFromGoogleAccount(
    GoogleSignInAccount account,
  ) async {
    final authz = await account.authorizationClient.authorizeScopes(scopes);
    return GoogleOAuthTokens(
      accessToken: authz.accessToken,
      refreshToken: playServicesRefreshMarker,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 50)),
    );
  }

  /// Drive scope grant after GIS identity sign-in (web) or for re-auth.
  Future<GoogleOAuthTokens> authorizeDriveScopes({
    String? serverClientId,
  }) async {
    await _ensureSignInInitialized(serverClientId: serverClientId);
    try {
      final authz = await GoogleSignIn.instance.authorizationClient
          .authorizeScopes(scopes);
      return GoogleOAuthTokens(
        accessToken: authz.accessToken,
        refreshToken: playServicesRefreshMarker,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 50)),
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.uiUnavailable ||
          (e.description ?? '').toLowerCase().contains('popup')) {
        throw StateError('popup_blocked');
      }
      throw StateError(e.description ?? e.toString());
    }
  }

  /// Silent Drive scope check (no UI). Null when the user must click again.
  Future<GoogleOAuthTokens?> authorizationForDriveScopesIfGranted({
    String? serverClientId,
  }) async {
    await _ensureSignInInitialized(serverClientId: serverClientId);
    try {
      final authz = await GoogleSignIn.instance.authorizationClient
          .authorizationForScopes(scopes)
          .timeout(const Duration(seconds: 5));
      if (authz == null) return null;
      return GoogleOAuthTokens(
        accessToken: authz.accessToken,
        refreshToken: playServicesRefreshMarker,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 50)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Silently refresh an access token previously obtained via Google Sign-In.
  ///
  /// Never prompts — used by auto-sync on startup/resume. Interactive auth
  /// belongs in [signInWithGoogle] only (Settings / restore).
  ///
  /// Uses [GoogleSignIn.authorizationClient] alone. Credential Manager's
  /// lightweight auth path shows a "Connexion" / Sign-in sheet even when the
  /// account is already known, so it must not run on the auto-sync path.
  Future<GoogleOAuthTokens> refreshViaGoogleSignIn({
    String? serverClientId,
  }) async {
    await _ensureSignInInitialized(serverClientId: serverClientId);
    late final GoogleSignInClientAuthorization? authz;
    try {
      authz = await GoogleSignIn.instance.authorizationClient
          .authorizationForScopes(scopes)
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw StateError('Google Drive session expired. Sign in again.');
    }
    if (authz == null) {
      throw StateError('Google Drive session expired. Sign in again.');
    }
    return GoogleOAuthTokens(
      accessToken: authz.accessToken,
      refreshToken: playServicesRefreshMarker,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 50)),
    );
  }

  /// Drops a stale access token from Play Services caches (e.g. after a 401).
  Future<void> clearCachedAccessToken(String accessToken) async {
    final trimmed = accessToken.trim();
    if (trimmed.isEmpty || !supportsGoogleSignIn) return;
    await _ensureSignInInitialized();
    try {
      await GoogleSignIn.instance.authorizationClient
          .clearAuthorizationToken(accessToken: trimmed);
    } catch (_) {}
  }

  Future<void> signOutGoogle() async {
    if (!supportsGoogleSignIn) return;
    await _ensureSignInInitialized();
    await GoogleSignIn.instance.signOut();
  }

  /// Desktop OAuth: browser + loopback redirect + PKCE.
  ///
  /// Token exchange uses [tokenProxyUrl] unless [clientSecret] /
  /// [bundledClientSecret] is set. [openUrl] defaults to the system browser.
  Future<GoogleOAuthTokens> signInWithLoopbackPkce({
    String? clientId,
    String clientSecret = '',
    bool Function()? isCancelled,
    Future<bool> Function(Uri authUrl)? openUrl,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (!supportsLoopbackPkce) {
      throw StateError('Loopback Google sign-in is not available here.');
    }
    final id = effectiveDesktopClientId(clientId);
    if (id.isEmpty) {
      throw StateError(
        'Desktop Drive sync needs a Google OAuth Desktop client id.',
      );
    }

    final cancelled = isCancelled ?? () => false;
    final pkce = GooglePkce.generate();
    final state = GooglePkce.randomUrlSafe(32);

    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (e) {
      throw StateError('Could not start local sign-in listener: $e');
    }

    final redirectUri = 'http://127.0.0.1:${server.port}/';
    final authUri = Uri.parse(_authUrl).replace(
      queryParameters: <String, String>{
        'client_id': id,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scope,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'access_type': 'offline',
        'prompt': 'consent',
        'include_granted_scopes': 'true',
      },
    );

    final codeCompleter = Completer<String>();
    late final StreamSubscription<HttpRequest> sub;
    sub = server.listen((request) async {
      try {
        final params = request.uri.queryParameters;
        final error = params['error'];
        final code = params['code'];
        final returnedState = params['state'];
        if (error != null && error.isNotEmpty) {
          final description = params['error_description'] ?? error;
          await _writeLoopbackPage(
            request,
            title: 'Sign-in failed',
            body: 'Google returned an error: $description',
          );
          if (!codeCompleter.isCompleted) {
            codeCompleter.completeError(
              StateError('Google sign-in failed: $description'),
            );
          }
          return;
        }
        if (returnedState != state) {
          await _writeLoopbackPage(
            request,
            title: 'Sign-in failed',
            body: 'Invalid OAuth state. Close this tab and try again in JAVP.',
          );
          if (!codeCompleter.isCompleted) {
            codeCompleter.completeError(
              StateError('Google sign-in failed (invalid state).'),
            );
          }
          return;
        }
        if (code == null || code.isEmpty) {
          await _writeLoopbackPage(
            request,
            title: 'Sign-in failed',
            body: 'No authorization code. Close this tab and try again in JAVP.',
          );
          if (!codeCompleter.isCompleted) {
            codeCompleter.completeError(
              StateError('Google sign-in returned no code.'),
            );
          }
          return;
        }
        await _writeLoopbackPage(
          request,
          title: 'Signed in',
          body: 'You can close this tab and return to JAVP.',
        );
        if (!codeCompleter.isCompleted) {
          codeCompleter.complete(code);
        }
      } catch (e) {
        if (!codeCompleter.isCompleted) {
          codeCompleter.completeError(e);
        }
      }
    }, onError: (Object e) {
      if (!codeCompleter.isCompleted) {
        codeCompleter.completeError(e);
      }
    });

    try {
      final opener = openUrl ??
          (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
      final launched = await opener(authUri);
      if (!launched) {
        throw StateError('Could not open the system browser for Google sign-in.');
      }

      final code = await Future.any<String>([
        codeCompleter.future,
        _waitUntilCancelled(cancelled, timeout),
      ]);

      return exchangeAuthorizationCode(
        clientId: id,
        clientSecret: clientSecret,
        code: code,
        codeVerifier: pkce.verifier,
        redirectUri: redirectUri,
      );
    } finally {
      await sub.cancel();
      await server.close(force: true);
    }
  }

  /// Exchanges an auth code (+ PKCE verifier) for tokens.
  Future<GoogleOAuthTokens> exchangeAuthorizationCode({
    required String clientId,
    required String code,
    required String codeVerifier,
    required String redirectUri,
    String clientSecret = '',
  }) async {
    final id = effectiveDesktopClientId(clientId);
    final body = <String, String>{
      'client_id': id,
      'code': code,
      'code_verifier': codeVerifier,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
    };
    final response = await _postTokenRequest(body, clientSecret: clientSecret);
    if (response.statusCode >= 400) {
      final decoded = _tryJson(response.body);
      final description =
          decoded?['error_description'] as String? ?? response.body;
      final error = decoded?['error'] as String? ?? '';
      if (error == 'redirect_uri_mismatch' ||
          description.toLowerCase().contains('redirect_uri')) {
        throw StateError(
          'Google rejected the desktop redirect. In Google Cloud Console, '
          'create an OAuth client of type Desktop and set '
          'GOOGLE_OAUTH_DESKTOP_CLIENT_ID to that client id '
          '(the Web client used for Android Sign-In cannot use loopback).',
        );
      }
      if (error == 'misconfigured' ||
          (error == 'invalid_request' &&
              description.toLowerCase().contains('client_secret'))) {
        throw StateError(
          'Desktop Drive token exchange failed. Check that javp.app’s OAuth '
          'proxy is configured, or use Folder sync with the Google Drive '
          'desktop app.',
        );
      }
      throw StateError(
        'Google token exchange failed (${response.statusCode}): $description',
      );
    }
    return _parseTokens(response.body, requireRefresh: true);
  }

  Future<GoogleDeviceCodeSession> requestDeviceCode(String clientId) async {
    final id = effectiveDesktopClientId(clientId);
    if (id.isEmpty) {
      throw StateError(
        'Device-code flow needs a TV OAuth client id. Prefer Google Sign-In '
        'on Android, or loopback PKCE on desktop.',
      );
    }
    final response = await _http.post(
      Uri.parse(_codeUrl),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': id,
        'scope': scope,
      },
    );
    if (response.statusCode >= 400) {
      throw StateError(
        'Google device code failed (${response.statusCode}): ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Google device code returned unexpected body');
    }
    final session = GoogleDeviceCodeSession.fromJson(decoded);
    if (session.deviceCode.isEmpty || session.userCode.isEmpty) {
      throw StateError('Google device code response was incomplete');
    }
    return session;
  }

  /// Polls until the user approves the code on another device.
  ///
  /// Requires [clientSecret] — do not embed that secret in a public binary.
  Future<GoogleOAuthTokens> waitForTokens({
    required String clientId,
    required GoogleDeviceCodeSession session,
    required bool Function() isCancelled,
    String clientSecret = '',
  }) async {
    final id = effectiveDesktopClientId(clientId);
    final deadline = DateTime.now().add(Duration(seconds: session.expiresIn));
    final interval = Duration(seconds: session.interval.clamp(3, 30));

    while (true) {
      if (isCancelled()) {
        throw StateError('Google sign-in cancelled');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Google sign-in expired — try again');
      }

      final body = <String, String>{
        'client_id': id,
        'device_code': session.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      };
      final secret = effectiveClientSecret(clientSecret);
      if (secret.isNotEmpty) body['client_secret'] = secret;

      final response = await _http.post(
        Uri.parse(_tokenUrl),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: body,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _parseTokens(response.body, requireRefresh: true);
      }

      final decoded = _tryJson(response.body);
      final error = decoded?['error'] as String?;
      final description = decoded?['error_description'] as String? ?? '';
      if (error == 'authorization_pending' || error == 'slow_down') {
        final wait = error == 'slow_down'
            ? interval + const Duration(seconds: 5)
            : interval;
        await Future<void>.delayed(wait);
        continue;
      }
      if (error == 'access_denied') {
        throw StateError('Google sign-in was denied');
      }
      if (error == 'expired_token') {
        throw StateError('Google sign-in expired — try again');
      }
      if (error == 'invalid_request' &&
          description.toLowerCase().contains('client_secret')) {
        throw StateError(
          'Device-code auth needs a client secret. Prefer Google Sign-In on '
          'Android, or desktop loopback with '
          '--dart-define=GOOGLE_OAUTH_CLIENT_SECRET=….',
        );
      }
      throw StateError(
        'Google token poll failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<GoogleOAuthTokens> refresh({
    required String clientId,
    required String refreshToken,
    String clientSecret = '',
  }) async {
    if (refreshToken == playServicesRefreshMarker) {
      return refreshViaGoogleSignIn(serverClientId: clientId);
    }
    // Refresh may have been issued to either the Web or Desktop client id.
    final id = clientId.trim().isNotEmpty
        ? clientId.trim()
        : effectiveDesktopClientId(null);
    final body = <String, String>{
      'client_id': id,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    };
    final response = await _postTokenRequest(body, clientSecret: clientSecret);
    if (response.statusCode >= 400) {
      throw StateError(
        'Google token refresh failed (${response.statusCode}): ${response.body}',
      );
    }
    final tokens = _parseTokens(response.body, requireRefresh: false);
    return GoogleOAuthTokens(
      accessToken: tokens.accessToken,
      refreshToken:
          tokens.refreshToken.isNotEmpty ? tokens.refreshToken : refreshToken,
      expiresAt: tokens.expiresAt,
    );
  }

  /// Posts to Google directly when a secret is available; otherwise uses the
  /// javp.app proxy (which injects the Desktop client_secret server-side).
  Future<http.Response> _postTokenRequest(
    Map<String, String> body, {
    String clientSecret = '',
  }) async {
    final secret = effectiveClientSecret(clientSecret);
    final useProxy = secret.isEmpty;
    if (useProxy) {
      final proxy = tokenProxyUrl.trim();
      if (proxy.isEmpty) {
        throw StateError(
          'Desktop Drive sync needs javp.app’s OAuth proxy, or a private '
          'GOOGLE_OAUTH_CLIENT_SECRET. Or use Folder sync instead.',
        );
      }
      return _http.post(
        Uri.parse(proxy),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: body,
      );
    }
    final direct = Map<String, String>.from(body);
    direct['client_secret'] = secret;
    return _http.post(
      Uri.parse(_tokenUrl),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: direct,
    );
  }

  static Future<void> _writeLoopbackPage(
    HttpRequest request, {
    required String title,
    required String body,
  }) async {
    final html = '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>$title</title>
<style>
body{font-family:system-ui,sans-serif;background:#111;color:#eee;
display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
main{max-width:28rem;padding:2rem;text-align:center}
h1{font-size:1.25rem;margin:0 0 .75rem}
p{opacity:.85;line-height:1.45}
</style></head>
<body><main><h1>$title</h1><p>$body</p></main></body></html>
''';
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.html;
    request.response.write(html);
    await request.response.close();
  }

  static Future<String> _waitUntilCancelled(
    bool Function() isCancelled,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (isCancelled()) {
        throw StateError('Google sign-in cancelled');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Google sign-in expired — try again');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  static GoogleOAuthTokens _parseTokens(
    String body, {
    required bool requireRefresh,
  }) {
    final decoded = _tryJson(body);
    if (decoded == null) {
      throw StateError('Google token response was not JSON');
    }
    final access = decoded['access_token'] as String? ?? '';
    final refresh = decoded['refresh_token'] as String? ?? '';
    final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 3600;
    if (access.isEmpty) {
      throw StateError('Google token response had no access_token');
    }
    if (requireRefresh && refresh.isEmpty) {
      throw StateError('Google token response had no refresh_token');
    }
    return GoogleOAuthTokens(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.now().toUtc().add(Duration(seconds: expiresIn)),
    );
  }

  static Map<String, dynamic>? _tryJson(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}

/// PKCE verifier / S256 challenge helpers (testable without network).
class GooglePkce {
  const GooglePkce({required this.verifier, required this.challenge});

  final String verifier;
  final String challenge;

  static GooglePkce generate({Random? random}) {
    final verifier = randomUrlSafe(64, random: random);
    return GooglePkce(verifier: verifier, challenge: challengeS256(verifier));
  }

  static String challengeS256(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  static String randomUrlSafe(int length, {Random? random}) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = random ?? Random.secure();
    return List<String>.generate(
      length,
      (_) => alphabet[rng.nextInt(alphabet.length)],
    ).join();
  }
}
