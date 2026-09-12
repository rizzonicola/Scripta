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
    this.undoController,
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

  // Riferimenti propri (non condivisi col chiamante) usati SOLO per portare
  // a schermo automaticamente l'occorrenza attiva della ricerca interna
  // (vedi [_scrollToActiveMatch]): uno `ScrollController` esplicito sullo
  // `SingleChildScrollView` che avvolge titolo + contenuto, e una chiave sul
  // campo di contenuto per poterne misurare la posizione reale al suo
  // interno.
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewKey = GlobalKey();
  final GlobalKey _contentFieldKey = GlobalKey();

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

    if (widget.activeSearchMatch != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActiveMatch());
    }
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

    // Nuova occorrenza attiva (ricerca appena aperta, avanzamento
    // Avanti/Indietro, o nuova nota aperta già con un termine impostato):
    // portala a schermo. `TextRange` ha uguaglianza per valore, quindi
    // questo confronto individua correttamente sia un cambio di posizione
    // sia una transizione da "nessuna occorrenza attiva" a "una c'è".
    if (widget.activeSearchMatch != null &&
        widget.activeSearchMatch != oldWidget.activeSearchMatch) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActiveMatch());
    }
  }

  @override
  void dispose() {
    _titleHaptics.dispose();
    _contentHaptics.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Calcola la posizione verticale REALE (non stimata) dell'inizio
  /// dell'occorrenza attiva all'interno del campo di contenuto e scrolla
  /// [_scrollController] fino a portarla in vista.
  ///
  /// Deliberatamente NON usa `widget.contentController.selection` +
  /// focus per sfruttare l'auto-scroll nativo di `EditableText` verso il
  /// cursore: farlo assegnerebbe una selezione "vera" al controller, che
  /// verrebbe intercettata da `_SelectionHapticBinder` (vedi sopra) come se
  /// l'utente avesse selezionato del testo, producendo un feedback aptico
  /// spurio ad ogni avanzamento tra le occorrenze — oltre a poter aprire la
  /// tastiera software su mobile solo per "guardare" un risultato di
  /// ricerca. Il calcolo qui sotto è invece basato su geometria realmente
  /// disposta da Flutter (dimensioni effettive del campo, `TextPainter` con
  /// lo stesso identico stile del testo reso), non su un'euristica a pixel
  /// fissi per riga.
  void _scrollToActiveMatch() {
    final match = widget.activeSearchMatch;
    if (match == null || !mounted) return;
    if (!_scrollController.hasClients) return;

    final viewportBox = _scrollViewKey.currentContext?.findRenderObject();
    final fieldBox = _contentFieldKey.currentContext?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.attached) return;
    if (fieldBox is! RenderBox || !fieldBox.attached) return;

    final fieldTopInViewport = fieldBox.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
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
    final target = (fieldTopAbsolute + matchOffsetWithinField - viewportBox.size.height * 0.3)
        .clamp(0.0, _scrollController.position.maxScrollExtent);

    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOut,
    );
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
      key: _scrollViewKey,
      controller: _scrollController,
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
              Container(
                key: _contentFieldKey,
                child: TextField(
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
