# Rebuild proxy addon against the LIEF-exported main .so (arm64).
# Does NOT modify liblibtorrent_flutter.so — run export_dynsyms.py first.
$ErrorActionPreference = "Stop"

$Pkg = Resolve-Path (Join-Path $PSScriptRoot "..")
$Sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$NDK = if ($env:ANDROID_NDK_HOME) { $env:ANDROID_NDK_HOME } else { Get-ChildItem (Join-Path $Sdk "ndk") -Directory | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName }
$LLVM = Join-Path $NDK "toolchains\llvm\prebuilt\windows-x86_64"
$ClangXX = Join-Path $LLVM "bin\clang++.exe"
$Nm = Join-Path $LLVM "bin\llvm-nm.exe"
$Work = Join-Path $Pkg "native-build\android-arm64"
$BoostRoot = Join-Path $Work "boost_1_84_0"
$LtSrc = Join-Path $Work "libtorrent-src"
$AbiDir = Join-Path $Pkg "prebuilt\android\arm64-v8a"
$MainSo = Join-Path $AbiDir "liblibtorrent_flutter.so"
$AddonSo = Join-Path $AbiDir "libjavp_lt_proxy.so"
$Target = "aarch64-linux-android24"

# Ensure dynsyms exist
$dyn = & $Nm -D --defined-only $MainSo 2>&1 | Out-String
if ($dyn -notmatch "settings_pack7set_int") {
  Write-Host "Exporting dynsyms via LIEF..." -ForegroundColor Cyan
  python (Join-Path $PSScriptRoot "export_dynsyms.py")
}

Write-Host "Compiling proxy addon..." -ForegroundColor Cyan
$OutTmp = Join-Path $Work "libjavp_lt_proxy.so"
& $ClangXX `
  --target=$Target `
  -shared -fPIC -O2 -std=c++17 `
  -fvisibility=default `
  -DTORRENT_BRIDGE_EXPORTS `
  -DTORRENT_NO_DEPRECATE `
  "-I$LtSrc\include" `
  "-I$BoostRoot" `
  -o $OutTmp `
  (Join-Path $PSScriptRoot "proxy_addon.cpp") `
  "-L$AbiDir" `
  -llibtorrent_flutter `
  -llog `
  -static-libstdc++

if ($LASTEXITCODE -ne 0) { throw "clang++ failed" }
Copy-Item -Force $OutTmp $AddonSo
& $Nm -D --defined-only $AddonSo | Select-String "lt_set_proxy"
Write-Host "OK -> $AddonSo" -ForegroundColor Green
