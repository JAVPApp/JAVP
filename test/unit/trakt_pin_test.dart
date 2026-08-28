import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/models/trakt_models.dart';
import 'package:javp/services/trakt/trakt_client.dart';

void main() {
  test('requestDeviceCode returns session from Trakt payload', () async {
    final client = TraktClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/oauth/device/code');
        expect(request.headers['trakt-api-key'], 'cid');
        expect(request.headers['trakt-api-version'], '2');
        return http.Response(
          jsonEncode({
            'device_code': 'devcode',
            'user_code': 'ABCD',
            'verification_url': 'https://trakt.tv/activate',
            'expires_in': 600,
            'interval': 5,
          }),
          200,
        );
      }),
    );

    final session = await client.requestDeviceCode(
      const TraktCredentials(clientId: 'cid', clientSecret: 'sec'),
    );
    expect(session.userCode, 'ABCD');
    expect(session.deviceCode, 'devcode');
    expect(session.verificationUri.host, 'trakt.tv');
    expect(session.scanUri.toString(), 'https://trakt.tv/activate');
    client.close();
  });

  test('waitForDeviceToken returns access_token after pending poll', () async {
    var calls = 0;
    final client = TraktClient(
      httpClient: MockClient((request) async {
        calls += 1;
        expect(request.url.path, '/oauth/device/token');
        if (calls == 1) {
          return http.Response(
            jsonEncode({'error': 'authorization_pending'}),
            400,
          );
        }
        return http.Response(
          jsonEncode({
            'access_token': 'tok_trakt',
            'refresh_token': 'ref',
            'expires_in': 7200,
          }),
          200,
        );
      }),
    );

    final session = TraktDeviceSession(
      deviceCode: 'devcode',
      userCode: 'ABCD',
      verificationUri: Uri.parse('https://trakt.tv/activate'),
      expiresIn: 60,
      interval: 1,
    );

    final token = await client.waitForDeviceToken(
      creds: const TraktCredentials(clientId: 'cid', clientSecret: 'sec'),
      session: session,
      isCancelled: () => false,
    );

    expect(token.accessToken, 'tok_trakt');
    expect(token.refreshToken, 'ref');
    expect(calls, 2);
    client.close();
  });
}
