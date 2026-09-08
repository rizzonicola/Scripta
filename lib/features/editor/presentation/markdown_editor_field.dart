import 'dart:async';

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

/// Governa il feedback tattile per un singolo [TextEditingController],
/// distinguendo in modo affidabile tra:
///  1. l'inizio di una NUOVA selezione (nessun testo selezionato -> testo
///     selezionato): unico momento in cui l'intensità "light" vibra;
///  2. il trascinamento di una maniglia su una selezione GIÀ esistente per
///     espanderla/ridurla: deve restare sempre silenzioso in "light";
///  3. l'intensità "strong", che invece vuole un ticchettio ad ogni
///     variazione del range per tutta la durata del trascinamento.
///
/// STORIA DEL BUG (tre tentativi, i primi due respinti dalla build/CI):
///
/// Bug #1 (versione originale): la decisione si basava SOLO sul valore
/// istantaneo di `selection.isCollapsed` prima/dopo ogni notifica del
/// controller. Durante un trascinamento reale di una maniglia, quando le
/// due maniglie si sfiorano, `TextSelection` passa MOMENTANEAMENTE per uno
/// stato collassato per poi riaprirsi: la vecchia logica scambiava ogni
/// oscillazione per l'inizio di una nuova selezione, generando vibrazioni
/// ravvicinate percepite come un ronzio continuo proprio durante il drag.
///
/// Tentativo #2 (respinto a runtime): per distinguere "nuova selezione" da
/// "trascinamento di una maniglia esistente" avevamo usato un
/// `Listener(onPointerDown/onPointerUp)` intorno al `TextField`. Le
/// maniglie di selezione, però, sono disegnate da Flutter in un
/// `OverlayEntry` separato (in cima all'albero, fuori dal `TextField`): il
/// tocco su una maniglia non attraversa mai il nostro `Listener`, quindi lo
/// stato "dito premuto" restava scorretto e il bug del ronzio ricompariva.
///
/// Tentativo #3 (respinto in CI, errore di compilazione): avevamo agganciato
/// `TextField.onSelectionChanged` per leggere la `SelectionChangedCause`
/// fornita da Flutter (`longPress`/`doubleTap` vs `drag`). Il widget
/// Material `TextField` in questa versione dell'SDK NON espone però un
/// parametro `onSelectionChanged` (esiste solo su `EditableText`/
/// `SelectableText`): build fallita su Linux/Android con "No named
/// parameter with the name 'onSelectionChanged'".
///
/// LA CORREZIONE DEFINITIVA (nessuna dipendenza da pointer/overlay/API
/// assenti — solo il `TextEditingController`, come nella versione
/// originale):
/// Si introduce uno stato "armato" (`_armed`) MA, a differenza del
/// tentativo iniziale, il riarmo non dipende più dal sapere se il dito è
/// premuto: dipende da un breve DEBOUNCE. `_armed` si disarma appena scatta
/// il colpetto e viene riarmato solo dopo che la selezione è rimasta
/// collassata e "silenziosa" (nessun ulteriore cambiamento) per
/// [_rearmDelay]. Un attraversamento-zero momentaneo durante un
/// trascinamento è sempre seguito, nel giro di un frame (~16ms), da un
/// nuovo aggiornamento che lo cancella prima che il timer scada: quindi non
/// riarma mai nulla e non genera falsi positivi. Una vera fine-selezione
/// (dito sollevato, nessun ulteriore movimento) resta invece silenziosa per
/// tutto il debounce e riarma correttamente il colpetto per la prossima
/// selezione. L'intensità "strong" resta gestita separatamente (invariata),
/// con un ticchettio ad ogni variazione del range mentre non è collassata.
class _SelectionHapticBinder {
  _SelectionHapticBinder(this._controller, this._getIntensity) {
    _lastText = _controller.text;
    _lastSelection = _controller.selection;
    _armed = _controller.selection.isCollapsed;
    _controller.addListener(_onValueChanged);
  }

  final TextEditingController _controller;
  final HapticIntensity Function() _getIntensity;
  late String _lastText;
  late TextSelection _lastSelection;

  /// true quando la prossima transizione "nessuna selezione -> selezione"
  /// deve generare il colpetto "light" (vedi doc di classe).
  bool _armed = true;

  /// Timer di debounce che riarma [_armed] solo dopo un periodo di quiete
  /// a selezione collassata; cancellato/riavviato ad ogni notifica del
  /// controller finché la selezione resta collassata.
  Timer? _rearmTimer;

  static const _rearmDelay = Duration(milliseconds: 200);

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
      _scheduleRearmIfNeeded(isCollapsedNow);
      return;
    }

    final selectionChanged = selection.start != _lastSelection.start ||
        selection.end != _lastSelection.end;

    // "Light": un solo colpetto, solo se armato dal debounce (vedi sopra).
    if (_armed && !isCollapsedNow) {
      HapticsHelper.selectionStart(_getIntensity());
      _armed = false;
      _rearmTimer?.cancel();
    } else {
      _scheduleRearmIfNeeded(isCollapsedNow);
    }

    // "Strong": ticchettio ad ogni variazione del range mentre si trascina,
    // indipendentemente dallo stato "armato" usato per "light".
    if (selectionChanged && !isCollapsedNow) {
      HapticsHelper.selectionDragTick(_getIntensity());
    }

    _lastSelection = selection;
  }

  /// Cancella sempre il timer pendente (ogni cambiamento "azzera" la quiete
  /// necessaria al riarmo) e ne pianifica uno nuovo SOLO se la selezione è
  /// attualmente collassata: se invece è ancora attiva non c'è nulla da
  /// riarmare finché non torna vuota.
  void _scheduleRearmIfNeeded(bool isCollapsedNow) {
    _rearmTimer?.cancel();
    if (!isCollapsedNow) return;
    _rearmTimer = Timer(_rearmDelay, () => _armed = true);
  }

  void dispose() {
    _controller.removeListener(_onValueChanged);
    _rearmTimer?.cancel();
  }
}

class _MarkdownEditorFieldState extends ConsumerState<MarkdownEditorField> {
  late _SelectionHapticBinder _titleHaptics;
  late _SelectionHapticBinder _contentHaptics;

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
