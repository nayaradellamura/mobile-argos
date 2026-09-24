import 'package:flutter/material.dart';

/// Substituto drop-in pra qualquer `Text` que corta com "..." — segura o
/// dedo em cima (ou passa o mouse, no desktop/web) pra ver o texto
/// completo num tooltip, em vez do texto sumir sem nenhuma forma de lê-lo.
///
/// Uso: troca `Text(valor, overflow: TextOverflow.ellipsis, style: s)` por
/// `EllipsisText(valor, style: s)` — os outros parâmetros (maxLines,
/// textAlign etc.) são opcionais e têm o mesmo comportamento de um `Text`
/// normal.
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
      // Só cobre o espaço do texto, não a tela toda — evita capturar toque
      // que era pra ir pro card/botão em volta.
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
