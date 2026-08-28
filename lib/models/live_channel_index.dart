/// Precomputed live TV index: collapsed channel order + per-group pages.
///
/// Stores ids only (resolved against the in-memory catalog). Built off the
/// critical path so TV can page instantly instead of scanning ~28k rows.
class LiveChannelIndex {
  const LiveChannelIndex({
    required this.fingerprint,
    required this.allIds,
    required this.idsByGroup,
    required this.variantCountById,
    required this.familyByChannelId,
    required this.variantIdsByFamily,
  });

  final String fingerprint;

  /// Collapsed “All” order (one id per channel family, first-seen).
  final List<String> allIds;

  /// Category/group name → collapsed ids in that group.
  final Map<String, List<String>> idsByGroup;

  /// Representative channel id → number of quality variants.
  final Map<String, int> variantCountById;

  /// Every live channel id → family key (or absent when unique).
  final Map<String, String> familyByChannelId;

  /// Family key → variant channel ids (best-first).
  final Map<String, List<String>> variantIdsByFamily;

  int countForGroup(String? groupName) {
    if (groupName == null || groupName.isEmpty) return allIds.length;
    return idsByGroup[groupName]?.length ?? 0;
  }

  List<String> idsForGroup(String? groupName) {
    if (groupName == null || groupName.isEmpty) return allIds;
    return idsByGroup[groupName] ?? const [];
  }

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'allIds': allIds,
        'idsByGroup': {
          for (final e in idsByGroup.entries) e.key: e.value,
        },
        'variantCountById': variantCountById,
        'familyByChannelId': familyByChannelId,
        'variantIdsByFamily': {
          for (final e in variantIdsByFamily.entries) e.key: e.value,
        },
      };

  factory LiveChannelIndex.fromJson(Map<String, dynamic> json) {
    List<String> stringList(dynamic raw) {
      if (raw is! List) return const [];
      return [
        for (final e in raw)
          if ('$e'.isNotEmpty) '$e',
      ];
    }

    Map<String, List<String>> stringListMap(dynamic raw) {
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          if ('${e.key}'.isNotEmpty) '${e.key}': stringList(e.value),
      };
    }

    Map<String, String> stringMap(dynamic raw) {
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          if ('${e.key}'.isNotEmpty && '${e.value}'.isNotEmpty)
            '${e.key}': '${e.value}',
      };
    }

    Map<String, int> intMap(dynamic raw) {
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          if ('${e.key}'.isNotEmpty)
            '${e.key}': (e.value is num)
                ? (e.value as num).toInt()
                : int.tryParse('${e.value}') ?? 1,
      };
    }

    return LiveChannelIndex(
      fingerprint: '${json['fingerprint'] ?? ''}',
      allIds: stringList(json['allIds']),
      idsByGroup: stringListMap(json['idsByGroup']),
      variantCountById: intMap(json['variantCountById']),
      familyByChannelId: stringMap(json['familyByChannelId']),
      variantIdsByFamily: stringListMap(json['variantIdsByFamily']),
    );
  }
}
