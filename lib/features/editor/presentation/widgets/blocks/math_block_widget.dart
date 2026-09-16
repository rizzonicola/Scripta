import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/markdown_ast_nodes.dart';
import 'markdown_block_style.dart';

/// Rendering di un [MathBlockNode] (`$$ ... $$`).
///
/// Nessun motore di rendering LaTeX è collegato in questa fase: l'
/// espressione viene mostrata testualmente, in un contenitore dedicato e
/// in monospaziatura, cosi da restare comunque leggibile e distinguibile
/// dal testo circostante. Un vero rendering (es. tramite un motore
/// TeX/MathML) è un candidato naturale per i Custom Renderer avanzati
/// della Fase 4, senza che questo richieda modifiche all'AST.
class MathBlockWidget extends StatelessWidget {
  final MathBlockNode node;
  final MarkdownBlockStyle style;

  const MathBlockWidget({
    super.key,
    required this.node,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: style.primaryColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: style.primaryColor.withValues(alpha: 0.25)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          node.expression,
          style: GoogleFonts.jetBrainsMono(
            fontSize: style.fontSize * 0.95,
            fontStyle: FontStyle.italic,
            color: style.onSurfaceColor,
          ),
        ),
      ),
    );
  }
}
