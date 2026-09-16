import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;

/// Builder per gli elementi `<code>` prodotti da `flutter_markdown_plus`
/// quando i renderer di blocco (paragrafo, titolo, item di lista,
/// blockquote) delegano a `MarkdownBody` la sola risoluzione della
/// formattazione INLINE del proprio testo grezzo.
///
/// Il layer di blocco dell'AST (`markdown_ast_nodes.dart`) non include un
/// parser inline dedicato per design (vedi la doc di `MarkdownBlockNode`):
/// riusare `MarkdownBody` per il solo inline layer, invece di scriverne uno
/// da zero, mantiene un'unica implementazione delle regole GFM
/// (grassetto/corsivo/link/codice inline) condivisa con il resto
/// dell'app, mentre l'AST resta l'unica fonte di verità per la
/// segmentazione in BLOCCHI (l'unica cosa che conta per la
/// virtualizzazione dello scroll).
class InlineCodeElementBuilder extends MarkdownElementBuilder {
  final TextStyle inlineCodeStyle;
  final double fontSize;
  final bool isDark;

  InlineCodeElementBuilder({
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
  });

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final String text = element.textContent;

    // Codice multi-riga o con info-string: non dovrebbe verificarsi dentro
    // un blocco già segmentato dall'AST (i fenced code block sono gestiti
    // da `CodeBlockWidget`, non da questo builder), ma si gestisce
    // comunque in modo robusto invece di lanciare un'eccezione.
    if (element.attributes.containsKey('class') || text.contains('\n')) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            text.trimRight(),
            style: GoogleFonts.jetBrainsMono(fontSize: fontSize * 0.85, height: 1.4),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: inlineCodeStyle),
    );
  }
}
