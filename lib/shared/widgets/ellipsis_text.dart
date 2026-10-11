import 'package:flutter/material.dart';

/// Texto que corta com "..." quando não cabe, mostrando o conteúdo completo
/// num tooltip ao toque longo/hover.
class EllipsisText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int maxLines;
  final TextAlign? textAlign;

  const EllipsisText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      triggerMode: TooltipTriggerMode.longPress,
      child: Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
      ),
    );
  }
}
