import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/models/markdown_selection_range.dart';
import '../../../models/markdown_ast_nodes.dart';
import 'inline_code_element_builder.dart';
import 'markdown_block_style.dart';

/// Rendering di un [ParagraphNode]: testo semplice, eventualmente su più
/// righe, con gli stili inline principali (grassetto, corsivo,
/// barrato, link, codice inline) risolti tramite `MarkdownBody`.
class ParagraphBlockWidget extends StatelessWidget {
  final ParagraphNode node;
  final MarkdownBlockStyle style;

  /// Intersezione tra la selezione del documento e questo blocco.
  ///
  /// NOTA IMPLEMENTATIVA: `MarkdownBody` (flutter_markdown_plus) parsa
  /// autonomamente la sintassi inline del paragrafo (grassetto, link,
  /// codice) e costruisce il proprio albero di widget: non espone i
  /// singoli `TextSpan` indicizzati per offset del testo sorgente, quindi
  /// non è possibile — senza sostituire `MarkdownBody` con un renderer
  /// inline proprietario — sezionare lo sfondo carattere per carattere
  /// come avviene in [markdown_block_widget.dart] per i code block.
  /// Come conseguenza, sia [SelectionType.full] sia [SelectionType.partial]
  /// evidenziano l'intero paragrafo: è un'approssimazione funzionante,
  /// non l'evidenziazione a grana fine richiesta dalla specifica.
  final BlockSelectionIntersection intersection;

  const ParagraphBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.intersection = BlockSelectionIntersection.none,
  });

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: node.text.isEmpty ? ' ' : node.text,
      selectable: false,
      styleSheet: style.styleSheet,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      onTapLink: (text, href, title) async {
        if (href == null || href.isEmpty) return;
        final uri = Uri.tryParse(href);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      builders: {
        'code': InlineCodeElementBuilder(
          inlineCodeStyle: style.inlineCodeStyle,
          fontSize: style.fontSize,
          isDark: style.isDark,
        ),
      },
    );

    if (intersection.type == SelectionType.none) {
      return body;
    }

    final highlightColor =
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.28);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlightColor,
        borderRadius: BorderRadius.circular(2),
      ),
      child: body,
    );
  }
}
