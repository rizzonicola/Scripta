import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/tex.dart' show SyntaxTree;

/// Formula a blocco (`$$ ... $$`) renderizzata con layout matematico 2D
/// (frazioni, radici, sommatorie, matrici...) tramite `flutter_math_fork`.
///
/// Centrata quando c'è spazio, scorrevole in orizzontale quando la formula è
/// più larga della colonna (la `ListView` esterna scorre in verticale, quindi
/// non c'è conflitto di gesture). Se il sorgente TeX non è valido mostra il
/// sorgente grezzo in monospace invece di lasciare un buco o lanciare.
///
/// Per massimizzare le prestazioni durante lo scroll nella `ListView.builder`,
/// accetta un [ast] o [parseError] già analizzati (calcolati una volta sola a
/// monte nell'elemento della vista), evitando di rieseguire `TexParser.parse()`
/// a ogni build/frame.
class DisplayMathBlock extends StatelessWidget {
  const DisplayMathBlock({
    super.key,
    required this.tex,
    required this.textStyle,
    this.ast,
    this.parseError,
  });

  final String tex;

  /// Dimensione e colore base della formula (dal tema del corpo nota).
  final TextStyle textStyle;

  /// Albero sintattico TeX pre-analizzato (opzionale, per evitare re-parsing).
  final SyntaxTree? ast;

  /// Errore di parsing pre-catturato (se la formula non è sintatticamente valida).
  final ParseException? parseError;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    final fallbackWidget = Text(
      tex,
      style: textStyle.copyWith(
        fontFamily: 'monospace',
        fontSize: (textStyle.fontSize ?? 16) * 0.9,
        color: errorColor,
      ),
    );

    final Widget mathWidget;
    if (ast != null || parseError != null) {
      // Percorso ottimizzato: usa l'AST già calcolato senza toccare il parser.
      mathWidget = Math(
        ast: ast,
        parseError: parseError,
        mathStyle: MathStyle.display,
        textStyle: textStyle,
        onErrorFallback: (_) => fallbackWidget,
      );
    } else {
      // Fallback standalone se istanziato senza AST pre-parsato.
      mathWidget = Math.tex(
        tex,
        mathStyle: MathStyle.display,
        textStyle: textStyle,
        onErrorFallback: (_) => fallbackWidget,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Center(
              child: mathWidget,
            ),
          ),
        );
      },
    );
  }
}
