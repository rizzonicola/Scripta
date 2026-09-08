import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';

class MarkdownEditorField extends ConsumerStatefulWidget {
  final TextEditingController titleController;
  final TextEditingController contentController;
  final UndoHistoryController? undoController;
  final ValueChanged<String>? onTitleChanged;
  final ValueChanged<String>? onContentChanged;

  const MarkdownEditorField({
    super.key,
    required this.titleController,
    required this.contentController,
    this.undoController,
    this.onTitleChanged,
    this.onContentChanged,
  });

  @override
  ConsumerState<MarkdownEditorField> createState() =>
      _MarkdownEditorFieldState();
}

/// Collega un singolo [TextEditingController] al gate globale di
/// [HapticsHelper].
///
/// STORIA DEL BUG (tre tentativi precedenti, tutti respinti):
/// I tentativi #1 (transizione istantanea `isCollapsed`), #2 (pointer
/// tracking via `Listener`, che non vede le maniglie perché disegnate in un
/// `OverlayEntry` separato) e #3 (`TextField.onSelectionChanged`, parametro
/// che il widget Material `TextField` non espone in questa versione
/// dell'SDK) provavano tutti a decidere ESPLICITAMENTE, dal nostro codice
/// Dart, quando emettere una vibrazione per l'intensità "light".
///
/// La causa radice per cui "Leggero" e "Disattivata" non funzionavano è
/// però un'altra, e nessuno di quei tentativi poteva risolverla: dalla PR
/// flutter/flutter#115373, il FRAMEWORK STESSO chiama
/// `HapticFeedback.vibrate()` in autonomia quando la selezione di un
/// `TextField` cambia (una volta alla creazione, e — su Android — ad ogni
/// variazione del range durante il trascinamento di una maniglia). Questa
/// chiamata nativa non passa MAI dal nostro `HapticsHelper`: qualunque cosa
/// (o nessuna cosa) il nostro codice facesse, il telefono vibrava comunque.
///
/// La correzione vera è quindi a livello di platform channel (vedi
/// `main.dart`, `_HapticGatingBinaryMessenger` + `HapticsHelper.
/// gateNativeHapticCall`), non nel controller. Il compito di questa classe
/// si riduce perciò a:
///  1. ignorare le notifiche dovute a digitazione di testo (non riguardano
///     la selezione "vera");
///  2. inoltrare lo stato `isCollapsed` corrente a
///     [HapticsHelper.reportSelectionState], che usa un debounce per
///     ri-armare il colpetto "light" solo dopo una vera fine-selezione (e
///     non su un attraversamento-zero momentaneo durante un trascinamento —
///     vedi la doc di quel metodo per il dettaglio);
///  3. per l'intensità "strong", richiamare esplicitamente
///     [HapticsHelper.selectionDragTick] ad ogni variazione del range
///     (garantisce il feedback continuo anche su iOS, dove il framework
///     vibra nativamente solo alla creazione della selezione).
class _SelectionHapticBinder {
  _SelectionHapticBinder(this._controller, this._getIntensity) {
    _lastText = _controller.text;
    _lastSelection = _controller.selection;
    _controller.addListener(_onValueChanged);
  }

  final TextEditingController _controller;
  final HapticIntensity Function() _getIntensity;
  late String _lastText;
  late TextSelection _lastSelection;

  void _onValueChanged() {
    final value = _controller.value;
    final textChanged = value.text != _lastText;
    _lastText = value.text;

    final selection = value.selection;
    // selection.isCollapsed è true anche per una TextSelection non valida
    // (offset == -1), quindi non serve un controllo separato su isValid.
    final isCollapsedNow = selection.isCollapsed;

    if (textChanged) {
      // La digitazione altera spesso anche la selezione (es. la collassa
      // sul nuovo cursore): aggiorniamo solo lo stato senza MAI considerarlo
      // inizio selezione da segnalare.
      _lastSelection = selection;
      HapticsHelper.reportSelectionState(isCollapsed: isCollapsedNow);
      return;
    }

    final selectionChanged = selection.start != _lastSelection.start ||
        selection.end != _lastSelection.end;

    HapticsHelper.reportSelectionState(isCollapsed: isCollapsedNow);

    // "Strong": ticchettio esplicito ad ogni variazione del range mentre si
    // trascina (vedi doc di classe per il perché serve anche in aggiunta
    // alla vibrazione nativa).
    if (selectionChanged && !isCollapsedNow) {
      HapticsHelper.selectionDragTick(_getIntensity());
    }

    _lastSelection = selection;
  }

  void dispose() {
    _controller.removeListener(_onValueChanged);
  }
}

class _MarkdownEditorFieldState extends ConsumerState<MarkdownEditorField> {
  late _SelectionHapticBinder _titleHaptics;
  late _SelectionHapticBinder _contentHaptics;

  /// Controller esplicito per la `SingleChildScrollView` esterna.
  ///
  /// CAUSA RADICE DEL BUG (asimmetria trascina-su vs trascina-giù nel
  /// ridimensionare una selezione esistente):
  /// Titolo e corpo condividono un unico `SingleChildScrollView` ancestor:
  /// il `TextField` del corpo (`maxLines: null`, senza altezza propria) non
  /// possiede una viewport interna, quindi durante il trascinamento di una
  /// maniglia di selezione `EditableText` chiede ripetutamente
  /// all'ancestor `Scrollable` di "portare in vista" l'estremo della
  /// selezione (`ensureVisible`). Questo, di per sé, non è il difetto: è il
  /// meccanismo standard e stabile che Flutter usa ovunque (anche un
  /// singolo `TextField` in una `ListView` funziona così).
  ///
  /// Il difetto è nel modo in cui la `SingleChildScrollView` interpreta il
  /// GESTO stesso. Senza un `dragStartBehavior` esplicito, il valore di
  /// default (`DragStartBehavior.start`) fa sì che il proprio
  /// `VerticalDragGestureRecognizer` campioni la posizione iniziale del
  /// trascinamento al primo movimento "significativo" del dito, non al
  /// tocco iniziale — un dettaglio che la documentazione ufficiale di
  /// Flutter segnala esplicitamente come problematico quando, come qui, un
  /// `GestureDetector`/recognizer annidato (quello privato della maniglia
  /// di selezione, gestito da `EditableText`) COMPETE nella stessa arena dei
  /// gesti per lo stesso puntatore. Il risultato è un primo delta di scroll
  /// calcolato su un punto di partenza diverso da quello realmente toccato
  /// dall'utente.
  /// Riprendere (tocca-e-trascina di nuovo) una selezione già esistente
  /// genera, rispetto a crearne una nuova, molti più micro-gesti di
  /// aggiustamento consecutivi (correzioni fini della maniglia), quindi
  /// molte più occasioni per questa ambiguità nell'arena dei gesti — da qui
  /// l'accumulo di scatti in avanti, il procedere a scatti e l'arresto
  /// prematuro osservati SOLO trascinando verso l'alto durante un
  /// ridimensionamento (verso il basso l'errore di campionamento iniziale è
  /// molto meno percepibile, perché il testo "va incontro" al dito).
  ///
  /// FIX: `DragStartBehavior.down` fa campionare la posizione al tocco
  /// iniziale (`PointerDownEvent`), eliminando il disallineamento — la
  /// stessa raccomandazione data nella doc ufficiale di
  /// `DragStartBehavior` proprio per il caso "testo selezionabile dentro
  /// uno scrollable". Nessuna modifica al layout: stesso identico albero di
  /// widget di prima.
  late final ScrollController _panelScrollController;

  @override
  void initState() {
    super.initState();
    _panelScrollController = ScrollController();
    _titleHaptics = _SelectionHapticBinder(
      widget.titleController,
      () => ref.read(settingsProvider).hapticIntensity,
    );
    _contentHaptics = _SelectionHapticBinder(
      widget.contentController,
      () => ref.read(settingsProvider).hapticIntensity,
    );
  }

  @override
  void didUpdateWidget(covariant MarkdownEditorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // I controller sono normalmente stabili per l'intera vita del pannello
    // editor (vedi note_editor_pane.dart), ma se mai venissero sostituiti
    // riattacchiamo i listener a quelli nuovi per evitare di restare agganciati
    // a controller ormai fuori uso (o, peggio, già disposti dal chiamante).
    if (oldWidget.titleController != widget.titleController) {
      _titleHaptics.dispose();
      _titleHaptics = _SelectionHapticBinder(
        widget.titleController,
        () => ref.read(settingsProvider).hapticIntensity,
      );
    }
    if (oldWidget.contentController != widget.contentController) {
      _contentHaptics.dispose();
      _contentHaptics = _SelectionHapticBinder(
        widget.contentController,
        () => ref.read(settingsProvider).hapticIntensity,
      );
    }
  }

  @override
  void dispose() {
    _titleHaptics.dispose();
    _contentHaptics.dispose();
    _panelScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);

    final titleStyle = AppTheme.getTextStyleForFont(
      settings.fontFamily,
      fontSize: settings.fontSize * 2.0,
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );

    final contentStyle = AppTheme.getTextStyleForFont(
      settings.fontFamily,
      fontSize: settings.fontSize,
      height: settings.lineHeight,
      color: theme.colorScheme.onSurface,
    );

    return SingleChildScrollView(
      controller: _panelScrollController,
      // Vedi la doc di `_panelScrollController` sopra per il perché è
      // questa la causa radice dell'asimmetria su/giù.
      dragStartBehavior: DragStartBehavior.down,
      // Fisica esplicita (già il default su Android, ma la rendiamo
      // esplicita per non dipendere da un `ScrollBehavior` ambient che in
      // futuro potrebbe cambiare piattaforma/fisica sotto i piedi a questo
      // editor).
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 96),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title Field
              TextField(
                controller: widget.titleController,
                onChanged: widget.onTitleChanged,
                style: titleStyle,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  hintText: l10n.untitledNote,
                  hintStyle: titleStyle.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),

              const SizedBox(height: 12),
              Divider(
                color: theme.colorScheme.outline.withValues(alpha: 0.25),
                thickness: 1,
              ),
              const SizedBox(height: 16),

              // Markdown Body Field
              TextField(
                controller: widget.contentController,
                undoController: widget.undoController,
                onChanged: widget.onContentChanged,
                style: contentStyle,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  hintText: l10n.writeMarkdownHere,
                  hintStyle: contentStyle.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
