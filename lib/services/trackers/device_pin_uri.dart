/// URL a phone should open for a device/PIN login.
///
/// Prefers RFC 8628 `verification_uri_complete` when the provider sent one
/// (code already in the link). Otherwise the base verification page — the
/// user still types the code shown on the TV.
Uri devicePinScanUri(Uri verificationUri, [Uri? verificationUriComplete]) {
  final complete = verificationUriComplete;
  if (complete != null && complete.hasScheme && complete.host.isNotEmpty) {
    return complete;
  }
  return verificationUri;
}

Uri? parseOptionalUri(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return uri;
}
