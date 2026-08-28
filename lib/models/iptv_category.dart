import 'package:javp/services/iptv/iptv_display_name.dart';

enum IptvCategoryKind { live, vod, series }

class IptvCategory {
  const IptvCategory({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.sourceId,
    this.isAdult = false,
  });

  final String id;
  final String name;
  final IptvCategoryKind kind;
  final String? parentId;

  /// Owning IPTV / media-server source. Null for synthesized `catalog-group:` shelves.
  final String? sourceId;

  /// Provider-marked adult category (Xtream `is_adult`, Stalker `censored`, …).
  final bool isAdult;

  /// [name] with decorative wrappers stripped (`### FRANCE ###` → `FRANCE`).
  String get displayName => cleanIptvDisplayName(name);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'parentId': parentId,
    if (sourceId != null) 'sourceId': sourceId,
    if (isAdult) 'isAdult': true,
  };

  factory IptvCategory.fromJson(Map<String, dynamic> json) {
    return IptvCategory(
      id: '${json['id']}',
      name: '${json['name']}',
      kind: IptvCategoryKind.values.byName('${json['kind']}'),
      parentId: json['parentId']?.toString(),
      sourceId: json['sourceId']?.toString(),
      isAdult:
          json['isAdult'] == true ||
          json['isAdult'] == 1 ||
          json['adult'] == true ||
          json['is_adult'] == true ||
          json['is_adult'] == 1 ||
          json['censored'] == true ||
          json['censored'] == 1 ||
          json['censored'] == '1',
    );
  }

  IptvCategory copyWith({
    String? id,
    String? name,
    IptvCategoryKind? kind,
    String? parentId,
    String? sourceId,
    bool? isAdult,
  }) {
    return IptvCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      parentId: parentId ?? this.parentId,
      sourceId: sourceId ?? this.sourceId,
      isAdult: isAdult ?? this.isAdult,
    );
  }
}
