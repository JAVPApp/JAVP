class AppUpdateApk {
  const AppUpdateApk({required this.url, this.sha256});

  final String url;
  final String? sha256;

  factory AppUpdateApk.fromJson(Map<String, dynamic> json) {
    final url = (json['url'] ?? json['apkUrl'] ?? '').toString();
    if (url.isEmpty) {
      throw FormatException('Invalid update APK entry: $json');
    }
    return AppUpdateApk(
      url: url,
      sha256: json['sha256']?.toString() ?? json['apkSha256']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    if (sha256 != null) 'sha256': sha256,
  };
}

/// A platform package entry in `latest.json` (`packages.windows-x64`, etc.).
class AppUpdatePackage {
  const AppUpdatePackage({required this.url, this.sha256, this.kind = 'zip'});

  final String url;
  final String? sha256;

  /// `zip` (extracted over the install) or `installer` (opened directly).
  final String kind;

  factory AppUpdatePackage.fromJson(Map<String, dynamic> json) {
    final url = (json['url'] ?? '').toString();
    if (url.isEmpty) {
      throw FormatException('Invalid update package entry: $json');
    }
    return AppUpdatePackage(
      url: url,
      sha256: json['sha256']?.toString(),
      kind: (json['kind'] ?? 'zip').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    if (sha256 != null) 'sha256': sha256,
    if (kind != 'zip') 'kind': kind,
  };
}

/// One public version section from `latest.json` `releases[]`.
///
/// [versionCode] is the pubspec `+N` (not Flutter's ABI-encoded APK code).
class AppUpdateReleaseNotes {
  const AppUpdateReleaseNotes({
    required this.versionName,
    required this.title,
    required this.notes,
    this.versionCode,
  });

  final String versionName;
  final int? versionCode;
  final String title;
  final String notes;

  factory AppUpdateReleaseNotes.fromJson(Map<String, dynamic> json) {
    final notes = (json['notes'] ?? json['changelog'] ?? '').toString();
    final versionName = (json['versionName'] ?? json['version'] ?? '')
        .toString();
    final title = (json['title'] ?? versionName).toString();
    final code =
        (json['versionCode'] as num?)?.toInt() ??
        int.tryParse('${json['baseVersionCode'] ?? ''}');
    return AppUpdateReleaseNotes(
      versionName: versionName,
      versionCode: code,
      title: title,
      notes: notes,
    );
  }

  Map<String, dynamic> toJson() => {
    'versionName': versionName,
    if (versionCode != null) 'versionCode': versionCode,
    'title': title,
    'notes': notes,
  };

  String toMarkdown() {
    final heading = title.trim().isNotEmpty ? title.trim() : versionName.trim();
    final body = notes.trim();
    if (heading.isEmpty) return body;
    if (body.isEmpty) return '## $heading';
    return '## $heading\n\n$body';
  }
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    this.changelog = '',
    this.force = false,
    this.minVersionCode,
    this.baseVersionCode,
    this.apkSha256,
    this.publishedAt,
    this.apks = const {},
    this.packages = const {},
    this.channel,
    this.releases = const [],
  });

  final String versionName;
  final int versionCode;

  /// Default / legacy download URL (usually the universal APK).
  final String apkUrl;

  /// Legacy concatenated notes (this marketing line). Prefer [changelogFor]
  /// when [releases] is present so the dialog can hide already-installed cuts.
  final String changelog;
  final bool force;

  /// If set, installs older than this must update before continuing.
  final int? minVersionCode;

  /// Pubspec build number (`+N`) before Flutter's split-per-abi encoding.
  ///
  /// Flutter writes `abiIndex * 1000 + build` into split APKs, so a phone on
  /// arm64 `0.2.4+6` reports versionCode **2006** while older manifests only
  /// advertised **6** — which made the updater claim "already latest".
  final int? baseVersionCode;
  final String? apkSha256;
  final DateTime? publishedAt;

  /// Optional per-ABI (and `universal`) APK map from `latest.json`.
  final Map<String, AppUpdateApk> apks;

  /// Optional desktop / non-APK packages, keyed by platform id
  /// (e.g. `windows-x64`, `windows-arm64`).
  final Map<String, AppUpdatePackage> packages;

  /// Optional channel id from the manifest (`stable` / `dev`).
  final String? channel;

  /// Newest-first public notes per cut, so the client can slice since the
  /// installed [versionCode].
  final List<AppUpdateReleaseNotes> releases;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final versionName = (json['versionName'] ?? json['version'] ?? '')
        .toString();
    final versionCode =
        (json['versionCode'] as num?)?.toInt() ??
        int.tryParse('${json['build'] ?? ''}') ??
        0;
    final apkUrl = (json['apkUrl'] ?? json['url'] ?? '').toString();

    final packages = <String, AppUpdatePackage>{};
    final rawPackages = json['packages'];
    if (rawPackages is Map) {
      for (final entry in rawPackages.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          packages[key] = AppUpdatePackage.fromJson(value);
        } else if (value is Map) {
          packages[key] = AppUpdatePackage.fromJson(
            Map<String, dynamic>.from(value),
          );
        } else if (value is String && value.isNotEmpty) {
          packages[key] = AppUpdatePackage(url: value);
        }
      }
    }

    // Android manifests always carry apkUrl; a desktop-only release may not.
    if (versionName.isEmpty ||
        versionCode <= 0 ||
        (apkUrl.isEmpty && packages.isEmpty)) {
      throw FormatException('Invalid update manifest: $json');
    }

    final apks = <String, AppUpdateApk>{};
    final rawApks = json['apks'];
    if (rawApks is Map) {
      for (final entry in rawApks.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          apks[key] = AppUpdateApk.fromJson(value);
        } else if (value is Map) {
          apks[key] = AppUpdateApk.fromJson(Map<String, dynamic>.from(value));
        } else if (value is String && value.isNotEmpty) {
          apks[key] = AppUpdateApk(url: value);
        }
      }
    }

    final channelRaw = json['channel']?.toString().trim();
    final releases = <AppUpdateReleaseNotes>[];
    final rawReleases = json['releases'] ?? json['changelogReleases'];
    if (rawReleases is List) {
      for (final item in rawReleases) {
        Map<String, dynamic>? map;
        if (item is Map<String, dynamic>) {
          map = item;
        } else if (item is Map) {
          map = Map<String, dynamic>.from(item);
        }
        if (map == null) continue;
        final parsed = AppUpdateReleaseNotes.fromJson(map);
        if (parsed.notes.trim().isEmpty) continue;
        releases.add(parsed);
      }
    }
    return AppUpdateInfo(
      versionName: versionName,
      versionCode: versionCode,
      apkUrl: apkUrl,
      changelog: (json['changelog'] ?? '').toString(),
      force: json['force'] == true || json['forceUpdate'] == true,
      minVersionCode: (json['minVersionCode'] as num?)?.toInt(),
      baseVersionCode: (json['baseVersionCode'] as num?)?.toInt(),
      apkSha256: json['apkSha256']?.toString(),
      publishedAt: DateTime.tryParse('${json['publishedAt'] ?? ''}'),
      apks: apks,
      packages: packages,
      channel: (channelRaw == null || channelRaw.isEmpty) ? null : channelRaw,
      releases: releases,
    );
  }

  Map<String, dynamic> toJson() => {
    'versionName': versionName,
    'versionCode': versionCode,
    'apkUrl': apkUrl,
    'changelog': changelog,
    'force': force,
    if (minVersionCode != null) 'minVersionCode': minVersionCode,
    if (baseVersionCode != null) 'baseVersionCode': baseVersionCode,
    if (apkSha256 != null) 'apkSha256': apkSha256,
    if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
    if (apks.isNotEmpty)
      'apks': {for (final e in apks.entries) e.key: e.value.toJson()},
    if (channel != null) 'channel': channel,
    if (releases.isNotEmpty) 'releases': [for (final r in releases) r.toJson()],
  };

  /// Strip Flutter `--split-per-abi` encoding (`abiIndex * 1000 + build`).
  ///
  /// Build numbers must stay below 1000 for this to round-trip cleanly.
  static int comparableVersionCode(int versionCode) {
    if (versionCode < 1000) return versionCode;
    return versionCode % 1000;
  }

  int get effectiveBaseVersionCode =>
      baseVersionCode ?? comparableVersionCode(versionCode);

  /// Picks the best APK for [preferredAbis] (first match wins), then
  /// `universal`, then the legacy [apkUrl].
  AppUpdateApk resolveApk({List<String> preferredAbis = const []}) {
    for (final abi in preferredAbis) {
      final match = apks[abi];
      if (match != null) return match;
    }
    final universal = apks['universal'];
    if (universal != null) return universal;
    return AppUpdateApk(url: apkUrl, sha256: apkSha256);
  }

  /// Picks a desktop package for [preferredKeys] (first match wins).
  AppUpdatePackage? resolvePackage({List<String> preferredKeys = const []}) {
    for (final key in preferredKeys) {
      final match = packages[key];
      if (match != null) return match;
    }
    return null;
  }

  bool isNewerThan({required int currentVersionCode}) =>
      effectiveBaseVersionCode > comparableVersionCode(currentVersionCode);

  /// User-facing notes newer than the installed build.
  ///
  /// Falls back to the concatenated [changelog] blob when the manifest has no
  /// [releases] (older `latest.json`) or the slice is empty.
  String changelogFor({
    required int currentVersionCode,
    String currentVersionName = '',
  }) {
    if (releases.isEmpty) return changelog;
    final current = comparableVersionCode(currentVersionCode);
    final selected = [
      for (final release in releases)
        if (_releaseIsNewerThan(
          release,
          currentVersionCode: current,
          currentVersionName: currentVersionName,
        ))
          release,
    ];
    if (selected.isEmpty) return changelog;
    return selected
        .map((r) => r.toMarkdown())
        .where((s) => s.trim().isNotEmpty)
        .join('\n\n');
  }

  static bool _releaseIsNewerThan(
    AppUpdateReleaseNotes release, {
    required int currentVersionCode,
    required String currentVersionName,
  }) {
    final code = release.versionCode;
    if (code != null) {
      return comparableVersionCode(code) > currentVersionCode;
    }
    if (currentVersionName.trim().isEmpty) return true;
    return compareMarketingVersion(release.versionName, currentVersionName) > 0;
  }

  /// Compare `X.Y.Z` (optional `-dev` / `+N`) numerically.
  static int compareMarketingVersion(String a, String b) {
    final pa = _marketingParts(a);
    final pb = _marketingParts(b);
    for (var i = 0; i < 3; i++) {
      final c = pa[i].compareTo(pb[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  static List<int> _marketingParts(String raw) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(raw.trim());
    if (match == null) return const [0, 0, 0];
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  bool isRequiredFor({required int currentVersionCode}) {
    if (force && isNewerThan(currentVersionCode: currentVersionCode)) {
      return true;
    }
    final min = minVersionCode;
    if (min == null) return false;
    return comparableVersionCode(currentVersionCode) <
        comparableVersionCode(min);
  }
}
