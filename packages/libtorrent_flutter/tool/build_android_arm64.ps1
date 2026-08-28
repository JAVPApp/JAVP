# Build patched liblibtorrent_flutter.so for Android arm64-v8a (Windows host + NDK).
$ErrorActionPreference = "Stop"

$Pkg = Resolve-Path (Join-Path $PSScriptRoot "..")
$Sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$NDK = if ($env:ANDROID_NDK_HOME) { $env:ANDROID_NDK_HOME } else { Get-ChildItem (Join-Path $Sdk "ndk") -Directory | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName }
$CMakeDir = if ($env:ANDROID_CMAKE_DIR) { $env:ANDROID_CMAKE_DIR } else { Get-ChildItem (Join-Path $Sdk "cmake") -Directory | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName }
$CMake = Join-Path $CMakeDir "bin\cmake.exe"
$Ninja = Join-Path $CMakeDir "bin\ninja.exe"
$LLVM = Join-Path $NDK "toolchains\llvm\prebuilt\windows-x86_64"
$ClangXX = Join-Path $LLVM "bin\clang++.exe"
$Work = Join-Path $Pkg "native-build\android-arm64"
$OutSo = Join-Path $Pkg "prebuilt\android\arm64-v8a\liblibtorrent_flutter.so"
$Api = 24
$Abi = "arm64-v8a"
$Target = "aarch64-linux-android$Api"
$OsslTarget = "android-arm64"

$env:PATH = "C:\Strawberry\perl\bin;C:\Strawberry\c\bin;$LLVM\bin;$env:PATH"
$env:ANDROID_NDK_HOME = $NDK
$env:ANDROID_NDK_ROOT = $NDK

New-Item -ItemType Directory -Force -Path $Work | Out-Null
Set-Location $Work

function Step($msg) {
  Write-Host ""
  Write-Host "==== $msg ====" -ForegroundColor Cyan
}

# ── Boost headers ────────────────────────────────────────────────────────────
$BoostRoot = Join-Path $Work "boost_1_84_0"
if (-not (Test-Path (Join-Path $BoostRoot "boost\version.hpp"))) {
  Step "Downloading Boost 1.84 headers"
  $boostTar = Join-Path $Work "boost.tar.gz"
  if (-not (Test-Path $boostTar)) {
    Invoke-WebRequest -Uri "https://archives.boost.io/release/1.84.0/source/boost_1_84_0.tar.gz" -OutFile $boostTar
  }
  # tar.exe on Windows 10+
  tar -xf $boostTar -C $Work
}

# ── OpenSSL ──────────────────────────────────────────────────────────────────
$OsslRoot = Join-Path $Work "openssl-install"
$OsslLib = Join-Path $OsslRoot "lib\libcrypto.a"
if (-not (Test-Path $OsslLib)) {
  if (Test-Path (Join-Path $OsslRoot "lib64\libcrypto.a")) {
    $OsslLib = Join-Path $OsslRoot "lib64\libcrypto.a"
  }
}
if (-not (Test-Path $OsslLib)) {
  Step "Building OpenSSL for $Abi"
  $osslSrc = Join-Path $Work "openssl-src"
  if (-not (Test-Path (Join-Path $osslSrc "Configure"))) {
    git clone --depth 1 --branch openssl-3.2.1 https://github.com/openssl/openssl.git $osslSrc
  }
  Set-Location $osslSrc
  $env:PATH = "$LLVM\bin;$env:PATH"
  perl Configure $OsslTarget `
    --prefix=$OsslRoot `
    --openssldir=$OsslRoot\ssl `
    no-shared no-tests no-ui-console no-apps `
    -D__ANDROID_API__=$Api
  # OpenSSL uses make; use NDK llvm-make via mingw from strawberry or nmake alternative.
  # Prefer "make" from Strawberry's c\bin (gmake).
  & "C:\Strawberry\c\bin\gmake.exe" -j8
  & "C:\Strawberry\c\bin\gmake.exe" install_sw
  Set-Location $Work
}

$OsslLibDir = Join-Path $OsslRoot "lib"
if (-not (Test-Path (Join-Path $OsslLibDir "libcrypto.a"))) {
  $OsslLibDir = Join-Path $OsslRoot "lib64"
}
if (-not (Test-Path (Join-Path $OsslLibDir "libcrypto.a"))) {
  throw "OpenSSL libs not found under $OsslRoot"
}

# ── libtorrent ───────────────────────────────────────────────────────────────
$LtSrc = Join-Path $Work "libtorrent-src"
$LtBuild = Join-Path $LtSrc "build"
$LtLib = $null
if (Test-Path $LtBuild) {
  $LtLib = Get-ChildItem -Path $LtBuild -Recurse -Filter "libtorrent-rasterbar.a" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $LtLib) {
  Step "Cloning / building libtorrent 2.0.11"
  if (-not (Test-Path (Join-Path $LtSrc "CMakeLists.txt"))) {
    git clone --depth 1 --recurse-submodules --branch v2.0.11 https://github.com/arvidn/libtorrent.git $LtSrc
  }
  New-Item -ItemType Directory -Force -Path $LtBuild | Out-Null
  Set-Location $LtBuild
  $toolchain = Join-Path $NDK "build\cmake\android.toolchain.cmake"
  & $CMake $LtSrc `
    -G Ninja `
    -DCMAKE_TOOLCHAIN_FILE="$toolchain" `
    -DANDROID_ABI=$Abi `
    -DANDROID_PLATFORM=android-$Api `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_CXX_STANDARD=17 `
    -DBuildShared=OFF `
    -Ddeprecated-functions=OFF `
    -Dencryption=ON `
    -Dboost-python-module=OFF `
    -Dpython-bindings=OFF `
    -DCMAKE_MAKE_PROGRAM="$Ninja" `
    -DBOOST_ROOT="$BoostRoot" `
    -DBoost_INCLUDE_DIR="$BoostRoot" `
    -DOPENSSL_ROOT_DIR="$OsslRoot" `
    -DOPENSSL_INCLUDE_DIR="$OsslRoot\include" `
    -DOPENSSL_CRYPTO_LIBRARY="$OsslLibDir\libcrypto.a" `
    -DOPENSSL_SSL_LIBRARY="$OsslLibDir\libssl.a" `
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
  & $Ninja -j8
  $LtLib = Get-ChildItem -Path $LtBuild -Recurse -Filter "libtorrent-rasterbar.a" |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $LtLib) { throw "libtorrent-rasterbar.a not found" }
  Set-Location $Work
}

Step "Building torrent_bridge ($Abi)"
$BridgeDir = Join-Path $Work "build-bridge"
New-Item -ItemType Directory -Force -Path $BridgeDir | Out-Null
$BridgeCpp = Join-Path $Pkg "src\torrent_bridge.cpp"
$OutPath = Join-Path $BridgeDir "liblibtorrent_flutter.so"

$LtIncludeBuild = Join-Path $LtBuild "include"
& $ClangXX `
  --target=$Target `
  -shared -fPIC -O3 -std=c++17 `
  -DTORRENT_BRIDGE_EXPORTS `
  -DTORRENT_NO_DEPRECATE `
  -DBOOST_NO_IOSTREAM `
  "-I$LtSrc\include" `
  "-I$LtIncludeBuild" `
  "-I$BoostRoot" `
  "-I$OsslRoot\include" `
  -o $OutPath `
  $BridgeCpp `
  "-Wl,--whole-archive" $LtLib "-Wl,--no-whole-archive" `
  "$OsslLibDir\libssl.a" "$OsslLibDir\libcrypto.a" `
  -llog `
  -static-libstdc++

if (-not (Test-Path $OutPath)) { throw "Bridge .so was not produced" }

New-Item -ItemType Directory -Force -Path (Split-Path $OutSo) | Out-Null
Copy-Item -Force $OutPath $OutSo
Step "Installed -> $OutSo"
(Get-Item $OutSo).Length
# Verify symbol
& (Join-Path $LLVM "bin\llvm-nm.exe") -D --defined-only $OutSo | Select-String "lt_set_proxy"
Write-Host "DONE" -ForegroundColor Green
