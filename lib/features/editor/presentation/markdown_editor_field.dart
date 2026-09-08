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
/// PERCHÉ LA VECCHIA LOGICA ERA DIFETTOSA (causa radice del bug):
/// La versione precedente decideva basandosi SOLO sul valore istantaneo di
/// `selection.isCollapsed` prima/dopo ogni notifica del controller: se era
/// `true` e diventava `false`, scattava un colpetto. Il problema è che
/// durante un trascinamento reale di una maniglia, quando le due maniglie
/// si avvicinano/si sfiorano, `TextSelection` PASSA MOMENTANEAMENTE per uno
/// stato collassato (base == extent) per poi riaprirsi non appena il dito
/// continua a muoversi: agli occhi della vecchia logica questo È
/// indistinguibile dall'inizio di una selezione ex-novo, quindi ogni
/// oscillazione del dito vicino al punto di incontro delle maniglie
/// generava un NUOVO colpetto — più vibrazioni ravvicinate percepite
/// dall'utente come un ronzio continuo e fastidioso proprio durante il drag,
/// cioè esattamente il momento in cui la specifica richiede silenzio totale.
/// Inoltre l'intensità "strong" non emetteva mai un feedback continuo
/// durante il trascinamento: chiamava lo stesso identico singolo colpetto
/// (solo più marcato), senza alcuna vibrazione "di sistema" durante il drag.
///
/// LA CORREZIONE:
/// Si introduce uno stato "armato" (`_armed`) che non dipende più dal solo
/// valore istantaneo di `isCollapsed`, ma dal momento in cui il PUNTATORE
/// tocca lo schermo (vedi [onPointerDown]/[onPointerUp], agganciati da un
/// `Listener` attorno al `TextField` in `build()`):
///  - Se un gesto INIZIA quando non c'è selezione, viene armato: la prima
///    transizione verso una selezione non vuota nel corso di QUEL gesto fa
///    scattare un solo colpetto, poi si disarma e resta disarmato per il
///    resto del gesto, qualunque oscillazione avvenga (risolve il ronzio).
///  - Se un gesto INIZIA quando una selezione esiste già (l'utente sta
///    afferrando una maniglia per ridimensionarla), non viene mai armato:
///    zero vibrazioni per l'intera durata di quel trascinamento, anche se
///    il range attraversa lo zero, come richiesto dalla specifica.
///  - Il testo digitato continua ad essere esplicitamente escluso
///    confrontando il testo prima/dopo: non deve mai generare vibrazione.
/// In parallelo, l'intensità "strong" ignora questo stato "armato" e
/// richiama semplicemente [HapticsHelper.selectionDragTick] ad ogni
/// variazione del range mentre la selezione resta non-collassata,
/// riproducendo così la vibrazione continua/marcata richiesta.
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
  /// deve generare il colpetto "light". Si disarma non appena il colpetto
  /// scatta e NON viene riarmato mentre il dito resta premuto (vedi sopra).
  bool _armed = true;

  /// true mentre il dito/puntatore è a contatto con il campo di testo.
  bool _pointerDown = false;

  /// Da agganciare a `Listener.onPointerDown` sul `TextField`: registra lo
  /// stato di partenza del gesto per decidere se armare o meno il colpetto.
  void onPointerDown() {
    _pointerDown = true;
    _armed = _controller.selection.isCollapsed;
  }

  /// Da agganciare a `Listener.onPointerUp`/`onPointerCancel`: a dito
  /// sollevato, se non è rimasta alcuna selezione siamo pronti per un
  /// futuro, nuovo, "primo colpetto" (es. il prossimo long-press).
  void onPointerUp() {
    _pointerDown = false;
    if (_controller.selection.isCollapsed) {
      _armed = true;
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
      _lastSelection = value.selection;
      if (!_pointerDown && value.selection.isCollapsed) {
        _armed = true;
      }
      return;
    }

    final selection = value.selection;
    // selection.isCollapsed è true anche per una TextSelection non valida
    // (offset == -1), quindi non serve un controllo separato su isValid.
    final isCollapsedNow = selection.isCollapsed;
    final selectionChanged = selection.start != _lastSelection.start ||
        selection.end != _lastSelection.end;

    // "Light": un solo colpetto per gesto, solo se il gesto è partito da
    // "nessuna selezione". Vedi doc di classe per il perché di `_armed`.
    if (_armed && !isCollapsedNow) {
      HapticsHelper.selectionStart(_getIntensity());
      _armed = false;
    } else if (!_pointerDown && isCollapsedNow) {
      // Nessun gesto in corso e nessuna selezione residua: pronti per il
      // prossimo "primo colpetto".
      _armed = true;
    }

    // "Strong": ticchettio ad ogni variazione del range mentre si trascina,
    // indipendentemente dallo stato "armato" usato per "light".
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
              Listener(
                onPointerDown: (_) => _titleHaptics.onPointerDown(),
                onPointerUp: (_) => _titleHaptics.onPointerUp(),
                onPointerCancel: (_) => _titleHaptics.onPointerUp(),
                child: TextField(
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
              ),

              const SizedBox(height: 12),
              Divider(
                color: theme.colorScheme.outline.withValues(alpha: 0.25),
                thickness: 1,
              ),
              const SizedBox(height: 16),

              // Markdown Body Field
              Listener(
                onPointerDown: (_) => _contentHaptics.onPointerDown(),
                onPointerUp: (_) => _contentHaptics.onPointerUp(),
                onPointerCancel: (_) => _contentHaptics.onPointerUp(),
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
