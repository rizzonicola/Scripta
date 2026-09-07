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

/// Rileva la transizione "nessuna selezione -> selezione attiva" di un
/// singolo [TextEditingController] e invoca [HapticsHelper.selectionStart]
/// UNA SOLA VOLTA per transizione.
///
/// PERCHÉ QUESTO APPROCCIO (e non un flag nei widget nativi):
/// Flutter non espone un hook pubblico su `TextField` per distinguere "ho
/// appena iniziato una selezione" da "sto trascinando una maniglia per
/// allargarla/restringerla/riposizionarla": entrambe le interazioni
/// aggiornano semplicemente `controller.selection`. La differenza reale
/// che ci interessa, però, è osservabile PURAMENTE dal valore prima/dopo:
///  - Nessuna selezione (`selection.isCollapsed == true`, es. un cursore
///    lampeggiante) -> una selezione con estensione (`isCollapsed == false`)
///    è ESATTAMENTE l'inizio di una nuova selezione (che sia partita da
///    long-press, doppio tap, o drag diretto del mouse): qui vibriamo.
///  - Selezione già attiva che rimane non-collassata mentre l'utente
///    trascina una maniglia per modificarne i bordi: `isCollapsed` resta
///    `false` per tutta la durata del trascinamento, quindi questa classe
///    non emette alcun ulteriore feedback, esattamente il comportamento
///    richiesto.
/// Il testo digitato (che pure aggiorna `TextEditingValue`) viene
/// esplicitamente escluso confrontando il testo prima/dopo: non deve MAI
/// generare vibrazione.
class _SelectionHapticBinder {
  _SelectionHapticBinder(this._controller, this._getIntensity) {
    _lastText = _controller.text;
    _wasCollapsed = _controller.selection.isCollapsed;
    _controller.addListener(_onValueChanged);
  }

  final TextEditingController _controller;
  final HapticIntensity Function() _getIntensity;
  late String _lastText;
  late bool _wasCollapsed;

  void _onValueChanged() {
    final value = _controller.value;
    final textChanged = value.text != _lastText;
    _lastText = value.text;

    if (textChanged) {
      // La digitazione altera spesso anche la selezione (es. la collassa
      // sul nuovo cursore): aggiorniamo solo il riferimento di stato senza
      // MAI considerarlo l'inizio di una selezione da segnalare.
      _wasCollapsed = value.selection.isCollapsed;
      return;
    }

    // selection.isCollapsed è true anche per una TextSelection non valida
    // (offset == -1), quindi non serve un controllo separato su isValid.
    final isCollapsedNow = value.selection.isCollapsed;
    if (_wasCollapsed && !isCollapsedNow) {
      HapticsHelper.selectionStart(_getIntensity());
    }
    _wasCollapsed = isCollapsedNow;
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
