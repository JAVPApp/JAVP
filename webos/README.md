# webOS platform folder

This directory is a placeholder. Generate the real flutter-webos project files
on an Ubuntu host (WSL2 is fine):

```bash
flutter-webos create --platforms webos .
```

Then build with:

```bash
flutter-webos run -d <tv> --dart-define=JAVP_HOST=webos
```

Docs: [docs/webos.md](../docs/webos.md) · [docs/smart-tv.md](../docs/smart-tv.md)
