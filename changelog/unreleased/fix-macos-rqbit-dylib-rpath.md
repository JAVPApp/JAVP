### Fixes

- macOS: app no longer crashes at launch looking for `librqbit_engine` under the build machine's home directory; the torrent engine dylib now loads from the app bundle via `@rpath`.
