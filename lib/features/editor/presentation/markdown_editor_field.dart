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

  /// Scroll controller di proprietà ESCLUSIVA del campo "Contenuto".
  ///
  /// CAUSA RADICE DEL BUG (asimmetria trascina-su vs trascina-giù durante il
  /// ridimensionamento di una selezione esistente):
  /// prima di questa modifica l'intero pannello (titolo + divider + corpo)
  /// viveva dentro un unico `SingleChildScrollView` esterno, con il
  /// `TextField` del corpo impostato a `maxLines: null` e SENZA un proprio
  /// `scrollController`. In questa configurazione `EditableText` non ha una
  /// viewport propria: durante il trascinamento di una maniglia di selezione
  /// delega l'auto-scroll al più vicino `Scrollable` ANCESTOR (trovato via
  /// `Scrollable.of(context)`), chiamando ripetutamente
  /// `ScrollPosition.ensureVisible` per tenere l'estremo della selezione in
  /// vista.
  /// Quel percorso è asimmetrico per costruzione: quando la selezione si
  /// espande verso il basso, il rettangolo-bersaglio richiesto coincide quasi
  /// sempre con l'area appena resa visibile dal frame precedente (il testo
  /// "scorre incontro" al dito), quindi le chiamate a `ensureVisible`
  /// convergono. Quando invece si riprende una selezione già esistente e la
  /// si trascina verso l'alto, ogni frame richiede un nuovo salto scroll
  /// basato sulla geometria dell'ancestor `Scrollable` calcolata PRIMA che il
  /// layout si sia assestato dal salto precedente: le richieste si accumulano
  /// e competono tra loro, producendo lo scatto in avanti troppo veloce, i
  /// movimenti a scatti e l'arresto prematuro prima di raggiungere la cima
  /// osservati in QA.
  ///
  /// La correzione strutturale è dare al corpo la propria viewport delimitata
  /// (vedi `Expanded` in `build`) e il proprio `ScrollController` esplicito:
  /// così `EditableText` gestisce l'auto-scroll durante il trascinamento
  /// direttamente sulla propria `ScrollPosition`, ricalcolata in modo
  /// coerente ad ogni frame in entrambe le direzioni — lo stesso percorso,
  /// stabile, usato da qualunque `TextField` multilinea "normale" con altezza
  /// vincolata (es. i campi di composizione di un client di messaggistica).
  late final ScrollController _contentScrollController;

  @override
  void initState() {
    super.initState();
    _contentScrollController = ScrollController();
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
    _contentScrollController.dispose();
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

    // Titolo (+ divider): sezione fissa, NON dentro la viewport scrollabile
    // del corpo. Cresce naturalmente con `maxLines: null`; non essendo
    // trascinabile su più "pagine" di testo, non soffre del problema di
    // auto-scroll durante il ridimensionamento della selezione.
    final titleSection = Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
            ],
          ),
        ),
      ),
    );

    // Corpo markdown: vincolato in altezza dall'`Expanded` sottostante e
    // reso `expands: true` con un proprio `scrollController` esplicito.
    // A differenza di prima, NON è più annidato dentro un
    // `SingleChildScrollView` esterno: `EditableText` riceve così un vincolo
    // di altezza definito (dall'`Expanded`) e crea al proprio interno uno
    // `Scrollable` di sua esclusiva proprietà. L'auto-scroll durante il
    // trascinamento delle maniglie di selezione avviene quindi direttamente
    // sulla `ScrollPosition` del campo, ricalcolata coerentemente ad ogni
    // frame in entrambe le direzioni — non più delegata a un `Scrollable`
    // ancestor condiviso (e alla sua geometria, potenzialmente non ancora
    // assestata dal salto del frame precedente), che era la causa
    // dell'asimmetria giù-fluido / su-instabile.
    final contentSection = Expanded(
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: TextField(
              controller: widget.contentController,
              scrollController: _contentScrollController,
              undoController: widget.undoController,
              onChanged: widget.onContentChanged,
              style: contentStyle,
              maxLines: null,
              minLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              scrollPadding: const EdgeInsets.fromLTRB(28, 0, 28, 96),
              decoration: InputDecoration(
                hintText: l10n.writeMarkdownHere,
                hintStyle: contentStyle.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                ),
                border: InputBorder.none,
                // Il padding inferiore (96) riproduce lo spazio "di
                // cortesia" che prima era in fondo al `SingleChildScrollView`
                // esterno, cosicché l'ultima riga di testo non resti a
                // ridosso del bordo inferiore dello schermo.
                contentPadding: const EdgeInsets.fromLTRB(28, 0, 28, 96),
              ),
            ),
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        titleSection,
        contentSection,
      ],
    );
  }
}
