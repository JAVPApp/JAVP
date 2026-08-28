import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/services/diagnostics/javp_log.dart';

/// On-device Stable ↔ Dev sources mirror for Android.
///
/// Windows / Linux / macOS already share app data (same binary / bundle id), so
/// Stable and Dev see the same SharedPreferences + secure storage. Android Dev
/// uses `com.javp.javp.dev`, so sandboxes differ — this bridge publishes a
/// signature-protected ContentProvider payload both packages can read/write.
class ChannelSourcesBridge {
  ChannelSourcesBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'javp/channel_sources';
  static const schema = 1;
  static const kind = 'javp-channel-sources';

  static final instance = ChannelSourcesBridge();

  final MethodChannel _channel;

  /// Android only — desktop channels already share storage identity.
  bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Publish the active profile's sources (including secrets) for the sibling
  /// channel. No-op when unsupported or on failure.
  Future<void> publish({
    required String profileId,
    required List<IptvSource> sources,
    required DateTime updatedAt,
  }) async {
    if (!isSupported) return;
    try {
      final payload = jsonEncode({
        'schema': schema,
        'kind': kind,
        'profileId': profileId,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'sources': [for (final s in sources) s.toJson()],
      });
      await _channel.invokeMethod<bool>('publish', {'payload': payload});
    } catch (e) {
      JavpLog.w('channel_sources', 'publish failed: $e');
    }
  }

  /// Pull a newer sibling snapshot for [profileId], if one exists.
  Future<ChannelSourcesSnapshot?> pullSibling({
    required String profileId,
    DateTime? localUpdatedAt,
  }) async {
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMethod<String>('pullSibling');
      if (raw == null || raw.isEmpty) return null;
      final snap = ChannelSourcesSnapshot.tryDecode(raw);
      if (snap == null) return null;
      if (snap.profileId != profileId) return null;
      if (localUpdatedAt != null &&
          !snap.updatedAt.isAfter(localUpdatedAt)) {
        return null;
      }
      return snap;
    } catch (e) {
      JavpLog.w('channel_sources', 'pullSibling failed: $e');
      return null;
    }
  }
}

class ChannelSourcesSnapshot {
  const ChannelSourcesSnapshot({
    required this.profileId,
    required this.updatedAt,
    required this.sources,
  });

  final String profileId;
  final DateTime updatedAt;
  final List<IptvSource> sources;

  static ChannelSourcesSnapshot? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final json = Map<String, dynamic>.from(decoded);
      if (json['kind'] != ChannelSourcesBridge.kind) return null;
      final profileId = (json['profileId'] as String?)?.trim();
      if (profileId == null || profileId.isEmpty) return null;
      final updatedAt =
          DateTime.tryParse(json['updatedAt'] as String? ?? '')?.toUtc();
      if (updatedAt == null) return null;
      final rawSources = json['sources'];
      if (rawSources is! List) return null;
      final sources = <IptvSource>[];
      for (final entry in rawSources) {
        if (entry is! Map) continue;
        final source = IptvSource.tryFromJson(Map<String, dynamic>.from(entry));
        if (source != null) sources.add(source);
      }
      return ChannelSourcesSnapshot(
        profileId: profileId,
        updatedAt: updatedAt,
        sources: sources,
      );
    } catch (_) {
      return null;
    }
  }
}
