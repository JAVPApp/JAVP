import 'dart:async';

import 'package:javp/services/discord/discord_presence_mapper.dart';

typedef DiscordRPCHandle = _NoOpRpc;

bool get isDiscordAvailable => false;

bool isRpcConnected(DiscordRPCHandle rpc) => false;

Future<DiscordRPCHandle> createAndInitializeRpc(String clientId) async {
  return _NoOpRpc();
}

Future<void> disposeRpc(DiscordRPCHandle rpc) async {}

Future<void> setPresence(DiscordRPCHandle rpc, DiscordPresenceData data) async {}

Future<void> clearPresence(DiscordRPCHandle rpc) async {}

class _NoOpRpc {}

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

class DiscordPresenceData {
  const DiscordPresenceData({
    required this.activity,
    this.details,
    this.state,
    this.startUnixSec,
    this.endUnixSec,
    this.largeAssetKey,
    this.largeAssetText,
    this.smallAssetKey,
    this.smallAssetText,
    required this.websiteUrl,
    required this.discordInviteUrl,
    this.isExternalUrl = false,
  });

  final DiscordPresenceActivity activity;
  final String? details;
  final String? state;
  final int? startUnixSec;
  final int? endUnixSec;
  final String? largeAssetKey;
  final String? largeAssetText;
  final String? smallAssetKey;
  final String? smallAssetText;
  final String websiteUrl;
  final String discordInviteUrl;
  final bool isExternalUrl;
}
