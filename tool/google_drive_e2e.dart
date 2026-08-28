/// Live smoke: device-code → (manual approve) → probe + write/read.
///
/// Run: dart run tool/google_drive_e2e.dart
/// When a user_code prints, open https://www.google.com/device and approve.
library;

import 'dart:io';

import 'package:javp/services/sync/google_drive_auth.dart';
import 'package:javp/services/sync/google_drive_remote.dart';

Future<void> main() async {
  final auth = GoogleDriveAuth();
  stdout.writeln('Requesting device code (scope=${GoogleDriveAuth.scope})…');
  final session = await auth.requestDeviceCode('');
  stdout.writeln('');
  stdout.writeln('Open: ${session.verificationUrl}');
  stdout.writeln('Code: ${session.userCode}');
  stdout.writeln('');
  stdout.writeln('Waiting for approval…');

  final tokens = await auth.waitForTokens(
    clientId: '',
    session: session,
    isCancelled: () => false,
  );
  stdout.writeln('Got tokens. Probing Drive…');

  final remote = GoogleDriveRemote(
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    tokenExpiry: tokens.expiresAt,
    clientId: GoogleDriveAuth.bundledClientId,
  );
  try {
    await remote.probe();
    stdout.writeln('probe ok');
    const path = 'javp/profiles/_e2e_probe.json';
    await remote.write(path, '{"ok":true}');
    final read = await remote.read(path);
    stdout.writeln('write/read ok: $read');
    await remote.delete(path);
    stdout.writeln('delete ok — Google Drive sync works');
  } finally {
    remote.close();
    auth.close();
  }
}
