# media_kit_libs_android_video (JAVP full codecs)

Vendored override of [media_kit_libs_android_video](https://pub.dev/packages/media_kit_libs_android_video) that downloads media-kit’s **full** libmpv Android jars instead of the size-optimized **default** flavor.

- Upstream default: common codecs only (smaller APK)
- This override: `--enable-decoders/demuxers/parsers` + libdav1d (broader format support, larger native libs)

Jars come from [libmpv-android-video-build v1.1.11](https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.11) (`full-*.jar`).
