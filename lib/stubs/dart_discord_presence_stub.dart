/// Web stub for dart_discord_presence — no-op implementations.
library dart_discord_presence_stub;

import 'dart:async';

class DiscordRPC {
  static bool get isAvailable => false;

  bool get isConnected => false;

  Future<void> initialize(String clientId) async {}
  Future<void> setPresence(DiscordPresence presence) async {}
  Future<void> clearPresence() async {}
  Future<void> dispose() async {}
}

class DiscordPresence {
  const DiscordPresence({
    this.type,
    this.details,
    this.state,
    this.timestamps,
    this.largeAsset,
    this.smallAsset,
    this.statusDisplayType,
    this.buttons,
  });

  final DiscordActivityType? type;
  final String? details;
  final String? state;
  final DiscordTimestamps? timestamps;
  final DiscordAsset? largeAsset;
  final DiscordAsset? smallAsset;
  final DiscordStatusDisplayType? statusDisplayType;
  final List<DiscordButton>? buttons;
}

enum DiscordActivityType { playing, streaming, listening, watching, custom, competing }
enum DiscordStatusDisplayType { details, state }

class DiscordTimestamps {
  const DiscordTimestamps({this.start, this.end});
  final int? start;
  final int? end;
}

class DiscordAsset {
  const DiscordAsset({this.key, this.text});
  factory DiscordAsset.fromUrl(String url, {String? text}) =>
      DiscordAsset(key: url, text: text);
  final String? key;
  final String? text;
}

class DiscordButton {
  const DiscordButton({required this.label, required this.url});
  final String label;
  final String url;
}

class DiscordNotRunningException implements Exception {
  const DiscordNotRunningException([this.message]);
  final String? message;
  @override
  String toString() => message ?? 'Discord is not running';
}

class DiscordConnectionException implements Exception {
  const DiscordConnectionException([this.message]);
  final String? message;
  @override
  String toString() => message ?? 'Discord connection failed';
}
