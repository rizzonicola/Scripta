import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/models/markdown_selection_range.dart';
import '../../../models/markdown_ast_nodes.dart';
import 'inline_code_element_builder.dart';
import 'markdown_block_style.dart';

/// Rendering di un [HeadingNode] (H1-H6, sintassi ATX `#`..`######`).
///
/// Lo stile è scalato in base a [HeadingNode.level]: per i livelli H1-H3
/// [MarkdownBlockStyle.styleSheet] espone già uno stile dedicato
/// (`h1`/`h2`/`h3`); per H4-H6, non presenti nello style sheet base, lo
/// stile viene derivato da `h3` con una riduzione progressiva della
/// dimensione, così da mantenere comunque una gerarchia visiva coerente.
class HeadingBlockWidget extends StatelessWidget {
  final HeadingNode node;
  final MarkdownBlockStyle style;

  /// Intersezione tra la selezione del documento e questo blocco.
  ///
  /// Stessa limitazione documentata in [ParagraphBlockWidget]: il testo
  /// dell'heading passa comunque per `MarkdownBody` per risolvere la
  /// formattazione inline, quindi l'evidenziazione non può essere
  /// sezionata per offset di carattere e copre l'intero heading sia per
  /// [SelectionType.full] sia per [SelectionType.partial].
  final BlockSelectionIntersection intersection;

  const HeadingBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.intersection = BlockSelectionIntersection.none,
  });

  TextStyle _styleForLevel() {
    switch (node.level) {
      case 1:
        return style.styleSheet.h1!;
      case 2:
        return style.styleSheet.h2!;
      case 3:
        return style.styleSheet.h3!;
      default:
        // H4-H6: nessuno stile dedicato nello style sheet condiviso.
        // Derivano da h3 riducendone progressivamente la dimensione.
        final base = style.styleSheet.h3!;
        final shrink = 1.0 - (node.level - 3) * 0.12;
        return base.copyWith(
          fontSize: (base.fontSize ?? style.fontSize * 1.3) * shrink,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final headingStyle = _styleForLevel();
    final body = MarkdownBody(
      // Il testo dell'heading è già privo dei cancelletti (vedi
      // `HeadingNode.text`): passarlo a `MarkdownBody` serve solo a
      // risolvere l'eventuale formattazione INLINE al suo interno
      // (`**grassetto**`, link, `code`, ...), non a re-interpretarlo
      // come blocco.
      data: node.text.isEmpty ? ' ' : node.text,
      selectable: false,
      styleSheet: style.styleSheet.copyWith(p: headingStyle),
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

    final content = Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: body,
    );

    if (intersection.type == SelectionType.none) {
      return content;
    }

    final highlightColor =
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.28);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlightColor,
        borderRadius: BorderRadius.circular(2),
      ),
      child: content,
    );
  }
}
