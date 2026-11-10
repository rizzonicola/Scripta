import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/tex.dart' show SyntaxTree;

import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';

/// Formula a blocco (`$$ ... $$`) renderizzata con layout matematico 2D
/// (frazioni, radici, sommatorie, matrici...) tramite `flutter_math_fork`.
///
/// Centrata quando c'è spazio, scorrevole in orizzontale quando la formula è
/// più larga della colonna (la `ListView` esterna scorre in verticale, quindi
/// non c'è conflitto di gesture). Se il sorgente TeX non è valido mostra un
/// riquadro con l'errore localizzato, il sorgente in monospace e un pulsante
/// per copiare il LaTeX, invece di lasciare un buco o lanciare.
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
    this.surfaceColor,
  });

  final String tex;

  /// Dimensione e colore base della formula (dal tema del corpo nota).
  final TextStyle textStyle;

  /// Albero sintattico TeX pre-analizzato (opzionale, per evitare re-parsing).
  final SyntaxTree? ast;

  /// Errore di parsing pre-catturato (se la formula non è sintatticamente valida).
  final ParseException? parseError;

  /// Sfondo del riquadro d'errore; se assente usa la superficie del tema.
  final Color? surfaceColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;
    final fallbackText = Text(
      tex,
      style: textStyle.copyWith(
        fontFamily: AppTheme.monospaceFontFamily,
        fontSize: (textStyle.fontSize ?? 16) * 0.9,
        color: errorColor,
      ),
    );

    // Errore già noto: niente scroll orizzontale, così il riquadro (e il suo
    // pulsante di copia) può usare tutta la larghezza della colonna.
    if (parseError != null) {
      return _MathFallback(
        tex: tex,
        textStyle: textStyle,
        errorColor: errorColor,
        surfaceColor: surfaceColor ?? theme.colorScheme.surfaceContainerHigh,
      );
    }

    final Widget mathWidget;
    if (ast != null) {
      // Percorso ottimizzato: usa l'AST già calcolato senza toccare il parser.
      mathWidget = Math(
        ast: ast,
        mathStyle: MathStyle.display,
        textStyle: textStyle,
        onErrorFallback: (_) => fallbackText,
      );
    } else {
      // Fallback standalone se istanziato senza AST pre-parsato.
      mathWidget = Math.tex(
        tex,
        mathStyle: MathStyle.display,
        textStyle: textStyle,
        onErrorFallback: (_) => fallbackText,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Center(child: mathWidget),
          ),
        );
      },
    );
  }
}

class _MathFallback extends StatefulWidget {
  const _MathFallback({
    required this.tex,
    required this.textStyle,
    required this.errorColor,
    required this.surfaceColor,
  });

  final String tex;
  final TextStyle textStyle;
  final Color errorColor;
  final Color surfaceColor;

  @override
  State<_MathFallback> createState() => _MathFallbackState();
}

class _MathFallbackState extends State<_MathFallback> {
  Timer? _resetTimer;
  bool _copied = false;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.tex));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      decoration: BoxDecoration(
        color: widget.surfaceColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.texSyntaxError,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: widget.errorColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                _copied ? l10n.latexCopied : '',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              IconButton(
                tooltip: l10n.copyLatex,
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                visualDensity: VisualDensity.compact,
                color: _copied
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                onPressed: _copy,
                icon: Icon(
                  _copied ? Icons.check_rounded : Icons.content_copy_rounded,
                ),
              ),
            ],
          ),
          SelectableText(
            widget.tex,
            style: widget.textStyle.copyWith(
              fontFamily: AppTheme.monospaceFontFamily,
              fontSize: (widget.textStyle.fontSize ?? 16) * 0.9,
              color: widget.errorColor,
            ),
          ),
        ],
      ),
    );
  }
}
