import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../../models/markdown_ast_nodes.dart';
import 'inline_code_element_builder.dart';
import 'markdown_block_style.dart';

/// Rendering di un [ParagraphNode]: testo semplice, eventualmente su più
/// righe, con gli stili inline principali (grassetto, corsivo,
/// barrato, link, codice inline) risolti tramite `MarkdownBody`.
class ParagraphBlockWidget extends StatelessWidget {
  final ParagraphNode node;
  final MarkdownBlockStyle style;

  const ParagraphBlockWidget({
    super.key,
    required this.node,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
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
  }
}
