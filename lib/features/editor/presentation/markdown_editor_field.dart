import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../../core/utils/selection_auto_scroller.dart';
import '../../settings/providers/settings_provider.dart';
import 'note_scroll_memory.dart';
import 'reading_layout.dart';

class MarkdownEditorField extends ConsumerStatefulWidget {
  final TextEditingController titleController;
  final TextEditingController contentController;
  final UndoHistoryController? undoController;

  /// Identificativo della nota: serve a ricordare la posizione di scrittura
  /// (offset nel sorgente) e a condividerla con la vista di sola lettura.
  final String? noteId;

  /// Focus del campo di contenuto (opzionale): permette al pannello editor
  /// di sapere se si sta scrivendo nel corpo o nel titolo (scorciatoie di
  /// formattazione Markdown).
  final FocusNode? contentFocusNode;
  final ValueChanged<String>? onTitleChanged;
  final ValueChanged<String>? onContentChanged;

  /// Occorrenza attiva della ricerca interna alla nota (vedi
  /// `note_search_provider.dart`), o `null` se la ricerca non è attiva /
  /// non ha risultati. Non viene usata per disegnare l'evidenziazione (di
  /// quella si occupa già `widget.contentController`, quando è un
  /// `SearchHighlightingTextEditingController` — vedi `note_editor_pane.dart`):
  /// serve SOLO a sapere QUANDO e VERSO DOVE scrollare automaticamente il
  /// campo di modifica, cosicché il punto trovato sia sempre visibile senza
  /// che l'utente debba scorrere manualmente (vedi [_scrollToActiveMatch]).
  final TextRange? activeSearchMatch;

  const MarkdownEditorField({
    super.key,
    required this.titleController,
    required this.contentController,
    this.noteId,
    this.undoController,
    this.contentFocusNode,
    this.onTitleChanged,
    this.onContentChanged,
    this.activeSearchMatch,
  });

  @override
  ConsumerState<MarkdownEditorField> createState() =>
      _MarkdownEditorFieldState();
}

/// Collega un singolo [TextEditingController] al gate globale di
/// [HapticsHelper].
///
/// Il framework vibra nativamente a ogni cambio di selezione
/// (flutter/flutter#115373) senza passare da [HapticsHelper]: la
/// soppressione vera avviene nel platform channel (vedi `main.dart`).
/// Qui resta solo da:
///  1. ignorare le notifiche dovute a digitazione di testo;
///  2. inoltrare `isCollapsed` a [HapticsHelper.reportSelectionState],
///     che ri-arma il colpetto "light" con un debounce;
///  3. per "strong", chiamare [HapticsHelper.selectionDragTick] a ogni
///     variazione del range (serve su iOS, dove il framework vibra solo
///     alla creazione della selezione).
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

    final selectionChanged =
        selection.start != _lastSelection.start ||
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

/// Inoltra a [SelectionAutoScroller] i cambi di SELEZIONE di un
/// [TextEditingController].
///
/// Le notifiche dovute a digitazione/IME (il testo cambia) vengono ignorate:
/// non sono un gesto di selezione e non devono mai armare l'auto-scroll.
class _SelectionChangeRelay {
  _SelectionChangeRelay(this._controller, this._onSelectionChanged) {
    _lastText = _controller.text;
    _lastSelection = _controller.selection;
    _controller.addListener(_onValueChanged);
  }

  final TextEditingController _controller;
  final VoidCallback _onSelectionChanged;
  late String _lastText;
  late TextSelection _lastSelection;

  void _onValueChanged() {
    final text = _controller.text;
    final selection = _controller.selection;
    final textChanged = text != _lastText;
    final selectionChanged = selection != _lastSelection;
    _lastText = text;
    _lastSelection = selection;
    if (textChanged || !selectionChanged || !selection.isValid) return;
    _onSelectionChanged();
  }

  void dispose() {
    _controller.removeListener(_onValueChanged);
  }
}

class _MarkdownEditorFieldState extends ConsumerState<MarkdownEditorField>
    with SingleTickerProviderStateMixin {
  late _SelectionHapticBinder _titleHaptics;
  late _SelectionHapticBinder _contentHaptics;

  // Auto-scroll continuo durante il trascinamento di una selezione (vedi
  // `SelectionAutoScroller`) e relativi relay dei due campi. Lo
  // `SelectionRevealShield` in `build` silenzia lo scroll nativo di
  // `TextField`, che a dito fermo non scorre e va in conflitto con gli
  // estremi della selezione (flutter/flutter#132047).
  late final SelectionAutoScroller _autoScroller;
  late _SelectionChangeRelay _titleSelectionRelay;
  late _SelectionChangeRelay _contentSelectionRelay;

  // Riferimenti propri (non condivisi col chiamante) usati SOLO per portare
  // a schermo automaticamente l'occorrenza attiva della ricerca interna
  // (vedi [_scrollToActiveMatch]): uno `ScrollController` esplicito sullo
  // `SingleChildScrollView` che avvolge titolo + contenuto, e una chiave sul
  // campo di contenuto per poterne misurare la posizione reale al suo
  // interno.
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewKey = GlobalKey();
  final GlobalKey _contentFieldKey = GlobalKey();

  // Ripristino della posizione condivisa con la vista di lettura. Come nella
  // lettura, il salvataggio avviene durante lo scroll (ScrollUpdate/End), non
  // in `dispose`: quando il campo viene smontato lo `Scrollable` può aver già
  // perso i client.
  int _restoreRevision = 0;
  double? _lastSavedEditorPixels;
  bool _saveEditorPositionScheduled = false;

  @override
  void initState() {
    super.initState();
    _titleHaptics = _SelectionHapticBinder(
      widget.titleController,
      () => ref.read(settingsProvider).hapticIntensity,
    );
    _contentHaptics = _SelectionHapticBinder(
      widget.contentController,
      () => ref.read(settingsProvider).hapticIntensity,
    );

    _autoScroller = SelectionAutoScroller(
      vsync: this,
      scrollController: _scrollController,
      viewportRect: _viewportGlobalRect,
      onScrollingChanged: (scrolling) =>
          HapticsHelper.selectionAutoScrollActive = scrolling,
    );
    _titleSelectionRelay = _SelectionChangeRelay(
      widget.titleController,
      _autoScroller.notifySelectionChanged,
    );
    _contentSelectionRelay = _SelectionChangeRelay(
      widget.contentController,
      _autoScroller.notifySelectionChanged,
    );

    if (widget.activeSearchMatch != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToActiveMatch(),
      );
    } else {
      _scheduleEditorRestore();
    }
  }

  // Rettangolo globale della viewport di scroll (l'area in cui il contenuto
  // è realmente visibile), o `null` se non ancora disponibile.
  Rect? _viewportGlobalRect() {
    final box = _scrollViewKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
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
      _titleSelectionRelay.dispose();
      _titleSelectionRelay = _SelectionChangeRelay(
        widget.titleController,
        _autoScroller.notifySelectionChanged,
      );
    }
    if (oldWidget.contentController != widget.contentController) {
      _contentHaptics.dispose();
      _contentHaptics = _SelectionHapticBinder(
        widget.contentController,
        () => ref.read(settingsProvider).hapticIntensity,
      );
      _contentSelectionRelay.dispose();
      _contentSelectionRelay = _SelectionChangeRelay(
        widget.contentController,
        _autoScroller.notifySelectionChanged,
      );
    }

    if (oldWidget.noteId != widget.noteId) {
      _restoreRevision++;
      _lastSavedEditorPixels = null;
      if (widget.activeSearchMatch == null) _scheduleEditorRestore();
    }

    // Nuova occorrenza attiva (ricerca appena aperta, avanzamento
    // Avanti/Indietro, o nuova nota aperta già con un termine impostato):
    // portala a schermo. `TextRange` ha uguaglianza per valore, quindi
    // questo confronto individua correttamente sia un cambio di posizione
    // sia una transizione da "nessuna occorrenza attiva" a "una c'è".
    if (widget.activeSearchMatch != null &&
        widget.activeSearchMatch != oldWidget.activeSearchMatch) {
      // La ricerca ha la precedenza sul ripristino della posizione: annulla
      // un eventuale ripristino ancora in coda e porta a schermo l'occorrenza.
      _restoreRevision++;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToActiveMatch(),
      );
    }
  }

  @override
  void dispose() {
    // Nessun salvataggio qui: al momento del `dispose` lo Scrollable ha già
    // perso i client e la posizione non è più misurabile. La memoria è
    // aggiornata dalle notifiche di scroll.
    _restoreRevision++;
    _titleHaptics.dispose();
    _contentHaptics.dispose();
    _titleSelectionRelay.dispose();
    _contentSelectionRelay.dispose();
    _autoScroller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// `RenderEditable` del corpo della nota, cercato nel sottoalbero del campo.
  /// Serve per tradurre pixel <-> posizione nel testo usando la geometria che
  /// Flutter ha già calcolato, senza un `TextPainter` completo a ogni scroll.
  RenderEditable? _contentRenderEditable() {
    final root = _contentFieldKey.currentContext?.findRenderObject();
    if (root == null || !root.attached) return null;
    RenderEditable? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderEditable) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  void _scheduleEditorRestore() {
    final noteId = widget.noteId;
    if (noteId == null) return;
    final sourceOffset = NoteScrollMemory.sourceOffsetFor(noteId);
    if (sourceOffset == null) return;
    final revision = ++_restoreRevision;
    _applyEditorRestore(sourceOffset, revision: revision, retries: 2);
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _applyEditorRestore(
    int sourceOffset, {
    required int revision,
    required int retries,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _restoreRevision) return;
      if (!_scrollController.hasClients) return;

      final position = _scrollController.position;
      final maxOffset = widget.contentController.text.length;
      final offset = sourceOffset.clamp(0, maxOffset);

      // Offset 0 = inizio nota: conserva il titolo e il padding iniziale.
      if (offset == 0) {
        if (position.pixels != 0) _scrollController.jumpTo(0);
        return;
      }

      final editable = _contentRenderEditable();
      final viewport = _viewportGlobalRect();
      if (editable != null && viewport != null) {
        final caret = editable.getLocalRectForCaret(
          TextPosition(offset: offset),
        );
        final caretTop = editable.localToGlobal(caret.topLeft).dy;
        final target = (position.pixels + caretTop - viewport.top).clamp(
          0.0,
          position.maxScrollExtent,
        );
        if ((target - position.pixels).abs() > 0.5) {
          _scrollController.jumpTo(target);
        }
        return;
      }

      if (retries > 0) {
        _applyEditorRestore(
          sourceOffset,
          revision: revision,
          retries: retries - 1,
        );
        WidgetsBinding.instance.ensureVisualUpdate();
      }
    });
  }

  /// Salva come offset nel sorgente il primo carattere visibile nella
  /// viewport. `getPositionForPoint` lavora in coordinate globali e sfrutta il
  /// layout già pronto di `RenderEditable`: nessun ricalcolo del testo.
  void _saveEditorPosition() {
    final noteId = widget.noteId;
    if (noteId == null || !_scrollController.hasClients) return;
    final editable = _contentRenderEditable();
    final viewport = _viewportGlobalRect();
    if (editable == null || viewport == null) return;

    final editableOrigin = editable.localToGlobal(Offset.zero);
    final textPosition = editable.getPositionForPoint(
      Offset(editableOrigin.dx + 1, viewport.top),
    );
    final sourceOffset = textPosition.offset.clamp(
      0,
      widget.contentController.text.length,
    );
    NoteScrollMemory.save(noteId, sourceOffset);
  }

  /// La geometria del campo riflette il nuovo offset di paint solo a frame
  /// concluso: la misura viene quindi accodata una sola volta per frame.
  void _scheduleSaveEditorPosition() {
    if (_saveEditorPositionScheduled) return;
    _saveEditorPositionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _saveEditorPositionScheduled = false;
      if (!mounted) return;
      _saveEditorPosition();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _handleEditorScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollUpdateNotification) {
      final pixels = notification.metrics.pixels;
      final last = _lastSavedEditorPixels;
      // Stessa soglia della vista di lettura: si evita una misura della
      // geometria a ogni frame senza perdere la posizione finale.
      if (last == null || (pixels - last).abs() >= 48) {
        _lastSavedEditorPixels = pixels;
        _scheduleSaveEditorPosition();
      }
    } else if (notification is ScrollEndNotification) {
      _lastSavedEditorPixels = notification.metrics.pixels;
      _scheduleSaveEditorPosition();
    }
    return false;
  }

  /// Calcola la posizione verticale reale dell'occorrenza attiva nel campo
  /// di contenuto e scrolla [_scrollController] fino a portarla in vista.
  ///
  /// Non usa `contentController.selection` + focus: assegnare una selezione
  /// "vera" farebbe scattare l'aptica di `_SelectionHapticBinder` e potrebbe
  /// aprire la tastiera. Il calcolo usa la geometria disposta da Flutter e
  /// un `TextPainter` con lo stesso stile del testo reso.
  void _scrollToActiveMatch() {
    final match = widget.activeSearchMatch;
    if (match == null || !mounted) return;
    if (!_scrollController.hasClients) return;

    final viewportBox = _scrollViewKey.currentContext?.findRenderObject();
    final fieldBox = _contentFieldKey.currentContext?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.attached) return;
    if (fieldBox is! RenderBox || !fieldBox.attached) return;

    final fieldTopInViewport = fieldBox
        .localToGlobal(Offset.zero, ancestor: viewportBox)
        .dy;
    final fieldTopAbsolute = _scrollController.offset + fieldTopInViewport;

    final settings = ref.read(settingsProvider);
    final contentStyle = AppTheme.getTextStyleForFont(
      settings.fontFamily,
      fontSize: settings.fontSize,
      height: settings.lineHeight,
    );

    final fullText = widget.contentController.text;
    final matchStart = match.start.clamp(0, fullText.length);
    final textBeforeMatch = fullText.substring(0, matchStart);

    final painter = TextPainter(
      text: TextSpan(text: textBeforeMatch, style: contentStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: fieldBox.size.width);

    // Punto verticale (relativo all'inizio del campo) in cui inizia
    // l'occorrenza: l'altezza del testo che la precede, con lo stesso
    // wrapping/stile del testo reale nel campo.
    final matchOffsetWithinField = painter.height;
    painter.dispose();

    // Centra l'occorrenza leggermente sopra al centro della viewport
    // (30% dall'alto), invece che esattamente al bordo superiore: lascia
    // un po' di contesto visibile sopra al risultato trovato.
    final target =
        (fieldTopAbsolute +
                matchOffsetWithinField -
                viewportBox.size.height * 0.3)
            .clamp(0.0, _scrollController.position.maxScrollExtent);

    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // `.select` sui soli campi che influenzano davvero questo widget
    // (font/size/line-height): coerente con lo stesso pattern già usato in
    // `MarkdownRenderedView` per la vista di sola lettura. Un cambio di
    // tema, lingua, accento o intensità haptic nelle Impostazioni non
    // invalida più questo campo di editing (con relativo `TextField`,
    // scroll controller, ecc.) mentre l'utente sta scrivendo altrove.
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    final titleStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize * 2.0,
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );

    final contentStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: theme.colorScheme.onSurface,
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _handleEditorScrollNotification,
      child: SingleChildScrollView(
        key: _scrollViewKey,
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(
          ReadingLayout.horizontalPadding,
          20,
          ReadingLayout.horizontalPadding,
          96,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ReadingLayout.maxContentWidth,
            ),
            child: SelectionRevealShield(
              isBlocking: () => _autoScroller.isDraggingSelection,
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
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.35,
                        ),
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
                  Container(
                    key: _contentFieldKey,
                    child: TextField(
                      controller: widget.contentController,
                      focusNode: widget.contentFocusNode,
                      undoController: widget.undoController,
                      onChanged: widget.onContentChanged,
                      style: contentStyle,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText: l10n.writeMarkdownHere,
                        hintStyle: contentStyle.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.35,
                          ),
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
