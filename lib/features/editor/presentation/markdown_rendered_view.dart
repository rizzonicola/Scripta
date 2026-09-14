import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ============================================================================
// 1. MODELLO DI STATO DELLA SELEZIONE
// ============================================================================

abstract class BlockSelectionState {
  const BlockSelectionState();
}

/// Il blocco non è selezionato
class BlockSelectedNone extends BlockSelectionState {
  const BlockSelectedNone();
}

/// Il blocco è completamente selezionato (Zero calcoli di layout visivo)
class BlockSelectedFull extends BlockSelectionState {
  const BlockSelectedFull();
}

/// Il blocco contiene una o più selezioni parziali/disgiunte
class BlockSelectedPartial extends BlockSelectionState {
  final List<TextRange> ranges;
  const BlockSelectedPartial(this.ranges);
}

// ============================================================================
// 2. CONTROLLER LOGICO DELLA SELEZIONE (Headless Selection Controller)
// ============================================================================

class DocumentSelectionController extends ValueNotifier<Map<int, BlockSelectionState>> {
  DocumentSelectionController() : super({});

  bool get hasSelection => value.isNotEmpty && value.values.any((s) => s is! BlockSelectedNone);

  /// Seleziona tutto il documento in 0ms (imposta lo stato FULL su tutti i blocchi)
  void selectAll(int totalBlocks) {
    final newState = <int, BlockSelectionState>{};
    for (int i = 0; i < totalBlocks; i++) {
      newState[i] = const BlockSelectedFull();
    }
    value = newState;
  }

  /// Deseleziona tutto
  void clear() {
    value = {};
  }

  /// Aggiorna lo stato di un singolo blocco (es. deselezione manuale o dragging)
  void setBlockState(int index, BlockSelectionState state) {
    final newState = Map<int, BlockSelectionState>.from(value);
    if (state is BlockSelectedNone) {
      newState.remove(index);
    } else {
      newState[index] = state;
    }
    value = newState;
  }

  /// Estrae il testo selezionato bypassando completamente l'interfaccia visiva
  String getSelectedText(List<String> rawBlocks) {
    final buffer = StringBuffer();
    for (int i = 0; i < rawBlocks.length; i++) {
      final state = value[i] ?? const BlockSelectedNone();
      final text = rawBlocks[i];

      if (state is BlockSelectedFull) {
        buffer.writeln(text);
      } else if (state is BlockSelectedPartial) {
        for (final range in state.ranges) {
          final start = range.start.clamp(0, text.length);
          final end = range.end.clamp(0, text.length);
          if (start < end) {
            buffer.write(text.substring(start, end));
          }
        }
        buffer.writeln();
      }
    }
    return buffer.toString().trimRight();
  }

  /// Copia negli appunti di sistema
  Future<void> copyToClipboard(List<String> rawBlocks) async {
    final text = getSelectedText(rawBlocks);
    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }
}

// ============================================================================
// 3. WIDGET DEL BLOCCO DI RIGA (Optimized Block Item)
// ============================================================================

class MarkdownBlockItem extends StatelessWidget {
  final int index;
  final String rawText;
  final DocumentSelectionController selectionController;

  const MarkdownBlockItem({
    required Key key,
    required this.index,
    required this.rawText,
    required this.selectionController,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final selectionColor = Theme.of(context).primaryColor.withOpacity(0.25);

    return ValueListenableBuilder<Map<int, BlockSelectionState>>(
      valueListenable: selectionController,
      // Passiamo il rendering standard del Markdown come `child` pre-costruito per la massima resa
      child: _buildStandardMarkdownContent(rawText),
      builder: (context, selectionMap, cachedChild) {
        final state = selectionMap[index] ?? const BlockSelectedNone();

        // CASO 1: Tutto Selezionato -> Applica sfondo visivo ISTANTANEO (Zero overhead di testo)
        if (state is BlockSelectedFull) {
          return Container(
            color: selectionColor,
            width: double.infinity,
            child: cachedChild,
          );
        }

        // CASO 2: Selezione Parziale -> Renderizza evidenziando solo le selezioni specifiche
        if (state is BlockSelectedPartial) {
          return _buildPartialSelectionContent(context, state.ranges);
        }

        // CASO 3: Nessuna Selezione -> Renderizza il widget standard virtualizzato
        return cachedChild!;
      },
    );
  }

  /// Rendering base del Markdown per blocchi normali o completamente selezionati
  Widget _buildStandardMarkdownContent(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 12.0),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.black87),
      ),
    );
  }

  /// Rendering per intervalli parziali (es. selezioni trascinate o con tasto Ctrl)
  Widget _buildPartialSelectionContent(BuildContext context, List<TextRange> ranges) {
    final highlightColor = Theme.of(context).primaryColor.withOpacity(0.35);
    final spans = <TextSpan>[];
    int currentOffset = 0;

    // Ordina i range per sovrapporli correttamente
    final sortedRanges = List<TextRange>.from(ranges)
      ..sort((a, b) => a.start.compareTo(b.start));

    for (final range in sortedRanges) {
      final start = range.start.clamp(0, rawText.length);
      final end = range.end.clamp(0, rawText.length);

      if (start > currentOffset) {
        spans.add(TextSpan(text: rawText.substring(currentOffset, start)));
      }
      if (start < end) {
        spans.add(TextSpan(
          text: rawText.substring(start, end),
          style: TextStyle(backgroundColor: highlightColor),
        ));
      }
      currentOffset = end;
    }

    if (currentOffset < rawText.length) {
      spans.add(TextSpan(text: rawText.substring(currentOffset)));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 12.0),
      child: Text.rich(
        TextSpan(children: spans),
        style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.black87),
      ),
    );
  }
}

// ============================================================================
// 4. VISTA PRINCIPALE DEL DOCUMENTO (ListView Virtualizzata)
// ============================================================================

class OptimizedDocumentViewer extends StatefulWidget {
  final List<String> markdownBlocks;

  const OptimizedDocumentViewer({super.key, required this.markdownBlocks});

  @override
  State<OptimizedDocumentViewer> createState() => _OptimizedDocumentViewerState();
}

class _OptimizedDocumentViewerState extends State<OptimizedDocumentViewer> {
  late final DocumentSelectionController _selectionController;

  @override
  void initState() {
    super.initState();
    _selectionController = DocumentSelectionController();
  }

  @override
  void dispose() {
    _selectionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Viewer Markdown ad Alte Prestazioni'),
        actions: [
          IconButton(
            icon: const Icon(Icons.select_all),
            tooltip: 'Seleziona Tutto',
            onPressed: () {
              _selectionController.selectAll(widget.markdownBlocks.length);
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copia',
            onPressed: () async {
              await _selectionController.copyToClipboard(widget.markdownBlocks);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Testo copiato negli appunti!')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.clear),
            tooltip: 'Deseleziona',
            onPressed: () => _selectionController.clear(),
          ),
        ],
      ),
      body: ListView.builder(
        // Utilizzo del buffer standard di Flutter: performance ottimali guaranteed
        cacheExtent: 250.0,
        itemCount: widget.markdownBlocks.length,
        itemBuilder: (context, index) {
          return MarkdownBlockItem(
            key: ValueKey('block_$index'),
            index: index,
            rawText: widget.markdownBlocks[index],
            selectionController: _selectionController,
          );
        },
      ),
    );
  }
}
