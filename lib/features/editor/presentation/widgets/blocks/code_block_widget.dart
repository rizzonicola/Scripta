import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../../core/utils/syntax_highlighter.dart';
import '../../../models/markdown_ast_nodes.dart';
import 'markdown_block_style.dart';

/// Rendering di un [CodeBlockNode] (fence ``` o ~~~): contenitore
/// dedicato, monospaziatura, numeri di riga e syntax highlighting.
///
/// A differenza degli altri renderer di blocco, questo NON passa dal
/// layer inline di `flutter_markdown_plus`: il contenuto grezzo (`code`)
/// è già interamente disponibile su [CodeBlockNode] grazie all'AST, quindi
/// viene disegnato direttamente riga per riga, con lo stesso motore di
/// evidenziazione sintattica (`ScriptaCodeHighlighter`) già usato altrove
/// nell'app.
class CodeBlockWidget extends StatelessWidget {
  final CodeBlockNode node;
  final MarkdownBlockStyle style;

  const CodeBlockWidget({
    super.key,
    required this.node,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final lines = node.code.split('\n');
    // Un fence che termina con `\n` prima della chiusura produce una
    // riga vuota finale nello split: la si scarta per non mostrare un
    // numero di riga "fantasma" in fondo al blocco.
    final effectiveLines = lines.isNotEmpty && lines.last.isEmpty && lines.length > 1
        ? lines.sublist(0, lines.length - 1)
        : lines;

    final codeStyle = GoogleFonts.jetBrainsMono(
      fontSize: style.fontSize * 0.85,
      height: 1.5,
      color: style.onSurfaceColor,
    );
    final lineNumberStyle = codeStyle.copyWith(
      color: style.onSurfaceColor.withValues(alpha: 0.35),
    );
    final gutterWidth = (effectiveLines.length.toString().length * 9.0) + 16.0;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: style.isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: style.outlineColor.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (node.language != null && node.language!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Text(
                node.language!.trim(),
                style: lineNumberStyle.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Gutter dei numeri di riga: colonna separata, così da
                    // restare fissa quando il codice scorre in orizzontale.
                    SizedBox(
                      width: gutterWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var i = 0; i < effectiveLines.length; i++)
                            Text('${i + 1}', style: lineNumberStyle),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in effectiveLines)
                          Text.rich(
                            line.isEmpty
                                // Riga vuota: uno spazio mantiene l'altezza
                                // della riga allineata al proprio numero
                                // nel gutter, invece di collassare a zero.
                                ? TextSpan(text: ' ', style: codeStyle)
                                : ScriptaCodeHighlighter.highlight(
                                    code: line,
                                    language: node.language ?? '',
                                    isDark: style.isDark,
                                    baseStyle: codeStyle,
                                  ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
