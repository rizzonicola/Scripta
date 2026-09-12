import 'package:flutter/material.dart';

/// [TextEditingController] in grado di disegnare, SOPRA al testo esistente,
/// le evidenziazioni delle occorrenze della ricerca interna alla nota (vedi
/// `note_search_provider.dart`), senza mai alterare `text`/`selection`.
///
/// PERCHÉ un controller custom invece di un widget separato che si
/// sovrappone al `TextField`: il campo di editing è già un `TextField`
/// standard, pienamente integrato con autosave, undo/redo e la gestione
/// aptica della selezione (vedi `markdown_editor_field.dart`). Un overlay
/// grafico indipendente dovrebbe rincorrere manualmente ogni cambio di
/// scroll/layout del `TextField` sottostante per restare allineato pixel
/// per pixel al testo — fragile e costoso. Sovrascrivere [buildTextSpan],
/// il punto in cui `EditableText` chiede al controller lo `TextSpan` da
/// disegnare, ottiene l'evidenziazione "gratuitamente" allineata, perché è
/// lo stesso identico meccanismo di rendering del testo del campo.
///
/// [setMatches] aggiorna le occorrenze correnti e chiama `notifyListeners()`
/// anche se `value` (testo/selezione) resta invariato: `TextField` ascolta
/// il controller e ricostruisce ad ogni notifica, quindi questa è la via
/// corretta per far sì che [buildTextSpan] venga richiamato con le nuove
/// occorrenze — non essendoci alcun cambio di `value`, nessun'altra parte
/// del sistema (autosave, undo/redo, aptica di selezione, tutti agganciati
/// all'evento di cambio VALORE) osserva o reagisce a questa notifica.
class SearchHighlightingTextEditingController extends TextEditingController {
  SearchHighlightingTextEditingController({super.text});

  List<TextRange> _matches = const [];
  int _activeMatchIndex = -1;

  void setMatches(List<TextRange> matches, int activeMatchIndex) {
    _matches = matches;
    _activeMatchIndex = activeMatchIndex;
    notifyListeners();
  }

  void clearMatches() => setMatches(const [], -1);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (_matches.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Colori ad alto contrasto per l'evidenziazione: ambra per le
    // occorrenze "passive", arancione pieno (con testo forzato a nero,
    // leggibile su entrambe le combinazioni chiaro/scuro) per quella
    // attualmente attiva — lo stesso schema usato in
    // `NoteSearchHighlightedView` per la vista di sola lettura, così
    // l'aspetto della ricerca resta coerente in entrambe le modalità.
    final normalHighlight =
        (isDark ? Colors.amber.shade700 : Colors.amber.shade300)
            .withValues(alpha: 0.55);
    const activeHighlight = Color(0xFFFB923C); // Orange 400

    final text = this.text;
    final children = <TextSpan>[];
    var cursor = 0;

    for (var i = 0; i < _matches.length; i++) {
      final range = _matches[i];
      final start = range.start.clamp(0, text.length);
      final end = range.end.clamp(start, text.length);
      if (start >= end) continue;

      if (start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, start), style: style));
      }

      final isActive = i == _activeMatchIndex;
      children.add(TextSpan(
        text: text.substring(start, end),
        style: (style ?? const TextStyle()).copyWith(
          backgroundColor: isActive ? activeHighlight : normalHighlight,
          color: isActive ? Colors.black : style?.color,
          fontWeight: isActive ? FontWeight.w700 : style?.fontWeight,
        ),
      ));
      cursor = end;
    }

    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor), style: style));
    }

    return TextSpan(style: style, children: children);
  }
}
