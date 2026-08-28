# Cursor Cloud Agent base image for JAVP (Flutter).
# Intentional scope: Flutter SDK + pub cache warm-up + Linux desktop build/run
# for verification — NOT a full Android SDK. Auto-fix / review agents need
# dart analyze + code edits; APK / signed releases stay on GitHub Actions.
#
# Cursor requires `git` (clone) and `sudo` (VM bootstrap) in custom images.
# ubuntu:24.04 ships the ubuntu user + sudo *group*, but not the sudo binary.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    FLUTTER_HOME=/opt/flutter \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH \
    PUB_CACHE=/opt/pub-cache \
    FLUTTER_STORAGE_BASE_URL=https://storage.googleapis.com \
    GIT_TERMINAL_PROMPT=0

# Toolchain notes:
#  - g++ + libstdc++-14-dev give clang a complete C++ toolchain so
#    `flutter build linux` links (clang selects the highest gcc dir present).
#  - libmpv-dev/mpv back media_kit's Linux playback.
#  - libayatana-appindicator3-dev is required to link tray_manager on Linux
#    (tray UX itself is Windows-only at runtime).
#  - xdg-user-dirs is required at runtime or path_provider throws
#    MissingPlatformDirectoryException on startup.
#  - sudo is required by Cursor Cloud Agent bootstrap (not optional).
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      ca-certificates \
      curl \
      git \
      sudo \
      unzip \
      xz-utils \
      zip \
      clang \
      cmake \
      ninja-build \
      pkg-config \
      libgtk-3-dev \
      liblzma-dev \
      g++ \
      libstdc++-14-dev \
      libsecret-1-dev \
      libjsoncpp-dev \
      libmpv-dev \
      mpv \
      libayatana-appindicator3-dev \
      xdg-user-dirs \
      python3 \
      openjdk-17-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# Flutter stable (matches CI: subosito/flutter-action channel stable)
ARG FLUTTER_VERSION=stable
RUN git clone --depth 1 -b "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
    && flutter config --no-analytics --enable-linux-desktop \
    && flutter precache --linux \
    && dart --disable-analytics \
    && flutter doctor -v || true

# Non-root user expected by Cursor cloud images (ubuntu exists on noble).
RUN id -u ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
RUN groupadd -f sudo \
    && usermod -aG sudo ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu \
    && mkdir -p "${PUB_CACHE}" \
    && chown -R ubuntu:ubuntu "${FLUTTER_HOME}" "${PUB_CACHE}" \
    && printf '%s\n' \
         'export FLUTTER_HOME=/opt/flutter' \
         'export PATH="$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$PATH"' \
         'export PUB_CACHE=/opt/pub-cache' \
         > /etc/profile.d/javp-flutter.sh \
    && command -v sudo \
    && command -v git

USER ubuntu
WORKDIR /home/ubuntu
# Fail the image build if Cursor's required bootstrap tools are broken for ubuntu.
RUN sudo -n true && flutter --version | head -1