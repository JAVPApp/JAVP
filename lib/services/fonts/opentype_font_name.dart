import 'dart:typed_data';

/// Reads the font family name from a TTF/OTF (sfnt) blob.
String? readOpenTypeFamilyName(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final data = ByteData.sublistView(bytes);
  final numTables = data.getUint16(4);
  const tableDirOffset = 12;
  const tableRecordSize = 16;
  if (bytes.length < tableDirOffset + numTables * tableRecordSize) {
    return null;
  }

  int? nameOffset;
  int? nameLength;
  for (var i = 0; i < numTables; i++) {
    final base = tableDirOffset + i * tableRecordSize;
    final tag = String.fromCharCodes(bytes.sublist(base, base + 4));
    if (tag != 'name') continue;
    nameOffset = data.getUint32(base + 8);
    nameLength = data.getUint32(base + 12);
    break;
  }
  if (nameOffset == null || nameLength == null) return null;
  if (nameOffset + nameLength > bytes.length || nameLength < 6) return null;

  final nameData = ByteData.sublistView(bytes, nameOffset, nameOffset + nameLength);
  final count = nameData.getUint16(2);
  final stringOffset = nameData.getUint16(4);
  if (6 + count * 12 > nameLength) return null;

  String? best;
  var bestScore = -1;
  for (var i = 0; i < count; i++) {
    final rec = 6 + i * 12;
    final platformId = nameData.getUint16(rec);
    final encodingId = nameData.getUint16(rec + 2);
    final languageId = nameData.getUint16(rec + 4);
    final nameId = nameData.getUint16(rec + 6);
    final length = nameData.getUint16(rec + 8);
    final offset = nameData.getUint16(rec + 10);
    // Font Family (1). Prefer typographic family (16) when present.
    if (nameId != 1 && nameId != 16) continue;
    final abs = stringOffset + offset;
    if (abs + length > nameLength) continue;
    final raw = bytes.sublist(nameOffset + abs, nameOffset + abs + length);
    final decoded = _decodeName(platformId, encodingId, raw);
    if (decoded == null || decoded.trim().isEmpty) continue;

    var score = nameId == 16 ? 20 : 10;
    if (platformId == 3 && (encodingId == 1 || encodingId == 10)) score += 5;
    if (platformId == 1 && encodingId == 0) score += 2;
    if (languageId == 0x0409 || languageId == 0) score += 1;
    if (score > bestScore) {
      bestScore = score;
      best = decoded.trim();
    }
  }
  return best;
}

String? _decodeName(int platformId, int encodingId, List<int> raw) {
  if (raw.isEmpty) return null;
  // Windows Unicode BMP / full repertoire, or Unicode platform.
  if (platformId == 3 && (encodingId == 1 || encodingId == 10) ||
      platformId == 0) {
    if (raw.length.isOdd) return null;
    final codeUnits = <int>[];
    for (var i = 0; i < raw.length; i += 2) {
      codeUnits.add((raw[i] << 8) | raw[i + 1]);
    }
    return String.fromCharCodes(codeUnits);
  }
  // Mac Roman (common for older fonts).
  if (platformId == 1) {
    return String.fromCharCodes(raw);
  }
  return null;
}
