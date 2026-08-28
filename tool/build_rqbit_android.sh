#!/usr/bin/env bash
# Rebuild rqbit_engine Android JNI prebuilts (all Play / sideload ABIs).
# Requires rustup, cargo-ndk, and ANDROID_NDK_HOME (or NDK from Android Studio).
set -euo pipefail
cd "$(dirname "$0")/../packages/rqbit_engine"
cargo install cargo-ndk --locked 2>/dev/null || true
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o prebuilt/android build --release --manifest-path rust/Cargo.toml
echo "Wrote prebuilt/android/*/librqbit_engine.so — commit when rust/ changes."
