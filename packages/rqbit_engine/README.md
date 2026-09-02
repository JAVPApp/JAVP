# rqbit_engine

JAVP’s torrent backend: embed [librqbit](https://github.com/ikatson/rqbit)
(Apache-2.0) as a Rust `cdylib`, start its HTTP API on `127.0.0.1`, and drive
magnets / `.torrent` files / HTTP range streams from Dart.

This replaces the GPL-3.0 `libtorrent_flutter` plugin in the app binary.

## Native build

Needs a Rust toolchain (`rustup`) on the host that compiles the Flutter target.
CI (`setup-rust-ci`) and `tool/local_release.sh` require cargo so Linux, macOS,
Windows, and Android main builds compile this crate on each platform.

| Platform | How the `.so` / `.dll` / `.dylib` is produced |
| --- | --- |
| Linux / Windows | CMake runs `cargo build --release` and Flutter copies the artifact next to the binary |
| macOS | CocoaPods runs `cargo build --release`, rewrites `LC_ID_DYLIB` to `@rpath/librqbit_engine.dylib`, and vendors the dylib (required so shipped `.app` zips do not embed `/Users/…` load paths) |
| Android | Gradle uses `prebuilt/android/<abi>/librqbit_engine.so` when present (CI Play/sideload builds skip cargo-ndk). Otherwise runs `cargo ndk` when the NDK + `cargo-ndk` are on PATH. |

```bash
# Desktop (from this package)
cargo build --release --manifest-path rust/Cargo.toml

# Android ABIs (optional; ship host)
cargo install cargo-ndk
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o prebuilt/android build --release --manifest-path rust/Cargo.toml
```

Set `RQBIT_ENGINE_SKIP_CARGO=1` to skip the cargo step and require a prebuilt.
CI sets this automatically when all required ABIs are vendored under `prebuilt/android/`
(see `.github/actions/setup-rqbit-android-ci`).

Rebuild Android prebuilts after `rust/` changes:

```bash
./tool/build_rqbit_android.sh
```

## Dart API

`RqbitEngine.start(savePath: …)` loads the native library, binds a random
loopback port, and returns an `RqbitClient` for `POST /torrents` and
`GET /torrents/{id}/stream/{file}`.
