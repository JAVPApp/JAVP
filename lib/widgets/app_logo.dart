import 'package:flutter/material.dart';

/// Brand mark from [assets/branding/javp_logo.png].
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 28});

  final double size;

  static const assetPath = 'assets/branding/javp_logo.png';

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      assetPath,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'JAVP',
    );
  }
}
