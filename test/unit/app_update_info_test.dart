import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/app_update_info.dart';

void main() {
  test('parses deploy latest.json shape', () {
    final info = AppUpdateInfo.fromJson({
      'versionName': '0.2.0',
      'versionCode': 12,
      'apkUrl': 'https://updater.javp.app/javp.apk',
      'changelog': 'Faster updater',
      'force': false,
      'apkSha256': 'abc',
      'publishedAt': '2026-08-09T12:00:00Z',
    });

    expect(info.versionName, '0.2.0');
    expect(info.versionCode, 12);
    expect(info.isNewerThan(currentVersionCode: 11), isTrue);
    expect(info.isNewerThan(currentVersionCode: 12), isFalse);
    expect(info.isRequiredFor(currentVersionCode: 11), isFalse);
  });

  test('compares Flutter split-per-abi versionCodes via base build', () {
    // Manifest from older deploys advertised pubspec +N (8) while arm64
    // installs report abiIndex*1000+N (2006 for 0.2.4+6).
    final legacyManifest = AppUpdateInfo.fromJson({
      'versionName': '0.2.6',
      'versionCode': 8,
      'apkUrl': 'https://updater.javp.app/javp.apk',
    });
    expect(legacyManifest.isNewerThan(currentVersionCode: 2006), isTrue);
    expect(legacyManifest.isNewerThan(currentVersionCode: 2008), isFalse);

    final patched = AppUpdateInfo.fromJson({
      'versionName': '0.2.6',
      'versionCode': 2008,
      'baseVersionCode': 8,
      'apkUrl': 'https://updater.javp.app/javp.apk',
    });
    expect(patched.effectiveBaseVersionCode, 8);
    expect(patched.isNewerThan(currentVersionCode: 2006), isTrue);
    expect(patched.isNewerThan(currentVersionCode: 8), isFalse);
    expect(patched.isNewerThan(currentVersionCode: 1008), isFalse);
  });

  test('force and minVersionCode mark required updates', () {
    final forced = AppUpdateInfo.fromJson({
      'version': '1.0.0',
      'versionCode': 5,
      'url': 'https://example.com/a.apk',
      'forceUpdate': true,
    });
    expect(forced.isRequiredFor(currentVersionCode: 4), isTrue);

    final gated = AppUpdateInfo.fromJson({
      'versionName': '1.0.0',
      'versionCode': 5,
      'apkUrl': 'https://example.com/a.apk',
      'minVersionCode': 4,
    });
    expect(gated.isRequiredFor(currentVersionCode: 3), isTrue);
    expect(gated.isRequiredFor(currentVersionCode: 4), isFalse);
  });

  test('parses optional channel field alongside apks', () {
    final info = AppUpdateInfo.fromJson({
      'versionName': '0.2.2-dev',
      'versionCode': 5,
      'apkUrl': 'https://updater.javp.app/dev/javp-arm64-v8a.apk',
      'channel': 'dev',
      'apks': {
        'arm64-v8a': {
          'url': 'https://updater.javp.app/dev/javp-arm64-v8a.apk',
          'sha256': 'abc',
        },
      },
    });
    expect(info.channel, 'dev');
    expect(info.toJson()['channel'], 'dev');
    expect(
      info.resolveApk(preferredAbis: const ['arm64-v8a']).url,
      contains('/dev/'),
    );
  });

  test('resolveApk prefers matching ABI then universal then legacy', () {
    final info = AppUpdateInfo.fromJson({
      'versionName': '0.3.0',
      'versionCode': 30,
      'apkUrl': 'https://updater.javp.app/javp.apk',
      'apkSha256': 'uni-sha',
      'apks': {
        'arm64-v8a': {
          'url': 'https://updater.javp.app/javp-arm64-v8a.apk',
          'sha256': 'arm64-sha',
        },
        'armeabi-v7a': {
          'url': 'https://updater.javp.app/javp-armeabi-v7a.apk',
          'sha256': 'armv7-sha',
        },
        'universal': {
          'url': 'https://updater.javp.app/javp.apk',
          'sha256': 'uni-sha',
        },
      },
    });

    final arm64 = info.resolveApk(
      preferredAbis: const ['arm64-v8a', 'universal'],
    );
    expect(arm64.url, endsWith('javp-arm64-v8a.apk'));
    expect(arm64.sha256, 'arm64-sha');

    final armv7 = info.resolveApk(preferredAbis: const ['armeabi-v7a']);
    expect(armv7.url, endsWith('javp-armeabi-v7a.apk'));

    final missing = info.resolveApk(preferredAbis: const ['x86_64']);
    expect(missing.url, endsWith('javp.apk'));
    expect(missing.sha256, 'uni-sha');

    final legacyOnly = AppUpdateInfo.fromJson({
      'versionName': '0.1.0',
      'versionCode': 1,
      'apkUrl': 'https://updater.javp.app/javp.apk',
      'apkSha256': 'only',
    });
    final fallback = legacyOnly.resolveApk(preferredAbis: const ['arm64-v8a']);
    expect(fallback.url, endsWith('javp.apk'));
    expect(fallback.sha256, 'only');
  });

  test('parses optional Windows packages and resolves preferred key', () {
    final info = AppUpdateInfo.fromJson({
      'versionName': '0.4.0',
      'versionCode': 40,
      'apkUrl': 'https://updater.javp.app/javp.apk',
      'packages': {
        'windows-x64': {
          'url': 'https://updater.javp.app/javp-windows-x64.zip',
          'sha256': 'win-sha',
          'kind': 'zip',
        },
      },
    });

    final pkg = info.resolvePackage(
      preferredKeys: const ['windows-arm64', 'windows-x64', 'windows'],
    );
    expect(pkg, isNotNull);
    expect(pkg!.url, endsWith('javp-windows-x64.zip'));
    expect(pkg.sha256, 'win-sha');
    expect(pkg.kind, 'zip');
  });

  test(
    'parses optional macOS packages and prefers Intel over Apple Silicon',
    () {
      final info = AppUpdateInfo.fromJson({
        'versionName': '0.4.2',
        'versionCode': 56,
        'packages': {
          'macos-arm64': {
            'url': 'https://updater.javp.app/javp-macos-arm64.zip',
            'sha256': 'arm-sha',
            'kind': 'zip',
          },
          'macos-x64': {
            'url': 'https://updater.javp.app/javp-macos-x64.zip',
            'sha256': 'intel-sha',
            'kind': 'zip',
          },
        },
      });

      final intel = info.resolvePackage(
        preferredKeys: const ['macos-x64', 'macos'],
      );
      expect(intel, isNotNull);
      expect(intel!.url, endsWith('javp-macos-x64.zip'));
      expect(intel.sha256, 'intel-sha');

      final arm = info.resolvePackage(
        preferredKeys: const ['macos-arm64', 'macos'],
      );
      expect(arm!.url, endsWith('javp-macos-arm64.zip'));
    },
  );

  test('allows Windows-only manifest without apkUrl', () {
    final info = AppUpdateInfo.fromJson({
      'versionName': '0.4.1',
      'versionCode': 41,
      'packages': {
        'windows-x64': {'url': 'https://updater.javp.app/javp-windows-x64.zip'},
      },
    });
    expect(info.apkUrl, isEmpty);
    expect(
      info.resolvePackage(preferredKeys: const ['windows-x64'])?.url,
      endsWith('javp-windows-x64.zip'),
    );
  });

  test('changelogFor slices releases newer than the installed build', () {
    final info = AppUpdateInfo.fromJson({
      'versionName': '0.4.2-dev',
      'versionCode': 62,
      'apkUrl': 'https://updater.javp.app/dev/javp.apk',
      'changelog': '## 0.4.2-dev+62\n\n- Blob includes older cuts too',
      'releases': [
        {
          'versionName': '0.4.2-dev',
          'versionCode': 62,
          'title': '0.4.2-dev+62 (2026-08-13)',
          'notes': '### Fixes\n- New thing',
        },
        {
          'versionName': '0.4.2-dev',
          'versionCode': 50,
          'title': '0.4.2-dev+50 (2026-08-12)',
          'notes': '### Fixes\n- Already installed',
        },
        {
          'versionName': '0.4.1-dev',
          'versionCode': 40,
          'title': '0.4.1-dev+40 (2026-08-11)',
          'notes': '### Features\n- Ancient',
        },
      ],
    });

    expect(info.releases, hasLength(3));
    expect(info.toJson()['releases'], hasLength(3));

    final since50 = info.changelogFor(
      currentVersionCode: 50,
      currentVersionName: '0.4.2-dev',
    );
    expect(since50, contains('New thing'));
    expect(since50, contains('0.4.2-dev+62'));
    expect(since50, isNot(contains('Already installed')));
    expect(since50, isNot(contains('Ancient')));

    final encodedArm64 = info.changelogFor(currentVersionCode: 2050);
    expect(encodedArm64, contains('New thing'));
    expect(encodedArm64, isNot(contains('Already installed')));

    final skipper = info.changelogFor(
      currentVersionCode: 40,
      currentVersionName: '0.4.1-dev',
    );
    expect(skipper, contains('New thing'));
    expect(skipper, contains('Already installed'));
    expect(skipper, isNot(contains('Ancient')));
  });

  test('changelogFor falls back to blob without releases', () {
    final info = AppUpdateInfo.fromJson({
      'versionName': '0.4.2-dev',
      'versionCode': 62,
      'apkUrl': 'https://updater.javp.app/dev/javp.apk',
      'changelog': 'Legacy notes only',
    });
    expect(info.changelogFor(currentVersionCode: 50), 'Legacy notes only');
  });

  test('changelogFor includes heading-only marketing bumps without +N', () {
    final info = AppUpdateInfo.fromJson({
      'versionName': '0.4.2',
      'versionCode': 56,
      'apkUrl': 'https://updater.javp.app/javp.apk',
      'changelog': 'unused',
      'releases': [
        {
          'versionName': '0.4.2',
          'versionCode': 56,
          'title': '0.4.2+56',
          'notes': '- Latest stable',
        },
        {
          'versionName': '0.3.2',
          'title': '0.3.2 (2026-08-11)',
          'notes': '- Ancient stable without build',
        },
      ],
    });
    final from041 = info.changelogFor(
      currentVersionCode: 45,
      currentVersionName: '0.4.1',
    );
    expect(from041, contains('Latest stable'));
    expect(from041, isNot(contains('Ancient stable')));

    final from030 = info.changelogFor(
      currentVersionCode: 20,
      currentVersionName: '0.3.0',
    );
    expect(from030, contains('Latest stable'));
    expect(from030, contains('Ancient stable'));
  });
}
