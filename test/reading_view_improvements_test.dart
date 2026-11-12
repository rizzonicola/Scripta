import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart' show ParseException;
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/editor/presentation/display_math_block.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';
import 'package:scripta/features/editor/presentation/note_scroll_memory.dart';
import 'package:scripta/features/editor/providers/note_search_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _kPhone = Size(400, 800);
const ValueKey<String> _kListKey = ValueKey<String>(
  'markdown-formatted-listview',
);

class _PlatformCalls {
  final List<String> methods = <String>[];
  String? clipboardText;
}

_PlatformCalls _mockPlatform(WidgetTester tester) {
  final calls = _PlatformCalls();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall methodCall) async {
      calls.methods.add(methodCall.method);
      if (methodCall.method == 'Clipboard.setData') {
        calls.clipboardText = (methodCall.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

Future<ProviderContainer> _pumpView(
  WidgetTester tester, {
  String title = 'Titolo',
  String content = 'Paragrafo con testo.',
  String? noteId,
  DateTime? updatedAt,
  int? wordCount,
  int? readingTimeMinutes,
  VoidCallback? onEdit,
  TextScaler? textScaler,
  Size size = _kPhone,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
        home: Scaffold(
          body: MarkdownRenderedView(
            title: title,
            content: content,
            noteId: noteId,
            updatedAt: updatedAt,
            wordCount: wordCount,
            readingTimeMinutes: readingTimeMinutes,
            onEdit: onEdit,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

ScrollableState _scrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(_kListKey),
            matching: find.byType(Scrollable),
          )
          .first,
    );

MarkdownSelectionScopeState _scope(WidgetTester tester) => tester
    .state<MarkdownSelectionScopeState>(find.byType(MarkdownSelectionScope));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(NoteScrollMemory.clear);

  testWidgets('lo stato vuoto è localizzato e passa alla modifica', (
    tester,
  ) async {
    var edited = false;
    await _pumpView(tester, content: '', onEdit: () => edited = true);

    expect(find.text('Nothing to read yet'), findsOneWidget);
    expect(find.text('Edit note'), findsOneWidget);

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(edited, isTrue);
  });

  testWidgets('il footer mostra parole, minuti e data di modifica', (
    tester,
  ) async {
    await _pumpView(
      tester,
      content: 'Una nota con qualche parola.',
      updatedAt: DateTime(2026, 3, 14),
      wordCount: 12,
      readingTimeMinutes: 1,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('rendered-meta-footer')),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(_kListKey),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('12 words · 1 min'), findsOneWidget);
    expect(find.textContaining('Updated'), findsOneWidget);
  });

  testWidgets('il testo rispetta la scala di testo di sistema', (tester) async {
    const scaler = TextScaler.linear(1.8);
    await _pumpView(tester, textScaler: scaler);

    final markdownTheme = tester.widget<MarkdownTheme>(
      find.byType(MarkdownTheme),
    );
    expect(markdownTheme.data.textScaler, scaler);
  });

  testWidgets('i blocchi espongono il testo ai lettori di schermo', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpView(
      tester,
      content:
          '# Sezione\n\nParagrafo con testo.\n\n```dart\nvoid main() {}\n```',
    );

    expect(find.bySemanticsLabel(RegExp('Paragrafo con testo')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('void main')), findsWidgets);
    handle.dispose();
  });

  testWidgets('copia della selezione: solo il testo, non i pulsanti', (
    tester,
  ) async {
    final calls = _mockPlatform(tester);
    await _pumpView(
      tester,
      content:
          '# Sezione\n\nParagrafo con testo.\n\n```dart\nvoid main() {}\n```',
    );

    final scope = _scope(tester);
    scope.selectAll();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    unawaited(scope.copySelection());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(calls.clipboardText, isNotNull);
    expect(calls.clipboardText, contains('Paragrafo con testo'));
    expect(calls.clipboardText, contains('void main'));
    expect(calls.clipboardText, isNot(contains('Copy')));
    expect(calls.clipboardText, isNot(contains('dart')));
  });

  testWidgets('la ricerca in sola lettura evidenzia il testo reso', (
    tester,
  ) async {
    final container = await _pumpView(
      tester,
      content: 'prima alfa seconda ALFA',
    );
    container.read(noteSearchProvider.notifier)
      ..open()
      ..setQuery('alfa');
    await tester.pumpAndSettle();

    expect(container.read(renderedNoteSearchTotalProvider), 2);
    final scope = _scope(tester);
    expect(scope.controller.getText(), 'alfa');
    expect(scope.toolbarIsVisible, isFalse);

    container.read(noteSearchProvider.notifier).nextMatch(2);
    await tester.pumpAndSettle();
    expect(scope.controller.getText(), 'ALFA');

    container.read(noteSearchProvider.notifier).close();
    await tester.pumpAndSettle();
    final selection = scope.controller.selection;
    expect(selection == null || selection.isCollapsed, isTrue);

    // Una query che esiste solo nel sorgente grezzo (i marker `**`) non è
    // un'occorrenza nel testo reso.
    container.read(noteSearchProvider.notifier)
      ..open()
      ..setQuery('**');
    await tester.pumpAndSettle();
    expect(container.read(renderedNoteSearchTotalProvider), 0);
  });

  testWidgets('Spazio scorre la vista quando il focus è sul contenuto', (
    tester,
  ) async {
    final buffer = StringBuffer();
    for (var i = 0; i < 80; i++) {
      buffer.writeln(
        'Paragrafo numero $i con abbastanza testo per occupare spazio.\n',
      );
    }
    await _pumpView(tester, content: buffer.toString());

    final focusWidget = tester
        .widgetList<Focus>(
          find.descendant(
            of: find.byType(MarkdownSelectionScope),
            matching: find.byType(Focus),
          ),
        )
        .firstWhere((focus) => focus.focusNode != null);
    focusWidget.focusNode!.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_scrollable(tester).position.pixels, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(_scrollable(tester).position.pixels, 0);
  });

  testWidgets('sui telefoni l’indice flottante non copre il testo', (
    tester,
  ) async {
    await _pumpView(
      tester,
      content: '# Prima sezione\n\nTesto.\n\n## Seconda sezione\n\nAltro.',
    );

    expect(find.byIcon(Icons.toc_rounded), findsNothing);
  });

  testWidgets('sugli schermi larghi il torna in cima resta disponibile', (
    tester,
  ) async {
    final buffer = StringBuffer('# Sezione\n\n');
    for (var i = 0; i < 60; i++) {
      buffer.writeln('Paragrafo $i con abbastanza testo per scorrere.\n');
    }
    await _pumpView(
      tester,
      content: buffer.toString(),
      size: const Size(900, 800),
    );

    expect(find.byIcon(Icons.vertical_align_top_rounded), findsNothing);

    await tester.drag(find.byKey(_kListKey), const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.vertical_align_top_rounded), findsOneWidget);
    expect(_scrollable(tester).position.pixels, greaterThan(480));

    await tester.tap(find.byIcon(Icons.vertical_align_top_rounded));
    await tester.pumpAndSettle();

    expect(_scrollable(tester).position.pixels, 0);
    expect(find.byIcon(Icons.vertical_align_top_rounded), findsNothing);
  });

  testWidgets('sui telefoni il torna in cima non copre il testo', (
    tester,
  ) async {
    final buffer = StringBuffer('# Sezione\n\n');
    for (var i = 0; i < 60; i++) {
      buffer.writeln('Paragrafo $i con abbastanza testo per scorrere.\n');
    }
    await _pumpView(tester, content: buffer.toString());

    await tester.drag(find.byKey(_kListKey), const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(_scrollable(tester).position.pixels, greaterThan(480));
    expect(find.byIcon(Icons.vertical_align_top_rounded), findsNothing);
    expect(find.byIcon(Icons.toc_rounded), findsNothing);
  });

  testWidgets('l’indice elenca i titoli e porta al blocco scelto', (
    tester,
  ) async {
    final buffer = StringBuffer('# Prima sezione\n\n');
    for (var i = 0; i < 60; i++) {
      buffer.writeln('Paragrafo $i con testo sufficiente.\n');
    }
    buffer.writeln('## Seconda sezione\n\nUltimo paragrafo.\n');
    await _pumpView(
      tester,
      content: buffer.toString(),
      size: const Size(900, 800),
    );

    await tester.tap(find.byIcon(Icons.toc_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Outline'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Prima sezione'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Seconda sezione'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, 'Seconda sezione'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(_scrollable(tester).position.pixels, greaterThan(0));
  });

  testWidgets('la posizione di lettura viene salvata e ripristinata', (
    tester,
  ) async {
    final buffer = StringBuffer();
    for (var i = 0; i < 80; i++) {
      buffer.writeln(
        'Paragrafo numero $i con abbastanza testo per creare altezza.\n',
      );
    }
    final content = buffer.toString();
    await _pumpView(tester, content: content, noteId: 'nota-ripristino');
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(_kListKey), const Offset(0, -700));
    await tester.pumpAndSettle();

    final savedOffset = NoteScrollMemory.sourceOffsetFor('nota-ripristino');
    final savedPixels = _scrollable(tester).position.pixels;
    expect(savedOffset, isNotNull);
    expect(savedOffset, greaterThan(0));
    expect(savedPixels, greaterThan(0));

    // Smonta e rimonta la vista: la nuova istanza deve leggere l'ancora
    // lasciata dalla precedente, non ripartire da zero.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpView(tester, content: content, noteId: 'nota-ripristino');
    await tester.pumpAndSettle();

    expect(_scrollable(tester).position.pixels, closeTo(savedPixels, 12));
  });

  testWidgets('il fallback TeX è localizzato e copia il sorgente', (
    tester,
  ) async {
    final calls = _mockPlatform(tester);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DisplayMathBlock(
            tex: r'\frac{incompleta',
            textStyle: const TextStyle(fontSize: 16),
            parseError: ParseException('bad'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('TeX syntax error'), findsOneWidget);
    expect(find.text(r'\frac{incompleta', findRichText: true), findsOneWidget);

    await tester.tap(find.byIcon(Icons.content_copy_rounded));
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls.clipboardText, r'\frac{incompleta');
    expect(find.text('LaTeX copied'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1700));
    expect(find.text('LaTeX copied'), findsNothing);
  });

  test('la memoria delle posizioni è LRU e limitata', () {
    NoteScrollMemory.clear();
    for (var i = 0; i < NoteScrollMemory.maxEntries + 5; i++) {
      NoteScrollMemory.save('nota-$i', 100 + i);
    }
    expect(NoteScrollMemory.sourceOffsetFor('nota-0'), isNull);
    expect(NoteScrollMemory.sourceOffsetFor('nota-4'), isNull);
    expect(NoteScrollMemory.sourceOffsetFor('nota-5'), 105);
    expect(
      NoteScrollMemory.sourceOffsetFor(
        'nota-${NoteScrollMemory.maxEntries + 4}',
      ),
      100 + NoteScrollMemory.maxEntries + 4,
    );
  });

  test('la posizione in cima è un valore valido, non un valore assente', () {
    NoteScrollMemory.clear();
    NoteScrollMemory.save('nota-in-cima', 0);
    expect(NoteScrollMemory.sourceOffsetFor('nota-in-cima'), 0);
  });
}
