/// Stato e scorciatoie desktop per la selezione dell'editor Markdown.
///
/// Layer di presentation: incapsula la macchina a stati del gesto di
/// selezione (drag → commit), Word-Snap (long-press/double-tap), manipolazione
/// delle maniglie di selezione (handles), il comando "select all" e l'accesso
/// alla clipboard di sistema. Lo stato esposto contiene **solo offset
/// numerici**: il testo sorgente non risiede mai nel provider, viene
/// letto dal chiamante solo al momento dell'uso.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/markdown_selection_range.dart';

/// Provider dell'intervallo di selezione corrente dell'editor.
///
/// Consumo consigliato:
/// ```dart
/// final selection = ref.watch(markdownSelectionProvider);
/// // rebuild mirati (gli == delle mutazioni rendono le notifiche pulite):
/// final extremes = ref.watch(
///   markdownSelectionProvider.select((s) => (s.min, s.max)),
/// );
/// ```
final markdownSelectionProvider =
    NotifierProvider<MarkdownSelectionNotifier, MarkdownSelectionRange>(
  MarkdownSelectionNotifier.new,
);

/// Macchina a stati della selezione, espressa in soli offset.
///
/// Ciclo di vita del gesto:
/// `startSelection` → `updateSelection`* → `endSelection`.
/// Word-Snap: `selectWordAt(offset, fullText)`.
/// Regolazione fine: `updateStartHandle` / `updateEndHandle`.
///
/// Il valore sentinella [noSelection] (`collapsed(-1)`) rappresenta
/// l'assenza di selezione ed è l'**unico** stato con `isValid == false`:
/// i consumer discriminano "nessuna selezione" senza campi aggiuntivi.
class MarkdownSelectionNotifier extends Notifier<MarkdownSelectionRange> {
  /// Pattern Unicode per spazi bianchi (`\s`, `\n`) e delimitatori/punteggiatura.
  static final RegExp _separatorRegex = RegExp(
    r'[\s\p{P}\p{S}]',
    unicode: true,
  );

  /// Stato iniziale / di riposo: caret sentinella a offset `-1`.
  ///
  /// Pubblico per confronti (`state == MarkdownSelectionNotifier.noSelection`)
  /// e per reset deterministici nei test.
  static const MarkdownSelectionRange noSelection =
      MarkdownSelectionRange.collapsed(-1);

  @override
  MarkdownSelectionRange build() => noSelection;

  /// Inizia un gesto di selezione (pointer down) ancorando entrambe le
  /// estremità a [offset].
  ///
  /// Offset negativi (bug di hit-testing) vengono clampati a `0` per non
  /// produrre mai stati invalidi.
  void startSelection(int offset) {
    final int safeOffset = math.max(0, offset);
    final MarkdownSelectionRange next = MarkdownSelectionRange(
      start: safeOffset,
      end: safeOffset,
      isSelecting: true,
    );
    if (next == state) return;
    state = next;
  }

  /// Aggiorna l'estremità mobile durante il drag.
  ///
  /// No-op se non esiste ancora un'ancora valida (stato sentinella): un
  /// `pointer move` spurio non può creare range con `start = -1`.
  /// La direzione del drag è irrilevante: è il modello a normalizzare
  /// con `min`/`max`.
  ///
  /// È anche il percorso programmatico per costruire una selezione:
  /// `startSelection(a); updateSelection(b); endSelection();`.
  void updateSelection(int currentOffset) {
    if (!state.isValid) return;
    final int safeOffset = math.max(0, currentOffset);
    if (state.end == safeOffset) return; // nessun cambiamento reale
    state = state.copyWith(end: safeOffset);
  }

  /// Conclude il gesto (pointer up): congela gli estremi.
  void endSelection() {
    if (!state.isSelecting) return;
    state = state.copyWith(isSelecting: false);
  }

  /// Aggiorna la posizione della maniglia iniziale (`start`) durante il drag,
  /// lasciando intatto [end].
  ///
  /// No-op se la selezione attuale non è valida. L'offset viene normalizzato
  /// per evitare valori negativi.
  void updateStartHandle(int newStartOffset) {
    if (!state.isValid) return;
    final int safeOffset = math.max(0, newStartOffset);
    if (state.start == safeOffset) return;
    state = state.copyWith(start: safeOffset);
  }

  /// Aggiorna la posizione della maniglia finale (`end`) durante il drag,
  /// lasciando intatto [start].
  ///
  /// No-op se la selezione attuale non è valida. L'offset viene normalizzato
  /// per evitare valori negativi.
  void updateEndHandle(int newEndOffset) {
    if (!state.isValid) return;
    final int safeOffset = math.max(0, newEndOffset);
    if (state.end == safeOffset) return;
    state = state.copyWith(end: safeOffset);
  }

  /// Seleziona automaticamente la parola o il token delimitatore sotto [offset]
  /// (Word-Snap), tipicamente scatenato da un long-press o double-tap.
  ///
  /// Logica di espansione:
  /// - Se [offset] è fuori limiti o il documento è vuoto, imposta un caret
  ///   sicuro e normalizzato (o no-op se già allineato).
  /// - Se [offset] cade su uno spazio (`\s`, `\n`) o un delimitatore sintattico,
  ///   seleziona unicamente quel carattere.
  /// - Se cade su un carattere alfabetico/parola, espande `wordStart` all'indietro
  ///   e `wordEnd` in avanti fino ai rispettivi separatori.
  void selectWordAt(int offset, String fullText) {
    if (fullText.isEmpty) {
      final MarkdownSelectionRange next = const MarkdownSelectionRange(
        start: 0,
        end: 0,
        isSelecting: false,
      );
      if (state == next) return;
      state = next;
      return;
    }

    if (offset < 0 || offset >= fullText.length) {
      final int safeCaretOffset = offset.clamp(0, fullText.length);
      final MarkdownSelectionRange next = MarkdownSelectionRange(
        start: safeCaretOffset,
        end: safeCaretOffset,
        isSelecting: false,
      );
      if (state == next) return;
      state = next;
      return;
    }

    int wordStart;
    int wordEnd;

    if (_isSeparator(fullText[offset])) {
      // Offset su spazio o delimitatore: seleziona il singolo carattere
      wordStart = offset;
      wordEnd = offset + 1;
    } else {
      // Cerca all'indietro fino al separatore precedente o all'inizio del testo
      wordStart = offset;
      while (wordStart > 0 && !_isSeparator(fullText[wordStart - 1])) {
        wordStart--;
      }

      // Cerca in avanti fino al primo separatore successivo o alla fine del testo
      wordEnd = offset + 1;
      while (wordEnd < fullText.length && !_isSeparator(fullText[wordEnd])) {
        wordEnd++;
      }
    }

    // Normalizzazione preventiva contro qualsiasi violazione di range
    final int safeStart = math.max(0, math.min(wordStart, fullText.length));
    final int safeEnd = math.max(safeStart, math.min(wordEnd, fullText.length));

    final MarkdownSelectionRange next = MarkdownSelectionRange(
      start: safeStart,
      end: safeEnd,
      isSelecting: false,
    );

    if (next == state) return;
    state = next;
  }

  /// Verifica se il carattere specificato corrisponde a uno spazio bianco
  /// (`\s`, `\n`, `\r`, `\t`) o a un delimitatore/simbolo (Markdown o punteggiatura).
  static bool _isSeparator(String char) {
    final int codeUnit = char.codeUnitAt(0);
    // Fast path: spazi bianchi ASCII e caratteri di controllo
    if (codeUnit <= 32 || codeUnit == 0x7F) return true;
    // Protezione per surrogate code units isolati (es. emoji multi-codeunit)
    if (codeUnit >= 0xD800 && codeUnit <= 0xDFFF) return false;
    return _separatorRegex.hasMatch(char);
  }

  /// Seleziona l'intero documento `[0, totalDocLength]`.
  ///
  /// Con `totalDocLength <= 0` degenera in un caret valido a `0`
  /// (selezione piena di lunghezza zero), mai in uno stato invalido.
  void selectAll(int totalDocLength) {
    final int safeLength = math.max(0, totalDocLength);
    final MarkdownSelectionRange next = MarkdownSelectionRange(
      start: 0,
      end: safeLength,
      isSelecting: false,
    );
    if (next == state) return;
    state = next;
  }

  /// Azzera la selezione tornando alla sentinella [noSelection].
  void clearSelection() {
    if (state == noSelection) return;
    state = noSelection;
  }

  /// Copia negli appunti di sistema il testo selezionato.
  ///
  /// - Caret (`isCollapsed`) o stato invalido → no-op immediato.
  /// - Gli offset vengono clampati alla lunghezza effettiva di
  ///   [fullMarkdownSource] **prima** del `substring`: una selezione
  ///   rimasta stantìa dopo un edit che ha accorciato il documento non
  ///   può mai causare `RangeError`.
  ///
  /// Lo snapshot di `state` avviene prima del primo `await` e lo stato
  /// non è più toccato dopo la sospensione: il metodo resta sicuro anche
  /// se il provider viene smontato durante la scrittura negli appunti.
  Future<void> copySelectedText(String fullMarkdownSource) async {
    final MarkdownSelectionRange selection = state;

    if (selection.isCollapsed || !selection.isValid) return;

    final int docLength = fullMarkdownSource.length;
    final int start = math.min(selection.min, docLength);
    final int end = math.min(selection.max, docLength);

    if (start >= end) return; // selezione finita fuori dal documento

    final String selectedText = fullMarkdownSource.substring(start, end);
    await Clipboard.setData(ClipboardData(text: selectedText));
  }
}

/// Intent: copia la selezione corrente negli appunti (Ctrl+C / Cmd+C).
class CopyMarkdownSelectionIntent extends Intent {
  const CopyMarkdownSelectionIntent();
}

/// Intent: seleziona l'intero documento (Ctrl+A / Cmd+A).
class SelectAllMarkdownIntent extends Intent {
  const SelectAllMarkdownIntent();
}

/// Mappa attivatori → intent dell'editor.
///
/// `control` copre Windows/Linux, `meta` copre macOS; entrambe le
/// varianti restano attive su ogni piattaforma (su macOS risponde anche
/// Ctrl+C, utile in sessioni remote/VNC). `SingleActivator` richiede la
/// combinazione esatta: Ctrl+Shift+C non attiva la copia.
const Map<ShortcutActivator, Intent> kMarkdownSelectionShortcuts =
    <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyC, control: true):
      CopyMarkdownSelectionIntent(),
  SingleActivator(LogicalKeyboardKey.keyC, meta: true):
      CopyMarkdownSelectionIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, control: true):
      SelectAllMarkdownIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      SelectAllMarkdownIntent(),
};

/// Installa le scorciatoie desktop (Ctrl/Cmd+C, Ctrl/Cmd+A) sopra un
/// sottoalbero dell'editor.
///
/// Gli intent vengono risolti quando il focus si trova in un qualsiasi
/// nodo discendente (es. la superficie dell'editor): gli eventi tastiera
/// risalgono per bubbling fino al `FocusNode` interno di [Shortcuts].
/// Con [autofocus] a `true` le scorciatoie sono vive anche senza un
/// focus interno esplicito; per una copertura a livello di app, montare
/// questo wrapper più in alto nell'albero (es. sopra lo `Scaffold`).
///
/// Il sorgente non viene passato per valore (eviterebbe rebuild a ogni
/// keystroke e duplicherebbe il testo) ma come callback [documentSource]
/// invocata solo al momento della combinazione: lo stato della selezione
/// resta composto da soli offset interi.
///
/// Su mobile il widget è inerte (niente tastiera fisica): gli stessi
/// comandi restano invocabili dal notifier, es. da una toolbar
/// contestuale con "Copia" / "Seleziona tutto".
class MarkdownSelectionShortcuts extends ConsumerStatefulWidget {
  const MarkdownSelectionShortcuts({
    super.key,
    required this.child,
    required this.documentSource,
    this.focusNode,
    this.autofocus = false,
  });

  final Widget child;

  /// Restituisce il markdown sorgente corrente e completo,
  /// es. `() => ref.read(markdownDocumentProvider).plainText`.
  final String Function() documentSource;

  /// FocusNode dedicato all'ascolto delle combinazioni; se `null` ne
  /// viene creato e disposto uno internamente.
  final FocusNode? focusNode;

  /// Se `true`, richiede il focus all'avvio così le scorciatoie
  /// funzionano anche quando nessun nodo interno è focalizzato.
  final bool autofocus;

  @override
  ConsumerState<MarkdownSelectionShortcuts> createState() =>
      _MarkdownSelectionShortcutsState();
}

class _MarkdownSelectionShortcutsState
    extends ConsumerState<MarkdownSelectionShortcuts> {
  // Creato solo se il chiamante non ne fornisce uno: ownership = dispose.
  late final FocusNode _ownedFocusNode =
      FocusNode(debugLabel: 'MarkdownSelectionShortcuts');

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _ownedFocusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // watch del *notifier* (non dello stato): il widget non si rebuilda
    // durante il drag, solo se l'istanza del notifier cambia.
    final MarkdownSelectionNotifier notifier =
        ref.watch(markdownSelectionProvider.notifier);

    // `Shortcuts` non espone `focusNode`/`autofocus` (li accetta solo
    // `Focus`): l'ascolto delle combinazioni tastiera richiede quindi un
    // `Focus` esplicito attorno a `Shortcuts`, che si limita a mappare le
    // combinazioni indipendentemente da come il focus viene gestito.
    final FocusNode effectiveFocusNode = widget.focusNode ?? _ownedFocusNode;

    return Focus(
      focusNode: effectiveFocusNode,
      autofocus: widget.autofocus,
      child: Shortcuts(
        debugLabel: 'MarkdownSelectionShortcuts',
        shortcuts: kMarkdownSelectionShortcuts,
        child: Actions(
          actions: <Type, Action<Intent>>{
            CopyMarkdownSelectionIntent:
                CallbackAction<CopyMarkdownSelectionIntent>(
              onInvoke: (_) {
                // Fire-and-forget: la clipboard non restituisce esiti e lo
                // stato non viene più toccato dopo l'await interno.
                notifier.copySelectedText(widget.documentSource());
                return null;
              },
            ),
            SelectAllMarkdownIntent: CallbackAction<SelectAllMarkdownIntent>(
              onInvoke: (_) {
                notifier.selectAll(widget.documentSource().length);
                return null;
              },
            ),
          },
          child: widget.child,
        ),
      ),
    );
  }
}