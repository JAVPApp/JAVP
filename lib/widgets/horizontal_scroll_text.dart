import 'package:flutter/material.dart';

/// One-line label that scrolls sideways when the string does not fit.
class HorizontalScrollText extends StatelessWidget {
  const HorizontalScrollText({
    super.key,
    required this.text,
    this.style,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final resolved = style ?? DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final painter = TextPainter(
          text: TextSpan(text: text, style: resolved),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          textAlign: textAlign ?? TextAlign.start,
        )..layout();
        final lineH = painter.height;
        final textW = painter.width;
        if (!maxW.isFinite || textW <= maxW + 0.5) {
          return Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: resolved,
            textAlign: textAlign,
          );
        }
        return SizedBox(
          width: maxW,
          height: lineH,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: SizedBox(
              width: textW,
              height: lineH,
              child: Text(
                text,
                maxLines: 1,
                softWrap: false,
                style: resolved,
                textAlign: textAlign,
              ),
            ),
          ),
        );
      },
    );
  }
}
