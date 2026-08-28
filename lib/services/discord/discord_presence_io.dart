import 'dart:async';

import 'package:javp/compat/dart_discord_presence.dart';
import 'package:javp/services/discord/discord_presence_mapper.dart';

export 'package:javp/compat/dart_discord_presence.dart'
    show DiscordNotRunningException, DiscordConnectionException;

typedef DiscordRPCHandle = DiscordRPC;

bool get isDiscordAvailable => DiscordRPC.isAvailable;

bool isRpcConnected(DiscordRPCHandle rpc) => rpc.isConnected;

Future<DiscordRPCHandle> createAndInitializeRpc(String clientId) async {
  final rpc = DiscordRPC();
  await rpc.initialize(clientId);
  return rpc;
}

Future<void> disposeRpc(DiscordRPCHandle rpc) => rpc.dispose();

Future<void> setPresence(DiscordRPCHandle rpc, DiscordPresenceData data) async {
  DiscordTimestamps? timestamps;
  if (data.startUnixSec != null || data.endUnixSec != null) {
    timestamps = DiscordTimestamps(
      start: data.startUnixSec,
      end: data.endUnixSec,
    );
  }

  final DiscordAsset largeAsset;
  if (data.isExternalUrl && data.largeAssetKey != null) {
    largeAsset = DiscordAsset.fromUrl(data.largeAssetKey!, text: data.largeAssetText);
  } else {
    largeAsset = DiscordAsset(key: data.largeAssetKey, text: data.largeAssetText ?? 'JAVP');
  }

  await rpc.setPresence(
    DiscordPresence(
      type: switch (data.activity) {
        DiscordPresenceActivity.listening => DiscordActivityType.listening,
        DiscordPresenceActivity.watching => DiscordActivityType.watching,
      },
      details: data.details,
      state: data.state,
      timestamps: timestamps,
      largeAsset: largeAsset,
      smallAsset: data.smallAssetKey != null
          ? DiscordAsset(key: data.smallAssetKey, text: data.smallAssetText)
          : null,
      statusDisplayType: DiscordStatusDisplayType.details,
      buttons: [
        DiscordButton(label: 'Website', url: data.websiteUrl),
        DiscordButton(label: 'Discord', url: data.discordInviteUrl),
      ],
    ),
  );
}

Future<void> clearPresence(DiscordRPCHandle rpc) => rpc.clearPresence();

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
