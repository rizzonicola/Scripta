import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/models/markdown_selection_range.dart';
import '../../../models/markdown_ast_nodes.dart';
import 'inline_code_element_builder.dart'; // ignore: unused_import
import 'markdown_block_style.dart';

/// Calcola la lunghezza totale in caratteri (UTF-16 code units) di un [InlineSpan].
int computeSpanLength(InlineSpan span) {
  if (span is TextSpan) {
    int length = span.text?.length ?? 0;
    if (span.children != null) {
      for (final child in span.children!) {
        length += computeSpanLength(child);
      }
    }
    return length;
  }
  return span.toPlainText(includeSemanticsLabels: false).length;
}

/// Calcola la lunghezza totale cumulativa in caratteri di una lista di [InlineSpan].
int computeSpansLength(List<InlineSpan> spans) {
  int total = 0;
  for (final span in spans) {
    total += computeSpanLength(span);
  }
  return total;
}

/// Applica ricorsivamente il colore di evidenziazione [highlightColor] a un [InlineSpan].
InlineSpan applyHighlightToSpan(InlineSpan span, Color highlightColor) {
  if (span is TextSpan) {
    final effectiveStyle = (span.style ?? const TextStyle()).copyWith(
      backgroundColor: highlightColor,
    );
    final List<InlineSpan>? newChildren = span.children != null
        ? span.children!
            .map((c) => applyHighlightToSpan(c, highlightColor))
            .toList()
        : null;

    return TextSpan(
      text: span.text,
      children: newChildren,
      style: effectiveStyle,
      recognizer: span.recognizer,
      semanticsLabel: span.semanticsLabel,
    );
  }
  return span;
}

/// Applica il colore di evidenziazione [highlightColor] a tutti gli span della lista.
List<InlineSpan> applyHighlightToSpans(
  List<InlineSpan> spans,
  Color highlightColor,
) {
  return spans
      .map((span) => applyHighlightToSpan(span, highlightColor))
      .toList();
}

/// Seziona un singolo [InlineSpan] relativamente a un sotto-intervallo locale [sliceStart, sliceEnd].
List<InlineSpan> _sliceSingleSpan(
  InlineSpan span,
  int sliceStart,
  int sliceEnd,
  Color highlightColor,
) {
  if (span is! TextSpan) {
    return [applyHighlightToSpan(span, highlightColor)];
  }

  final String text = span.text ?? '';
  final int textLen = text.length;
  final bool hasChildren = span.children != null && span.children!.isNotEmpty;

  // Caso 1: Foglia TextSpan (solo testo, nessun figlio)
  if (!hasChildren) {
    final List<InlineSpan> out = [];

    // Caratteri prima della selezione (stile originale senza sfondo)
    if (sliceStart > 0) {
      out.add(
        TextSpan(
          text: text.substring(0, math.min(sliceStart, textLen)),
          style: span.style,
          recognizer: span.recognizer,
          semanticsLabel: span.semanticsLabel,
        ),
      );
    }

    // Caratteri compresi nella selezione (stile originale + backgroundColor)
    final int hlStart = math.max(0, math.min(sliceStart, textLen));
    final int hlEnd = math.max(hlStart, math.min(sliceEnd, textLen));
    if (hlEnd > hlStart) {
      out.add(
        TextSpan(
          text: text.substring(hlStart, hlEnd),
          style: (span.style ?? const TextStyle()).copyWith(
            backgroundColor: highlightColor,
          ),
          recognizer: span.recognizer,
          semanticsLabel: span.semanticsLabel,
        ),
      );
    }

    // Caratteri dopo la selezione (stile originale senza sfondo)
    if (sliceEnd < textLen) {
      out.add(
        TextSpan(
          text: text.substring(math.max(0, sliceEnd)),
          style: span.style,
          recognizer: span.recognizer,
          semanticsLabel: span.semanticsLabel,
        ),
      );
    }

    return out;
  }

  // Caso 2: Container TextSpan (solo figli stilizzati, nessun testo diretto)
  if (textLen == 0 && hasChildren) {
    final List<InlineSpan> slicedChildren = sliceInlineSpans(
      spans: span.children!,
      start: sliceStart,
      end: sliceEnd,
      highlightColor: highlightColor,
    );
    return [
      TextSpan(
        children: slicedChildren,
        style: span.style,
        recognizer: span.recognizer,
        semanticsLabel: span.semanticsLabel,
      ),
    ];
  }

  // Caso 3: TextSpan con sia testo diretto sia figli
  final List<InlineSpan> out = [];

  final int textSliceStart = math.max(0, math.min(textLen, sliceStart));
  final int textSliceEnd = math.max(0, math.min(textLen, sliceEnd));

  if (textSliceStart < textSliceEnd) {
    if (textSliceStart > 0) {
      out.add(
        TextSpan(
          text: text.substring(0, textSliceStart),
          style: span.style,
          recognizer: span.recognizer,
        ),
      );
    }
    out.add(
      TextSpan(
        text: text.substring(textSliceStart, textSliceEnd),
        style: (span.style ?? const TextStyle()).copyWith(
          backgroundColor: highlightColor,
        ),
        recognizer: span.recognizer,
      ),
    );
    if (textSliceEnd < textLen) {
      out.add(
        TextSpan(
          text: text.substring(textSliceEnd),
          style: span.style,
          recognizer: span.recognizer,
        ),
      );
    }
  } else {
    out.add(
      TextSpan(
        text: text,
        style: span.style,
        recognizer: span.recognizer,
      ),
    );
  }

  final int childSliceStart = math.max(0, sliceStart - textLen);
  final int childSliceEnd = math.max(0, sliceEnd - textLen);
  final List<InlineSpan> slicedChildren = sliceInlineSpans(
    spans: span.children!,
    start: childSliceStart,
    end: childSliceEnd,
    highlightColor: highlightColor,
  );
  out.addAll(slicedChildren);

  return out;
}

/// Funzione helper pura per lo slicing millimetrico di una lista di [InlineSpan].
///
/// Riceve la lista o l'albero di [InlineSpan] e l'intervallo locale `[start, end)`.
/// - I caratteri prima di [start]: mantengono lo stile originale senza sfondo.
/// - I caratteri compresi tra [start] e [end): stile originale + [highlightColor].
/// - I caratteri dopo [end]: mantengono lo stile originale senza sfondo.
List<InlineSpan> sliceInlineSpans({
  required List<InlineSpan> spans,
  required int start,
  required int end,
  required Color highlightColor,
}) {
  if (spans.isEmpty || start >= end) {
    return spans;
  }

  final int totalLength = computeSpansLength(spans);
  final int clampedStart = math.max(0, math.min(start, totalLength));
  final int clampedEnd = math.max(clampedStart, math.min(end, totalLength));

  if (clampedStart >= clampedEnd) {
    return spans;
  }

  final List<InlineSpan> result = [];
  int currentOffset = 0;

  for (final span in spans) {
    final int spanLen = computeSpanLength(span);
    final int spanStart = currentOffset;
    final int spanEnd = currentOffset + spanLen;
    currentOffset = spanEnd;

    // Caso A: Lo span è interamente prima o interamente dopo la selezione
    if (spanEnd <= clampedStart || spanStart >= clampedEnd) {
      result.add(span);
    }
    // Caso B: Lo span è interamente contenuto nella selezione
    else if (spanStart >= clampedStart && spanEnd <= clampedEnd) {
      result.add(applyHighlightToSpan(span, highlightColor));
    }
    // Caso C: Lo span è parzialmente intersecato
    else {
      final int localSliceStart = math.max(0, clampedStart - spanStart);
      final int localSliceEnd = math.min(spanLen, clampedEnd - spanStart);
      result.addAll(
        _sliceSingleSpan(
          span,
          localSliceStart,
          localSliceEnd,
          highlightColor,
        ),
      );
    }
  }

  return result;
}

/// Helper per sezionare direttamente una stringa di testo puro in [InlineSpan] evidenziati.
List<InlineSpan> sliceTextToSpans({
  required String text,
  required int start,
  required int end,
  required TextStyle normalStyle,
  required Color highlightColor,
}) {
  return sliceInlineSpans(
    spans: [TextSpan(text: text, style: normalStyle)],
    start: start,
    end: end,
    highlightColor: highlightColor,
  );
}

/// Rendering di un blocco di testo ([ParagraphNode] o [HeadingNode]) con selezione
/// millimetrica basata su [BlockSelectionIntersection].
class ParagraphBlockWidget extends StatelessWidget {
  /// Il nodo AST da renderizzare. Supporta sia [ParagraphNode] che [HeadingNode].
  final dynamic node;

  /// Stili globali e foglio di stile Markdown per il blocco.
  final MarkdownBlockStyle style;

  /// Intersezione tra la selezione del documento e questo blocco.
  final BlockSelectionIntersection intersection;

  const ParagraphBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.intersection = BlockSelectionIntersection.none,
  });

  /// Restituisce il testo raw del nodo AST.
  String get blockText => (node as dynamic).text as String? ?? '';

  /// Restituisce il nodo castato a [ParagraphNode] se compatibile.
  ParagraphNode? get paragraphNode =>
      node is ParagraphNode ? node as ParagraphNode : null;

  /// Restituisce il nodo castato a [HeadingNode] se compatibile.
  HeadingNode? get headingNode =>
      node is HeadingNode ? node as HeadingNode : null;

  /// Risolve lo stile tipografico dei titoli (h1..h6) preservando le dimensioni.
  TextStyle _resolveHeadingStyle(int level, BuildContext context) {
    final TextStyle? sheetStyle;
    switch (level) {
      case 1:
        sheetStyle = style.styleSheet.h1;
        break;
      case 2:
        sheetStyle = style.styleSheet.h2;
        break;
      case 3:
        sheetStyle = style.styleSheet.h3;
        break;
      case 4:
        sheetStyle = style.styleSheet.h4;
        break;
      case 5:
        sheetStyle = style.styleSheet.h5;
        break;
      case 6:
        sheetStyle = style.styleSheet.h6;
        break;
      default:
        sheetStyle = style.styleSheet.h1;
        break;
    }

    if (sheetStyle != null) {
      return sheetStyle;
    }

    final textTheme = Theme.of(context).textTheme;
    switch (level) {
      case 1:
        return textTheme.headlineLarge ??
            TextStyle(fontSize: style.fontSize * 2.0, fontWeight: FontWeight.bold);
      case 2:
        return textTheme.headlineMedium ??
            TextStyle(fontSize: style.fontSize * 1.7, fontWeight: FontWeight.bold);
      case 3:
        return textTheme.headlineSmall ??
            TextStyle(fontSize: style.fontSize * 1.4, fontWeight: FontWeight.bold);
      case 4:
        return textTheme.titleLarge ??
            TextStyle(fontSize: style.fontSize * 1.2, fontWeight: FontWeight.bold);
      case 5:
        return textTheme.titleMedium ??
            TextStyle(fontSize: style.fontSize * 1.1, fontWeight: FontWeight.bold);
      case 6:
      default:
        return textTheme.titleSmall ??
            TextStyle(fontSize: style.fontSize * 1.0, fontWeight: FontWeight.bold);
    }
  }

  /// Risolve lo stile base di default (paragrafo o heading).
  TextStyle _resolveBaseStyle(BuildContext context) {
    if (node is HeadingNode) {
      int level = 1;
      try {
        level = (node as dynamic).level as int;
      } catch (_) {
        try {
          level = (node as dynamic).depth as int;
        } catch (_) {
          level = 1;
        }
      }
      return _resolveHeadingStyle(level, context);
    }

    return style.styleSheet.p ??
        Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: style.fontSize,
            ) ??
        TextStyle(fontSize: style.fontSize);
  }

  /// Converte i nodi Markdown generati da [md.Document.parseInline] in [InlineSpan] stilizzati.
  List<InlineSpan> _buildSpansFromMarkdownNodes({
    required List<md.Node> nodes,
    required TextStyle currentStyle,
    required BuildContext context,
    GestureRecognizer? recognizer,
  }) {
    final List<InlineSpan> spans = [];

    for (final node in nodes) {
      if (node is md.Text) {
        if (node.text.isNotEmpty) {
          spans.add(
            TextSpan(
              text: node.text,
              style: currentStyle,
              recognizer: recognizer,
            ),
          );
        }
      } else if (node is md.Element) {
        final String tag = node.tag.toLowerCase();

        TextStyle childStyle = currentStyle;
        GestureRecognizer? childRecognizer = recognizer;

        switch (tag) {
          case 'strong':
          case 'b':
            childStyle = childStyle.merge(
              style.styleSheet.strong ??
                  const TextStyle(fontWeight: FontWeight.bold),
            );
            break;

          case 'em':
          case 'i':
            childStyle = childStyle.merge(
              style.styleSheet.em ??
                  const TextStyle(fontStyle: FontStyle.italic),
            );
            break;

          case 'del':
          case 's':
            childStyle = childStyle.merge(
              style.styleSheet.del ??
                  const TextStyle(decoration: TextDecoration.lineThrough),
            );
            break;

          case 'code':
            childStyle = childStyle.merge(
              style.inlineCodeStyle ??
                  style.styleSheet.code ??
                  TextStyle(
                    fontFamily: 'monospace',
                    fontSize: style.fontSize,
                  ),
            );
            break;

          case 'a':
            childStyle = childStyle.merge(
              style.styleSheet.a ??
                  TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
            );
            final String? href = node.attributes['href'];
            if (href != null && href.isNotEmpty) {
              childRecognizer = TapGestureRecognizer()
                ..onTap = () async {
                  final uri = Uri.tryParse(href);
                  if (uri != null && await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                };
            }
            break;

          case 'br':
            spans.add(TextSpan(text: '\n', style: currentStyle));
            continue;

          default:
            break;
        }

        if (node.children != null && node.children!.isNotEmpty) {
          spans.addAll(
            _buildSpansFromMarkdownNodes(
              nodes: node.children!,
              currentStyle: childStyle,
              context: context,
              recognizer: childRecognizer,
            ),
          );
        } else {
          final String textContent = node.textContent;
          if (textContent.isNotEmpty) {
            spans.add(
              TextSpan(
                text: textContent,
                style: childStyle,
                recognizer: childRecognizer,
              ),
            );
          }
        }
      }
    }

    return spans;
  }

  /// Esegue il parsing sicuro della stringa raw in [InlineSpan], con fallback
  /// automatico a [TextSpan] piatto in caso di eccezioni.
  List<InlineSpan> _parseInlineSpans({
    required String rawText,
    required TextStyle baseStyle,
    required BuildContext context,
  }) {
    if (rawText.isEmpty) {
      return const [];
    }

    try {
      final document = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      );
      final nodes = document.parseInline(rawText);
      final spans = _buildSpansFromMarkdownNodes(
        nodes: nodes,
        currentStyle: baseStyle,
        context: context,
      );
      if (spans.isNotEmpty) {
        return spans;
      }
    } catch (_) {
      // Fallback trasparente su testo puro in caso di errore nel parser Markdown
    }

    return [TextSpan(text: rawText, style: baseStyle)];
  }

  @override
  Widget build(BuildContext context) {
    final String rawText = blockText;
    final TextStyle baseStyle = _resolveBaseStyle(context);

    // Gestione paragrafo vuoto (preserva la line height standard)
    if (rawText.isEmpty) {
      final highlightColor =
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.28);
      final TextStyle emptyStyle = intersection.type == SelectionType.full
          ? baseStyle.copyWith(backgroundColor: highlightColor)
          : baseStyle;

      return Text.rich(
        TextSpan(
          text: ' ',
          style: emptyStyle,
        ),
      );
    }

    // Parsing degli InlineSpan (grassetto, corsivo, codice, link)
    final List<InlineSpan> originalSpans = _parseInlineSpans(
      rawText: rawText,
      baseStyle: baseStyle,
      context: context,
    );

    // Caso 1: Nessuna selezione
    if (intersection.type == SelectionType.none) {
      return Text.rich(
        TextSpan(
          children: originalSpans,
          style: baseStyle,
        ),
      );
    }

    final highlightColor =
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.28);

    // Caso 2: Selezione completa
    if (intersection.type == SelectionType.full) {
      final highlightedSpans = applyHighlightToSpans(originalSpans, highlightColor);
      return Text.rich(
        TextSpan(
          children: highlightedSpans,
          style: baseStyle.copyWith(backgroundColor: highlightColor),
        ),
      );
    }

    // Caso 3: Selezione parziale millimetrica
    final List<InlineSpan> slicedSpans = sliceInlineSpans(
      spans: originalSpans,
      start: intersection.localStart,
      end: intersection.localEnd,
      highlightColor: highlightColor,
    );

    return Text.rich(
      TextSpan(
        children: slicedSpans,
        style: baseStyle,
      ),
    );
  }
}