# Build a Microsoft Store MSIX (Windows host).
# Requires Flutter Windows desktop + Visual Studio C++ workload.
#
# Usage (from repo root):
#   powershell -File tool/build_msix.ps1
#   powershell -File tool/build_msix.ps1 -LocalTest   # non-Store signed test package
#
# Identity is in pubspec.yaml msix_config (Store ID 9P4PMM405RZH).
# CI maps version X.Y.Z+N → msix_version X.Y.Z.0 (Store requires revision=0).

param(
    [switch]$LocalTest
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

Write-Host "flutter pub get..."
flutter pub get

Write-Host "flutter build windows --release (JAVP_DISTRIBUTION=msstore)..."
flutter build windows --release --dart-define=JAVP_DISTRIBUTION=msstore

if ($LocalTest) {
    Write-Host "dart run msix:create (local test package)..."
    dart run msix:create
} else {
    Write-Host "dart run msix:create --store..."
    dart run msix:create --store
}

Write-Host "Done. Upload the Store package from build/windows/ when Partner Center is ready."
