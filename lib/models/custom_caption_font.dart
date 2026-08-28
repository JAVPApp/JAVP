/// User-added caption typeface (installed-by-name or imported file).
class CustomCaptionFont {
  const CustomCaptionFont({
    required this.family,
    this.fileName,
  });

  /// Name passed to mpv `sub-font` / Flutter [TextStyle.fontFamily].
  final String family;

  /// Basename under the app caption-fonts directory, when imported from a file.
  final String? fileName;

  bool get isFileBacked => fileName != null && fileName!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'family': family,
        if (fileName != null) 'fileName': fileName,
      };

  factory CustomCaptionFont.fromJson(Map<String, dynamic> json) {
    return CustomCaptionFont(
      family: (json['family'] as String? ?? '').trim(),
      fileName: (json['fileName'] as String?)?.trim(),
    );
  }
}
