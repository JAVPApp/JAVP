import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// PBKDF2-SHA256 PIN material for device-local locks.
///
/// Payload shape is shared by parental controls and profile lock so either
/// store can verify a PIN written by the other helper.
class PinHash {
  static const defaultIterations = 120000;

  static String normalize(String pin) => pin.trim();

  static void assertShape(String pin) {
    if (pin.length < 4 || pin.length > 8) {
      throw ArgumentError('PIN must be 4–8 digits');
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN must be numeric');
    }
  }

  static Future<String> encode(String pin) async {
    final normalized = normalize(pin);
    assertShape(normalized);
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final hash = await derive(normalized, salt, defaultIterations);
    return jsonEncode({
      'v': 1,
      'salt': base64Encode(salt),
      'hash': base64Encode(hash),
      'iterations': defaultIterations,
    });
  }

  static Future<bool> verify(String pin, String payload) async {
    if (payload.isEmpty) return false;
    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final salt = base64Decode(map['salt'] as String);
      final expected = base64Decode(map['hash'] as String);
      final iterations =
          (map['iterations'] as num?)?.toInt() ?? defaultIterations;
      final actual = await derive(normalize(pin), salt, iterations);
      if (actual.length != expected.length) return false;
      var diff = 0;
      for (var i = 0; i < actual.length; i++) {
        diff |= actual[i] ^ expected[i];
      }
      return diff == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<List<int>> derive(
    String pin,
    List<int> salt,
    int iterations,
  ) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final key = await kdf.deriveKeyFromPassword(
      password: pin,
      nonce: Uint8List.fromList(salt),
    );
    return key.extractBytes();
  }
}
