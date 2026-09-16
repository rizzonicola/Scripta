import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextSelection;

import '../../../models/markdown_ast_nodes.dart';

/// FASE 4 — Selezione Visiva Virtualizzata sui Blocchi.
///
/// Stato di evidenziazione LOCALE di un singolo blocco (o di un nodo
/// annidato, es. un item di lista o un figlio di blockquote), derivato
/// dall'intersezione fra il range coperto dal nodo nel sorgente
/// (`node.startOffset`..`node.endOffset`) e la selezione logica corrente
/// esposta da `MarkdownSelectionController.logicalSourceSelection`
/// (anch'essa espressa in offset del sorgente Markdown completo, vedi
/// Fase 3 — `MarkdownSelectionSourceMapper`).
///
/// Questo è ciò che permette a un blocco appena istanziato da
/// `ListView.builder` (perché entrato nel viewport durante uno scroll a
/// selezione già attiva) di sapere IMMEDIATAMENTE, alla sua prima
/// `build`, se deve apparire evidenziato — senza dover attendere che la
/// geometria di selezione nativa di `SelectableRegion` si sincronizzi
/// con un `RenderObject` appena registrato (sincronizzazione che, per i
/// widget di nuova registrazione dopo che una selezione è già stata
/// stabilita — es. dopo "Seleziona Tutto" o durante lo scroll con un
/// trascinamento esteso — Flutter non garantisce avvenga all'istante).
enum BlockSelectionState {
  /// Il blocco non è toccato dalla selezione corrente.
  none,

  /// Il blocco è toccato dalla selezione solo in parte: uno dei due
  /// estremi della selezione cade ALL'INTERNO del range del blocco. Sono
  /// tipicamente, al più, i due blocchi "di bordo" di un trascinamento
  /// (quello in cui l'utente ha iniziato/terminato il gesto): restano
  /// sempre montati/vicini al viewport per tutta la durata
  /// dell'interazione (è li che si trova il puntatore), quindi non sono
  /// soggetti al problema di virtualizzazione che questa fase risolve —
  /// la resa pixel-per-pixel della loro evidenziazione PARZIALE resta
  /// quindi intenzionalmente a carico del meccanismo nativo, già
  /// corretto in quel caso, di `SelectableRegion`.
  partial,

  /// Il blocco ricade PER INTERO dentro l'intervallo di selezione:
  /// questo è esattamente il caso che la virtualizzazione può "perdere"
  /// quando il blocco viene (ri)montato mentre la selezione è già
  /// attiva. Il renderer applica qui un'evidenziazione esplicita,
  /// calcolata ad ogni build da questo stesso file — quindi corretta fin
  /// dal primo frame in cui il blocco esiste, indipendentemente da cosa
  /// stia facendo `SelectableRegion` nel frattempo.
  full,
}

@immutable
class BlockVisualSelection {
  final BlockSelectionState state;

  const BlockVisualSelection._(this.state);

  static const BlockVisualSelection none =
      BlockVisualSelection._(BlockSelectionState.none);
  static const BlockVisualSelection partial =
      BlockVisualSelection._(BlockSelectionState.partial);
  static const BlockVisualSelection full =
      BlockVisualSelection._(BlockSelectionState.full);

  bool get isNone => state == BlockSelectionState.none;
  bool get isPartial => state == BlockSelectionState.partial;
  bool get isFull => state == BlockSelectionState.full;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BlockVisualSelection && other.state == state);

  @override
  int get hashCode => state.hashCode;

  @override
  String toString() => 'BlockVisualSelection.$state';
}

/// Calcola lo stato di evidenziazione LOCALE di [node] a partire dalla
/// selezione logica corrente [logicalSelection] (offset nel sorgente
/// Markdown completo — vedi
/// `MarkdownSelectionController.logicalSourceSelection`).
///
/// **Costo: O(1)** — solo quattro confronti fra interi, MAI una
/// scansione del testo del nodo né tantomeno del documento. Pensata per
/// essere richiamata ad ogni `itemBuilder` di `ListView.builder` (quindi
/// potenzialmente decine di volte per frame durante uno scroll rapido)
/// senza alcun impatto misurabile sulle prestazioni.
BlockVisualSelection resolveBlockVisualSelection(
  MarkdownNode node,
  TextSelection? logicalSelection,
) {
  if (logicalSelection == null || !logicalSelection.isValid) {
    return BlockVisualSelection.none;
  }

  final selStart = logicalSelection.start;
  final selEnd = logicalSelection.end;
  if (selStart == selEnd) return BlockVisualSelection.none;

  final nodeStart = node.startOffset;
  final nodeEnd = node.endOffset;

  // Nessuna sovrapposizione fra i due intervalli.
  if (selEnd <= nodeStart || selStart >= nodeEnd) {
    return BlockVisualSelection.none;
  }

  // Il nodo ricade per intero nell'intervallo selezionato.
  if (selStart <= nodeStart && selEnd >= nodeEnd) {
    return BlockVisualSelection.full;
  }

  return BlockVisualSelection.partial;
}

/// Wrapper riutilizzabile: applica uno sfondo di evidenziazione a [child]
/// SOLO quando [visualSelection] è `full` — nessun costo aggiuntivo
/// (nessun `Container` extra nell'albero) negli altri due stati, dato
/// che la stragrande maggioranza dei blocchi visibili in un documento
/// non toccato dalla selezione corrente deve restituire esattamente
/// [child] così com'è.
class BlockSelectionHighlight extends StatelessWidget {
  final BlockVisualSelection visualSelection;
  final Color color;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final Widget child;

  const BlockSelectionHighlight({
    super.key,
    required this.visualSelection,
    required this.color,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(4)),
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    if (!visualSelection.isFull) return child;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(color: color, borderRadius: borderRadius),
      child: child,
    );
  }
}
