import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/editor/domain/models/markdown_selection_range.dart';
import 'package:scripta/features/editor/models/markdown_ast_nodes.dart';
import 'package:scripta/features/editor/presentation/widgets/blocks/markdown_block_style.dart';
import 'package:scripta/features/editor/presentation/widgets/blocks/table_block_widget.dart';

void main() {
  group('TableBlockWidget Selection Tests', () {
    late TableBlockNode tableNode;
    late MarkdownBlockStyle blockStyle;

    setUp(() {
      tableNode = const TableBlockNode(
        startOffset: 0,
        endOffset: 60,
        children: [],
        attributes: {
          'headers': ['Header 1', 'Header 2'],
          'rows': [
            ['Cell A1', 'Cell A2'],
            ['Cell B1', 'Cell B2'],
          ],
          'alignments': [TableColumnAlignment.left, TableColumnAlignment.left],
          'columnCount': 2,
        },
      );

      final theme = ThemeData(
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 14),
        ),
      );
      final styleSheet = MarkdownStyleSheet.fromTheme(theme);
      blockStyle = MarkdownBlockStyle(
        styleSheet: styleSheet,
        inlineCodeStyle: const TextStyle(fontFamily: 'monospace'),
        titleTextStyle: const TextStyle(fontSize: 24),
        fontFamily: 'sans-serif',
        fontSize: 16.0,
        isDark: false,
        primaryColor: Colors.blue,
        onSurfaceColor: Colors.black,
        outlineColor: Colors.grey,
      );
    });

    testWidgets('Renders all cells unhighlighted when no intersection', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableBlockWidget(
              node: tableNode,
              style: blockStyle,
              intersection: BlockSelectionIntersection.none,
            ),
          ),
        ),
      );

      expect(find.text('Header 1'), findsOneWidget);
      expect(find.text('Header 2'), findsOneWidget);
      expect(find.text('Cell A1'), findsOneWidget);
      expect(find.text('Cell A2'), findsOneWidget);

      // Verify no Text.rich with highlight background exists
      final textWidgets = tester.widgetList<Text>(find.byType(Text));
      for (final widget in textWidgets) {
        if (widget.textSpan != null) {
          final span = widget.textSpan! as TextSpan;
          expect(span.style?.backgroundColor, isNull);
        }
      }
    });

    testWidgets('Highlights only intersected cell when partial intersection occurs', (tester) async {
      // Intersecting first cell only: localStart: 0, localEnd: 8
      const partialIntersection = BlockSelectionIntersection(
        type: SelectionType.partial,
        localStart: 0,
        localEnd: 8,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableBlockWidget(
              node: tableNode,
              style: blockStyle,
              intersection: partialIntersection,
            ),
          ),
        ),
      );

      // Header 1 should have highlighted rich text
      final richTexts = tester.widgetList<RichText>(find.byType(RichText));
      bool foundHighlight = false;

      for (final rich in richTexts) {
        final textSpan = rich.text as TextSpan;
        textSpan.visitChildren((span) {
          if (span.style?.backgroundColor != null) {
            foundHighlight = true;
          }
          return true;
        });
      }

      expect(foundHighlight, isTrue);

      // Cells further down like 'Cell B2' should NOT have highlights
      expect(find.text('Cell B2'), findsOneWidget);
    });
  });
}
