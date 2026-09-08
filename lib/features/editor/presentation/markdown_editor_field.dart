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
/// CAUSA RADICE (due bug distinti, corretti in due passaggi):
///
/// Bug #1 (versione originale): la decisione si basava SOLO sul valore
/// istantaneo di `selection.isCollapsed` prima/dopo ogni notifica del
/// controller. Durante un trascinamento reale di una maniglia, quando le
/// due maniglie si sfiorano, `TextSelection` passa MOMENTANEAMENTE per uno
/// stato collassato per poi riaprirsi: la vecchia logica scambiava ogni
/// oscillazione per l'inizio di una nuova selezione, generando vibrazioni
/// ravvicinate percepite come un ronzio continuo proprio durante il drag.
///
/// Bug #2 (nel primo tentativo di fix): per distinguere "nuova selezione"
/// da "trascinamento di una maniglia esistente" avevamo usato un
/// `Listener(onPointerDown/onPointerUp)` intorno al `TextField`, assumendo
/// di poter dedurre lo stato del gesto dai raw pointer event. Il problema è
/// che Flutter disegna le maniglie di selezione tramite un `OverlayEntry`
/// inserito nell'`Overlay` dell'app (in cima all'albero, es. da
/// `MaterialApp`/`Navigator`) e NON come discendente del `TextField`: il
/// tocco sulla maniglia avviene quindi in un ramo dell'albero dei render
/// object completamente separato dal nostro `Listener`, che non riceve MAI
/// quegli eventi. Risultato: durante il trascinamento di una maniglia il
/// nostro `_pointerDown` restava bloccato a `false`, quindi ogni volta che
/// il range attraversava lo zero il codice si "riarmava" e generava un
/// nuovo colpetto — esattamente il ronzio continuo durante il "riprendo la
/// selezione per espanderla/ridurla" segnalato.
///
/// LA CORREZIONE DEFINITIVA:
/// Si abbandona ogni inferenza da pointer/overlay e si usa il segnale che
/// Flutter fornisce ESATTAMENTE per questo scopo: il parametro
/// `SelectionChangedCause` di `TextField.onSelectionChanged` (vedi
/// [onSelectionChanged]), che indica il MOTIVO per cui la selezione è
/// cambiata, indipendentemente da dove si trovi fisicamente il tocco:
///  - `longPress` / `doubleTap` / `forcePress` -> l'utente sta CREANDO una
///    selezione ex-novo: se il testo non era selezionato un istante prima,
///    scatta un solo colpetto "light".
///  - `drag` -> l'utente sta trascinando una maniglia (sia per allargare la
///    selezione iniziale sia per ridimensionarne una già esistente): non fa
///    MAI scattare il colpetto "light", qualunque valore attraversi
///    `isCollapsed` nel frattempo.
/// L'intensità "strong" resta invece gestita dal listener sul controller
/// (vedi [_onValueChanged]), che chiama [HapticsHelper.selectionDragTick]
/// ad ogni variazione del range mentre la selezione resta non-collassata:
/// questa parte funzionava già correttamente e non è stata toccata.
class _SelectionHapticBinder {
  _SelectionHapticBinder(this._controller, this._getIntensity) {
    _lastText = _controller.text;
    _lastSelectionForTick = _controller.selection;
    _wasCollapsedForLight = _controller.selection.isCollapsed;
    _controller.addListener(_onValueChanged);
  }

  final TextEditingController _controller;
  final HapticIntensity Function() _getIntensity;
  late String _lastText;

  /// Stato usato SOLO dal ticchettio continuo di "strong" (invariato).
  late TextSelection _lastSelectionForTick;

  /// Stato usato SOLO dal colpetto singolo di "light", aggiornato
  /// esclusivamente in [onSelectionChanged]/testo digitato: tenerlo separato
  /// dal listener del controller evita ambiguità sull'ordine di chiamata
  /// tra `ChangeNotifier` e callback del widget.
  bool _wasCollapsedForLight = true;

  /// Da agganciare a `TextField.onSelectionChanged`.
  void onSelectionChanged(TextSelection selection, SelectionChangedCause? cause) {
    final wasCollapsed = _wasCollapsedForLight;
    _wasCollapsedForLight = selection.isCollapsed;

    if (_getIntensity() != HapticIntensity.light) return;

    final isCreationCause = cause == SelectionChangedCause.longPress ||
        cause == SelectionChangedCause.doubleTap ||
        cause == SelectionChangedCause.forcePress;

    if (isCreationCause && wasCollapsed && !selection.isCollapsed) {
      HapticsHelper.selectionStart(HapticIntensity.light);
    }
  }

  void _onValueChanged() {
    final value = _controller.value;
    final textChanged = value.text != _lastText;
    _lastText = value.text;

    if (textChanged) {
      // La digitazione altera spesso anche la selezione (es. la collassa
      // sul nuovo cursore): aggiorniamo solo lo stato senza MAI considerarlo
      // inizio selezione da segnalare.
      _lastSelectionForTick = value.selection;
      _wasCollapsedForLight = value.selection.isCollapsed;
      return;
    }

    final selection = value.selection;
    // selection.isCollapsed è true anche per una TextSelection non valida
    // (offset == -1), quindi non serve un controllo separato su isValid.
    final isCollapsedNow = selection.isCollapsed;
    final selectionChanged = selection.start != _lastSelectionForTick.start ||
        selection.end != _lastSelectionForTick.end;

    // "Strong": ticchettio ad ogni variazione del range mentre si trascina.
    if (selectionChanged && !isCollapsedNow) {
      HapticsHelper.selectionDragTick(_getIntensity());
    }

    _lastSelectionForTick = selection;
  }

  void dispose() {
    _controller.removeListener(_onValueChanged);
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
                onSelectionChanged: _titleHaptics.onSelectionChanged,
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
                onSelectionChanged: _contentHaptics.onSelectionChanged,
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
