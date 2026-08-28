import 'dart:convert';

import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/screens/catalog_category_screen.dart';

/// GoRouter extra codec for typed extras that survive refresh / history restore.
class JavpRouteExtraCodec extends Codec<Object?, Object?> {
  const JavpRouteExtraCodec();

  @override
  Converter<Object?, Object?> get decoder => const _JavpRouteExtraDecoder();

  @override
  Converter<Object?, Object?> get encoder => const _JavpRouteExtraEncoder();
}

class _JavpRouteExtraEncoder extends Converter<Object?, Object?> {
  const _JavpRouteExtraEncoder();

  @override
  Object? convert(Object? input) {
    if (input is MediaItem) return input.toJson();
    if (input is CatalogCategoryArgs) return input.toJson();
    if (input is IptvCategory) {
      return {'__route': 'IptvCategory', ...input.toJson()};
    }
    return input;
  }
}

class _JavpRouteExtraDecoder extends Converter<Object?, Object?> {
  const _JavpRouteExtraDecoder();

  @override
  Object? convert(Object? input) {
    final categoryArgs = CatalogCategoryArgs.tryParse(input);
    if (categoryArgs != null) return categoryArgs;
    if (input is Map && input['__route'] == 'IptvCategory') {
      return IptvCategory.fromJson(Map<String, dynamic>.from(input));
    }
    return mediaItemFromRouteExtra(input) ?? input;
  }
}
