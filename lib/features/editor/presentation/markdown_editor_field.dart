import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';

/// Notifica SOLO quando lo stato "almeno un campo ha una selezione non
/// collassata" cambia (true<->false), mai sulle variazioni intermedie
/// dell'estensione della selezione durante un trascinamento.
///
/// CAUSA RADICE DELL'ASIMMETRIA SU/GIÙ (confermata da uno screen recording
/// fornito dall'utente, che mostra la posizione di scroll oscillare avanti
/// e indietro — non un semplice "arriva troppo veloce e si ferma" — mentre
/// si ridimensiona una selezione trascinando verso l'alto):
/// la `SingleChildScrollView` che contiene titolo e corpo ha un proprio
/// riconoscitore di trascinamento (serve per lo scroll manuale a dito).
/// Quando l'utente trascina una maniglia di selezione, ANCHE quel
/// riconoscitore vede lo stesso puntatore muoversi verticalmente e può
/// competere nella arena dei gesti con il riconoscitore privato della
/// maniglia (gestito da `EditableText`/`RenderEditable`, disegnato in un
/// `OverlayEntry` sopra tutto). Quando entrambi processano per un po' lo
/// stesso trascinamento prima che l'arena si risolva, si ottengono DUE
/// sistemi che spostano la stessa posizione di scroll in tempi leggermente
/// sfasati: uno segue il dito "a fisica" (drag diretto), l'altro rincorre
/// programmaticamente l'estremo della selezione (`ensureVisible`) — da qui
/// il rimbalzo avanti/indietro osservato, molto più percepibile trascinando
/// verso l'alto (verso il basso i due target coincidono quasi sempre,
/// perché il testo "va incontro" al dito).
///
/// FIX: mentre una selezione è attiva (non collassata) su uno dei due
/// campi, la `SingleChildScrollView` esterna smette di accettare il
/// trascinamento manuale (`NeverScrollableScrollPhysics`). Questo NON
/// blocca lo scroll programmatico: `ScrollPosition.animateTo`/`jumpTo`
/// (ciò che `EditableText` usa per `ensureVisible`) agiscono direttamente
/// sulla posizione e ignorano la fisica "utente" — che è esattamente lo
/// scopo di `NeverScrollableScrollPhysics` (impedisce SOLO il trascinamento
/// a dito, non lo scroll pilotato da codice). Tolta la concorrenza nella
/// arena dei gesti, resta un solo sistema a guidare lo scroll durante il
/// resize della selezione, in entrambe le direzioni.
class _SelectionActivityNotifier extends ChangeNotifier {
  bool _active = false;
  bool get active => _active;

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    notifyListeners();
  }
}


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

  final _selectionActivity = _SelectionActivityNotifier();

  void _updateSelectionActivity() {
    final active = !widget.titleController.selection.isCollapsed ||
        !widget.contentController.selection.isCollapsed;
    _selectionActivity._setActive(active);
  }

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
    widget.titleController.addListener(_updateSelectionActivity);
    widget.contentController.addListener(_updateSelectionActivity);
  }

  @override
  void didUpdateWidget(covariant MarkdownEditorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // I controller sono normalmente stabili per l'intera vita del pannello
    // editor (vedi note_editor_pane.dart), ma se mai venissero sostituiti
    // riattacchiamo i listener a quelli nuovi per evitare di restare agganciati
    // a controller ormai fuori uso (o, peggio, già disposti dal chiamante).
    if (oldWidget.titleController != widget.titleController) {
      oldWidget.titleController.removeListener(_updateSelectionActivity);
      widget.titleController.addListener(_updateSelectionActivity);
      _titleHaptics.dispose();
      _titleHaptics = _SelectionHapticBinder(
        widget.titleController,
        () => ref.read(settingsProvider).hapticIntensity,
      );
    }
    if (oldWidget.contentController != widget.contentController) {
      oldWidget.contentController.removeListener(_updateSelectionActivity);
      widget.contentController.addListener(_updateSelectionActivity);
      _contentHaptics.dispose();
      _contentHaptics = _SelectionHapticBinder(
        widget.contentController,
        () => ref.read(settingsProvider).hapticIntensity,
      );
    }
  }

  @override
  void dispose() {
    widget.titleController.removeListener(_updateSelectionActivity);
    widget.contentController.removeListener(_updateSelectionActivity);
    _selectionActivity.dispose();
    _titleHaptics.dispose();
    _contentHaptics.dispose();
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

    return AnimatedBuilder(
      animation: _selectionActivity,
      builder: (context, child) {
        return SingleChildScrollView(
          // Durante il resize di una selezione, niente trascinamento
          // manuale: vedi la doc di `_SelectionActivityNotifier` sopra.
          // Fuori da quella finestra, comportamento identico all'originale.
          physics: _selectionActivity.active
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 96),
          child: child,
        );
      },
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
