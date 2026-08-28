import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:javp/compat/javp_compute.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-disk profile photos (one JPEG per profile id).
///
/// Bytes stay out of SharedPreferences so large photos cannot bloat the
/// registry; sync carries a base64 copy inside [ProfileSnapshot].
class ProfileAvatarStore {
  ProfileAvatarStore({this._overrideRoot});

  final Directory? _overrideRoot;

  static const _folderName = 'profile_avatars';
  static const _maxEdge = 256;
  static const _jpegQuality = 85;

  Future<Directory> _root() async {
    final override = _overrideRoot;
    if (override != null) {
      if (!await override.exists()) {
        await override.create(recursive: true);
      }
      return override;
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, _folderName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _fileFor(String profileId) async {
    final root = await _root();
    return File(p.join(root.path, '$profileId.jpg'));
  }

  Future<Uint8List?> load(String profileId) async {
    final file = await _fileFor(profileId);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Decodes [raw], downscales to a square-ish JPEG, and writes it.
  ///
  /// Returns the bytes that were stored (for sync), or null when [raw] is not
  /// a usable image.
  Future<Uint8List?> save(String profileId, Uint8List raw) async {
    final encoded = await javpCompute(
      () => encodeAvatar(raw),
      debugLabel: 'avatar-encode',
    );
    if (encoded == null) return null;
    final file = await _fileFor(profileId);
    await file.writeAsBytes(encoded, flush: true);
    return encoded;
  }

  /// Writes already-encoded JPEG bytes from sync without re-encoding.
  Future<void> saveEncoded(String profileId, Uint8List encoded) async {
    final file = await _fileFor(profileId);
    await file.writeAsBytes(encoded, flush: true);
  }

  Future<void> delete(String profileId) async {
    final file = await _fileFor(profileId);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // Best effort — missing file is fine.
      }
    }
  }

  static Uint8List? encodeAvatar(Uint8List raw) {
    if (raw.isEmpty) return null;
    img.Image? decoded;
    try {
      decoded = img.decodeImage(raw);
    } catch (_) {
      return null;
    }
    if (decoded == null) return null;
    final resized = img.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? _maxEdge : null,
      height: decoded.height > decoded.width ? _maxEdge : null,
      interpolation: img.Interpolation.average,
    );
    return Uint8List.fromList(img.encodeJpg(resized, quality: _jpegQuality));
  }

  static String encodeBase64(Uint8List bytes) => base64Encode(bytes);

  static Uint8List? tryDecodeBase64(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(trimmed));
    } catch (_) {
      return null;
    }
  }
}
