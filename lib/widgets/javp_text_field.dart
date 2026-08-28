import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/widgets/tv/tv_deferred_ime.dart';

/// App [TextField] that does not open the TV keyboard until OK / Select.
class JavpTextField extends StatelessWidget {
  const JavpTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.autofocus = false,
    this.obscureText = false,
    this.maxLines = 1,
    this.enabled,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.inputFormatters,
    this.cursorColor,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.smartDashesType,
    this.smartQuotesType,
    this.readOnly = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final bool autofocus;
  final bool obscureText;
  final int maxLines;
  final bool? enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final List<TextInputFormatter>? inputFormatters;
  final Color? cursorColor;
  final bool autocorrect;
  final bool enableSuggestions;
  final SmartDashesType? smartDashesType;
  final SmartQuotesType? smartQuotesType;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return TvDeferredIme(
      focusNode: focusNode,
      enabled: enabled ?? true,
      builder: (context, ime) => TextField(
        controller: controller,
        focusNode: ime.focusNode,
        decoration: decoration,
        keyboardType: ime.readOnly ? TextInputType.none : keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        style: style,
        autofocus: autofocus,
        obscureText: obscureText,
        maxLines: maxLines,
        enabled: enabled,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onTap: () {
          ime.onTap();
          onTap?.call();
        },
        inputFormatters: inputFormatters,
        cursorColor: cursorColor,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        smartDashesType: smartDashesType,
        smartQuotesType: smartQuotesType,
        readOnly: readOnly || ime.readOnly,
      ),
    );
  }
}
