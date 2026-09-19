import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// Formula a blocco (`$$ ... $$`) renderizzata con layout matematico 2D
/// (frazioni, radici, sommatorie, matrici...) tramite `flutter_math_fork`.
///
/// Centrata quando c'è spazio, scorrevole in orizzontale quando la formula è
/// più larga della colonna (la `ListView` esterna scorre in verticale, quindi
/// non c'è conflitto di gesture). Se il sorgente TeX non è valido mostra il
/// sorgente grezzo in monospace invece di lasciare un buco o lanciare.
class DisplayMathBlock extends StatelessWidget {
  const DisplayMathBlock({
    super.key,
    required this.tex,
    required this.textStyle,
  });

  final String tex;

  /// Dimensione e colore base della formula (dal tema del corpo nota).
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Center(
              child: Math.tex(
                tex,
                mathStyle: MathStyle.display,
                textStyle: textStyle,
                onErrorFallback: (_) => Text(
                  tex,
                  style: textStyle.copyWith(
                    fontFamily: 'monospace',
                    fontSize: (textStyle.fontSize ?? 16) * 0.9,
                    color: errorColor,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
