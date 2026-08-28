import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:javp/models/app_update_info.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum UpdateInstallTarget {
  androidApk,
  windowsZip,
  linuxZip,
  macosZip,
  unsupported,
}

String get platformLabel => Platform.operatingSystem;

UpdateInstallTarget detectInstallTarget() {
  if (kIsWeb) return UpdateInstallTarget.unsupported;
  if (Platform.isAndroid) return UpdateInstallTarget.androidApk;
  if (Platform.isWindows) return UpdateInstallTarget.windowsZip;
  if (Platform.isLinux) return UpdateInstallTarget.linuxZip;
  if (Platform.isMacOS) return UpdateInstallTarget.macosZip;
  return UpdateInstallTarget.unsupported;
}

List<String> detectPreferredPackages() {
  if (kIsWeb) return const [];
  if (Platform.isWindows) {
    switch (Abi.current()) {
      case Abi.windowsArm64:
        return const ['windows-arm64', 'windows-x64', 'windows'];
      default:
        return const ['windows-x64', 'windows'];
    }
  }
  if (Platform.isLinux) {
    switch (Abi.current()) {
      case Abi.linuxArm64:
        return const ['linux-arm64', 'linux'];
      default:
        return const ['linux-x64', 'linux'];
    }
  }
  if (Platform.isMacOS) {
    switch (Abi.current()) {
      case Abi.macosArm64:
        return const ['macos-arm64', 'macos'];
      case Abi.macosX64:
        return const ['macos-x64', 'macos'];
      default:
        return const ['macos-arm64', 'macos'];
    }
  }
  return const [];
}

List<String> detectPreferredAbis() {
  switch (Abi.current()) {
    case Abi.androidArm64:
      return const ['arm64-v8a', 'universal'];
    case Abi.androidArm:
      return const ['armeabi-v7a', 'universal'];
    case Abi.androidX64:
      return const ['x86_64', 'universal'];
    case Abi.androidIA32:
      return const ['x86', 'universal'];
    default:
      return const ['arm64-v8a', 'universal'];
  }
}

Exception httpException(String message, Uri uri) => HttpException(message, uri: uri);

String getFilePath(dynamic file) => (file as File).path;

Future<File?> getCachedFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  return file;
}

Future<bool> checkAppliedStamp({
  required String stampPath,
  required String expectedSha256,
}) async {
  final effectiveStampPath = stampPath.isEmpty 
      ? p.join(File(Platform.resolvedExecutable).parent.path, '.javp-applied-sha256')
      : stampPath;
  final stamp = File(effectiveStampPath);
  if (!await stamp.exists()) return false;
  final applied = (await stamp.readAsString()).trim().toLowerCase();
  return applied == expectedSha256;
}

Future<File> downloadUpdate({
  required AppUpdateInfo update,
  required UpdateInstallTarget installTarget,
  required List<String> preferredAbis,
  required List<String> preferredPackages,
  required String userAgent,
  required http.Client client,
  void Function(int received, int? total)? onProgress,
}) async {
  switch (installTarget) {
    case UpdateInstallTarget.androidApk:
      final apk = update.resolveApk(preferredAbis: preferredAbis);
      return _downloadToFile(
        url: apk.url,
        sha256hex: apk.sha256,
        fileName: 'javp-${update.versionCode}.apk',
        userAgent: userAgent,
        client: client,
        onProgress: onProgress,
        label: 'APK',
      );
    case UpdateInstallTarget.windowsZip:
    case UpdateInstallTarget.linuxZip:
    case UpdateInstallTarget.macosZip:
      final pkg = update.resolvePackage(preferredKeys: preferredPackages);
      if (pkg == null) {
        throw StateError('No package in update manifest for this platform');
      }
      final ext = _extensionForTarget(installTarget, pkg.url);
      return _downloadToFile(
        url: pkg.url,
        sha256hex: pkg.sha256,
        fileName: 'javp-${update.versionCode}.$ext',
        userAgent: userAgent,
        client: client,
        onProgress: onProgress,
        label: '${installTarget.name} package',
      );
    case UpdateInstallTarget.unsupported:
      throw StateError('In-app updates are not supported here');
  }
}

String _extensionForTarget(UpdateInstallTarget target, String url) {
  final lower = url.toLowerCase();
  if (target == UpdateInstallTarget.windowsZip && lower.endsWith('.exe')) {
    return 'exe';
  }
  if (target == UpdateInstallTarget.linuxZip && lower.endsWith('.appimage')) {
    return 'AppImage';
  }
  if (target == UpdateInstallTarget.macosZip && lower.endsWith('.dmg')) {
    return 'dmg';
  }
  return 'zip';
}

Future<File> _downloadToFile({
  required String url,
  required String fileName,
  String? sha256hex,
  required String userAgent,
  required http.Client client,
  void Function(int received, int? total)? onProgress,
  String label = 'Update',
}) async {
  final request = http.Request('GET', Uri.parse(url));
  request.headers['User-Agent'] = userAgent;
  final response = await client.send(request);
  if (response.statusCode >= 400) {
    throw HttpException(
      '$label download failed (${response.statusCode})',
      uri: Uri.parse(url),
    );
  }

  final total = response.contentLength;
  final dir = await _updateDownloadDir();
  final file = File(p.join(dir.path, fileName));
  final sink = file.openWrite();
  var received = 0;
  try {
    await for (final chunk in response.stream) {
      received += chunk.length;
      sink.add(chunk);
      onProgress?.call(received, total);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }

  final expected = sha256hex?.trim().toLowerCase();
  if (expected != null && expected.isNotEmpty) {
    final digest = await sha256.bind(file.openRead()).first;
    final actual = digest.toString();
    if (actual != expected) {
      await file.delete().catchError((_) => file);
      throw StateError(
        '$label checksum mismatch (expected $expected, got $actual)',
      );
    }
  }

  return file;
}

Future<Directory> _updateDownloadDir() async {
  Directory root;
  try {
    root = await getApplicationCacheDirectory();
  } catch (_) {
    root = await getTemporaryDirectory();
  }
  final dir = Directory(p.join(root.path, 'javp-updates'));
  await dir.create(recursive: true);
  return dir;
}

Future<void> installUpdate({
  required File downloaded,
  required UpdateInstallTarget installTarget,
}) async {
  switch (installTarget) {
    case UpdateInstallTarget.androidApk:
      final result = await OpenFilex.open(
        downloaded.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw StateError(result.message);
      }
    case UpdateInstallTarget.windowsZip:
      await _installWindowsPackage(downloaded);
    case UpdateInstallTarget.linuxZip:
      await _installLinuxPackage(downloaded);
    case UpdateInstallTarget.macosZip:
      await _installMacosPackage(downloaded);
    case UpdateInstallTarget.unsupported:
      throw StateError('In-app updates are not supported here');
  }
}

Future<void> _installWindowsPackage(File downloaded) async {
  if (downloaded.path.toLowerCase().endsWith('.exe')) {
    final result = await OpenFilex.open(downloaded.path);
    if (result.type != ResultType.done) {
      throw StateError(result.message);
    }
    return;
  }
  final digest = await sha256.bind(downloaded.openRead()).first;
  await _installDesktopZip(
    downloaded,
    binaryName: 'javp.exe',
    scriptExtension: 'ps1',
    writeScript: ({
      required int pid,
      required String payloadDir,
      required String installDir,
      required String exePath,
      required String stagingDir,
      required String logPath,
    }) =>
        _buildWindowsApplyScript(
          pid: pid,
          payloadDir: payloadDir,
          installDir: installDir,
          exePath: exePath,
          stagingDir: stagingDir,
          logPath: logPath,
          appliedSha256: digest.toString(),
        ),
    launch: _launchWindowsUpdateHelper,
  );
}

Future<void> _installLinuxPackage(File downloaded) async {
  final lower = downloaded.path.toLowerCase();
  if (lower.endsWith('.appimage')) {
    final result = await OpenFilex.open(downloaded.path);
    if (result.type != ResultType.done) {
      throw StateError(result.message);
    }
    return;
  }
  await _installDesktopZip(
    downloaded,
    binaryName: 'javp',
    scriptExtension: 'sh',
    writeScript: _buildLinuxApplyScript,
    launch: (script) async {
      await Process.run('chmod', ['+x', script.path]);
      await Process.start('/bin/bash', [
        script.path,
      ], mode: ProcessStartMode.detached);
    },
  );
}

Future<void> _installMacosPackage(File downloaded) async {
  final exe = File(Platform.resolvedExecutable);
  final appBundle = _resolveMacAppBundle(exe);
  if (appBundle == null) {
    throw StateError(
      'Could not find a .app bundle for ${exe.path}. '
      'Extract javp.app from the zip and run it from there.',
    );
  }
  await _assertInstallDirWritable(appBundle.parent);

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final tempRoot = await getTemporaryDirectory();
  final staging = Directory(p.join(tempRoot.path, 'javp-update-$stamp'));
  await staging.create(recursive: true);

  final payloadApp = await _unpackMacosAppZip(downloaded, staging);
  final script = File(p.join(tempRoot.path, 'javp-update-$stamp.sh'));
  await script.writeAsString(
    _buildMacosApplyScript(
      pid: pid,
      payloadDir: payloadApp.path,
      installDir: appBundle.path,
      exePath: exe.path,
      stagingDir: staging.path,
      logPath: p.join(tempRoot.path, 'javp-update-$stamp.log'),
    ),
  );
  await Process.run('chmod', ['+x', script.path]);
  await Process.start('/bin/bash', [
    script.path,
  ], mode: ProcessStartMode.detached);
}

Directory? _resolveMacAppBundle(File exe) {
  var dir = exe.parent;
  for (var i = 0; i < 8; i++) {
    if (dir.path.toLowerCase().endsWith('.app')) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Future<void> _installDesktopZip(
  File downloaded, {
  required String binaryName,
  required String scriptExtension,
  required String Function({
    required int pid,
    required String payloadDir,
    required String installDir,
    required String exePath,
    required String stagingDir,
    required String logPath,
  })
  writeScript,
  required Future<void> Function(File script) launch,
}) async {
  final exe = File(Platform.resolvedExecutable);
  final installDir = exe.parent;
  await _assertInstallDirWritable(installDir);

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final tempRoot = await getTemporaryDirectory();
  final staging = Directory(p.join(tempRoot.path, 'javp-update-$stamp'));
  await staging.create(recursive: true);

  final payload = await _unpackDesktopZip(
    downloaded,
    staging,
    binaryName: binaryName,
  );

  final script = File(
    p.join(tempRoot.path, 'javp-update-$stamp.$scriptExtension'),
  );
  await script.writeAsString(
    writeScript(
      pid: pid,
      payloadDir: payload.path,
      installDir: installDir.path,
      exePath: exe.path,
      stagingDir: staging.path,
      logPath: p.join(tempRoot.path, 'javp-update-$stamp.log'),
    ),
  );
  await launch(script);
}

Future<void> _assertInstallDirWritable(Directory installDir) async {
  final probe = File(p.join(installDir.path, '.javp-update-probe-$pid'));
  try {
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
  } on FileSystemException {
    throw StateError(
      'JAVP cannot write to its own folder (${installDir.path}). '
      'Download the new zip from updater.javp.app and extract it there, '
      'or move JAVP somewhere your user can write.',
    );
  }
}

Future<Directory> _unpackDesktopZip(
  File zip,
  Directory target, {
  required String binaryName,
}) async {
  final path = await Isolate.run(
    () => _unpackDesktopZipSync(zip.path, target.path, binaryName),
  );
  return Directory(path);
}

Future<Directory> _unpackMacosAppZip(File zip, Directory target) async {
  final path = await Isolate.run(
    () => _unpackMacosAppZipSync(zip.path, target.path),
  );
  return Directory(path);
}

Future<void> _launchWindowsUpdateHelper(File script) async {
  final cmd = File(
    p.join(
      script.parent.path,
      '${p.basenameWithoutExtension(script.path)}.cmd',
    ),
  );
  await cmd.writeAsString(_windowsHelperCmdScript(script.path));
  await Process.start(
    'cmd.exe',
    ['/d', '/c', 'call', cmd.path],
    workingDirectory: script.parent.path,
    mode: ProcessStartMode.detached,
  );
  await Future<void>.delayed(const Duration(milliseconds: 600));
}

String _windowsHelperCmdScript(String scriptPath) {
  final escaped = scriptPath.replaceAll('"', '');
  return '''
@echo off
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$escaped"
''';
}

String _buildWindowsApplyScript({
  required int pid,
  required String payloadDir,
  required String installDir,
  required String exePath,
  required String stagingDir,
  required String logPath,
  int copyAttempts = 12,
  String appliedSha256 = '',
}) {
  String q(String value) => value.replaceAll("'", "''");
  final stampSha = appliedSha256.trim().toLowerCase();
  final stampBlock = stampSha.isEmpty
      ? ''
      : '''
  Set-Content -LiteralPath (Join-Path \$dst '.javp-applied-sha256') -Value '${q(stampSha)}' -NoNewline
  Write-Log 'applied stamp written'
''';
  return '''
\$ErrorActionPreference = 'Stop'
\$log = '${q(logPath)}'
function Write-Log(\$message) {
  Add-Content -LiteralPath \$log -Value "\$(Get-Date -Format o) \$message"
}
Write-Log 'helper started (waiting for JAVP pid $pid)'
try {
  try {
    Wait-Process -Id $pid -Timeout 60 -ErrorAction Stop
    Write-Log 'JAVP exited'
  } catch {
    Write-Log "wait skipped: \$_"
    try {
      Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
      Wait-Process -Id $pid -Timeout 15 -ErrorAction SilentlyContinue
      Write-Log 'forced JAVP to exit'
    } catch {}
  }
  \$src = '${q(payloadDir)}'
  \$dst = '${q(installDir)}'
  \$exe = '${q(exePath)}'
  for (\$i = 1; \$i -le $copyAttempts; \$i++) {
    try {
      Copy-Item -Path (Join-Path \$src '*') -Destination \$dst -Recurse -Force
      Write-Log 'files replaced'
      break
    } catch {
      Write-Log "copy attempt \$i failed: \$_"
      if (\$i -eq $copyAttempts) { throw }
      Start-Sleep -Milliseconds 750
    }
  }
  if (-not (Test-Path -LiteralPath \$exe)) {
    throw "updated exe missing: \$exe"
  }
$stampBlock  Start-Process -FilePath \$exe -WorkingDirectory \$dst
  Write-Log 'relaunched'
  Remove-Item -LiteralPath '${q(stagingDir)}' -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  Write-Log "update failed: \$_"
  exit 1
}
''';
}

String _buildLinuxApplyScript({
  required int pid,
  required String payloadDir,
  required String installDir,
  required String exePath,
  required String stagingDir,
  required String logPath,
  int copyAttempts = 12,
}) {
  String q(String value) => value.replaceAll("'", "'\"'\"'");
  return '''
#!/usr/bin/env bash
set -euo pipefail
log='${q(logPath)}'
write_log() { printf '%s %s\\n' "\$(date -Iseconds 2>/dev/null || date)" "\$1" >> "\$log"; }
write_log "waiting for JAVP (pid $pid) to exit"
for _ in \$(seq 1 60); do
  if ! kill -0 $pid 2>/dev/null; then
    break
  fi
  sleep 1
done
src='${q(payloadDir)}'
dst='${q(installDir)}'
for i in \$(seq 1 $copyAttempts); do
  if cp -a "\$src"/. "\$dst"/; then
    write_log 'files replaced'
    break
  fi
  write_log "copy attempt \$i failed"
  if [[ "\$i" -eq $copyAttempts ]]; then
    write_log 'update failed: copy retries exhausted'
    exit 1
  fi
  sleep 0.75
done
chmod +x '${q(exePath)}' 2>/dev/null || true
nohup '${q(exePath)}' >/dev/null 2>&1 &
write_log 'relaunched'
rm -rf '${q(stagingDir)}' || true
''';
}

String _buildMacosApplyScript({
  required int pid,
  required String payloadDir,
  required String installDir,
  required String exePath,
  required String stagingDir,
  required String logPath,
  int copyAttempts = 12,
}) {
  String q(String value) => value.replaceAll("'", "'\"'\"'");
  return '''
#!/usr/bin/env bash
set -euo pipefail
log='${q(logPath)}'
write_log() { printf '%s %s\\n' "\$(date -Iseconds 2>/dev/null || date)" "\$1" >> "\$log"; }
write_log "waiting for JAVP (pid $pid) to exit"
for _ in \$(seq 1 60); do
  if ! kill -0 $pid 2>/dev/null; then
    break
  fi
  sleep 1
done
src='${q(payloadDir)}'
dst='${q(installDir)}'
for i in \$(seq 1 $copyAttempts); do
  if rm -rf "\$dst" && cp -a "\$src" "\$dst"; then
    write_log 'app bundle replaced'
    break
  fi
  write_log "replace attempt \$i failed"
  if [[ "\$i" -eq $copyAttempts ]]; then
    write_log 'update failed: replace retries exhausted'
    exit 1
  fi
  sleep 0.75
done
xattr -cr "\$dst" 2>/dev/null || true
chmod +x "\$dst/Contents/MacOS/javp" 2>/dev/null || true
open "\$dst"
write_log 'relaunched'
rm -rf '${q(stagingDir)}' || true
''';
}

String _unpackDesktopZipSync(
  String zipPath,
  String targetPath,
  String binaryName,
) {
  final target = Directory(targetPath);
  final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
  final rootPrefix = _detectZipRoot(archive);
  final binaryLower = binaryName.toLowerCase();

  for (final entry in archive) {
    var name = entry.name.replaceAll('\\', '/');
    if (name.startsWith('__MACOSX/')) continue;
    if (rootPrefix != null && name.startsWith(rootPrefix)) {
      name = name.substring(rootPrefix.length);
    }
    if (name.isEmpty) continue;
    final outPath = p.normalize(p.join(target.path, name));
    if (!p.isWithin(target.path, outPath)) continue;
    if (entry.isFile) {
      final out = File(outPath);
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(entry.readBytes() ?? const <int>[]);
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }

  if (File(p.join(target.path, binaryName)).existsSync()) return target.path;

  final nested =
      target
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path).toLowerCase() == binaryLower)
          .map((f) => f.parent.path)
          .toList()
        ..sort((a, b) => p.split(a).length.compareTo(p.split(b).length));
  if (nested.isEmpty) {
    throw StateError('Update package did not contain $binaryName');
  }
  return nested.first;
}

String _unpackMacosAppZipSync(String zipPath, String targetPath) {
  final target = Directory(targetPath);
  final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
  final rootPrefix = _detectZipRoot(archive);
  final keepAppRoot =
      rootPrefix != null &&
      rootPrefix.toLowerCase().replaceAll(RegExp(r'/+$'), '').endsWith('.app');

  for (final entry in archive) {
    var name = entry.name.replaceAll('\\', '/');
    if (name.startsWith('__MACOSX/')) continue;
    if (!keepAppRoot && rootPrefix != null && name.startsWith(rootPrefix)) {
      name = name.substring(rootPrefix.length);
    }
    if (name.isEmpty) continue;
    final outPath = p.normalize(p.join(target.path, name));
    if (!p.isWithin(target.path, outPath)) continue;
    if (entry.isFile) {
      final out = File(outPath);
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(entry.readBytes() ?? const <int>[]);
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }

  final apps =
      target
          .listSync(recursive: true)
          .whereType<Directory>()
          .where((d) => d.path.toLowerCase().endsWith('.app'))
          .toList()
        ..sort(
          (a, b) => p.split(a.path).length.compareTo(p.split(b.path).length),
        );
  if (apps.isEmpty) {
    throw StateError('Update package did not contain a .app bundle');
  }
  final app = apps.first;
  final binary = File(p.join(app.path, 'Contents', 'MacOS', 'javp'));
  if (!binary.existsSync()) {
    throw StateError('Update package .app is missing Contents/MacOS/javp');
  }
  return app.path;
}

String? _detectZipRoot(Archive archive) {
  final top = <String>{};
  for (final entry in archive) {
    final name = entry.name.replaceAll('\\', '/');
    if (name.startsWith('__MACOSX/')) continue;
    final parts = name.split('/');
    if (parts.isEmpty || parts.first.isEmpty) continue;
    top.add(parts.first);
  }
  if (top.length != 1) return null;
  final only = top.first;
  final prefix = '$only/';
  final allUnder = archive.every((entry) {
    final name = entry.name.replaceAll('\\', '/');
    return name == only || name == prefix || name.startsWith(prefix);
  });
  return allUnder ? prefix : null;
}
