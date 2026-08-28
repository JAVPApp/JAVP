import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/platform/portable_mode_io.dart';
import 'package:path/path.dart' as p;

void main() {
  setUp(debugResetPortableMode);
  tearDown(debugResetPortableMode);

  group('looksLikeWindowsInstallDir', () {
    test('matches Inno per-user install folder', () {
      expect(
        looksLikeWindowsInstallDir(
          r'C:\Users\Ada\AppData\Local\Programs\JAVP',
          {'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local'},
        ),
        isTrue,
      );
    });

    test('is case-insensitive on Windows paths', () {
      expect(
        looksLikeWindowsInstallDir(
          r'c:\users\ada\appdata\local\programs\javp',
          {'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local'},
        ),
        isTrue,
      );
    });

    test('does not match an extracted zip on the desktop', () {
      expect(
        looksLikeWindowsInstallDir(
          r'C:\Users\Ada\Desktop\javp-windows-x64',
          {'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local'},
        ),
        isFalse,
      );
    });

    test('treats WindowsApps as installed', () {
      expect(
        looksLikeWindowsInstallDir(
          r'C:\Program Files\WindowsApps\JAVP_1.0.0.0_x64\app',
          const {},
        ),
        isTrue,
      );
    });
  });

  group('resolvePortableMode', () {
    test('install dir wins over a portable marker', () {
      expect(
        resolvePortableMode(
          env: {'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local'},
          exeDirectory: r'C:\Users\Ada\AppData\Local\Programs\JAVP',
          fileExists: (_) => true,
        ),
        isFalse,
      );
    });

    test('marker next to a zip extract enables portable mode', () {
      expect(
        resolvePortableMode(
          env: {'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local'},
          exeDirectory: r'D:\usb\javp',
          fileExists: (path) => p.basename(path) == 'portable',
        ),
        isTrue,
      );
    });

    test('JAVP_PORTABLE=1 forces portable outside the install dir', () {
      expect(
        resolvePortableMode(
          env: {
            'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local',
            'JAVP_PORTABLE': '1',
          },
          exeDirectory: r'C:\src\javp\build\windows\x64\runner\Debug',
          fileExists: (_) => false,
        ),
        isTrue,
      );
    });

    test('JAVP_PORTABLE=0 disables a zip marker', () {
      expect(
        resolvePortableMode(
          env: {
            'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local',
            'JAVP_PORTABLE': '0',
          },
          exeDirectory: r'D:\usb\javp',
          fileExists: (_) => true,
        ),
        isFalse,
      );
    });

    test('no marker and no env stays on AppData', () {
      expect(
        resolvePortableMode(
          env: {'LOCALAPPDATA': r'C:\Users\Ada\AppData\Local'},
          exeDirectory: r'C:\src\javp\build\windows\x64\runner\Debug',
          fileExists: (_) => false,
        ),
        isFalse,
      );
    });
  });

  test('PortablePathProvider writes under data/', () async {
    final root = await Directory.systemTemp.createTemp('javp_portable_');
    addTearDown(() => root.delete(recursive: true));
    final provider = PortablePathProvider(p.join(root.path, 'data'));
    final support = await provider.getApplicationSupportPath();
    final documents = await provider.getApplicationDocumentsPath();
    expect(support, endsWith(p.join('data', 'support')));
    expect(documents, endsWith(p.join('data', 'documents')));
    expect(Directory(support!).existsSync(), isTrue);
    expect(Directory(documents!).existsSync(), isTrue);
  });
}
