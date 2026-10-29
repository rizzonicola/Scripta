import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/note_search_provider.dart';

/// Vista di sola lettura mostrata AL POSTO di [MarkdownRenderedView] mentre
/// la ricerca interna alla nota è attiva con un termine non vuoto (vedi
/// `_ReadOnlyNoteView` in `note_editor_pane.dart`).
///
/// PERCHÉ una vista separata invece di far evidenziare le occorrenze
/// direttamente dentro `MarkdownRenderedView`: quella vista è un
/// sottosistema estremamente ottimizzato (virtualizzazione a blocchi con
/// selezione ancorata al modello dati — vedi la sua corposa documentazione
/// di classe) costruito attorno a `flutter_md`, che non espone alcun punto
/// di estensione per colorare porzioni arbitrarie di testo ALL'INTERNO di
/// un nodo (serve un controllo carattere per carattere, non a livello di
/// blocco/span Markdown — vedi `MarkdownThemeData.builder` e `spanFilter`,
/// che operano su interi blocchi/span, non su sotto-range di un singolo
/// span). Iniettare l'evidenziazione lì dentro richiederebbe di riscrivere
/// quella pipeline, con rischio concreto di regressioni su un'area già
/// delicata.
///
/// Questa vista, mostrata SOLO per la durata di una ricerca attiva (si torna
/// a [MarkdownRenderedView] non appena il pannello si chiude o il termine
/// viene svuotato), mostra invece il testo "grezzo" del corpo della nota
/// (senza interpretare la sintassi Markdown) con le occorrenze evidenziate:
/// una scelta deliberata per evitare di dover riscrivere la pipeline di
/// rendering formattato solo per questo caso d'uso transitorio.
class NoteSearchHighlightedView extends ConsumerStatefulWidget {
  final String title;
  final String content;

  const NoteSearchHighlightedView({
    super.key,
    required this.title,
    required this.content,
  });

  @override
  ConsumerState<NoteSearchHighlightedView> createState() =>
      _NoteSearchHighlightedViewState();
}

class _NoteSearchHighlightedViewState
    extends ConsumerState<NoteSearchHighlightedView> {
  // Chiave applicata SOLO al widget dell'occorrenza attiva (le altre sono
  // semplici TextSpan, senza alcun costo aggiuntivo di widget): è
  // sufficiente per portarla a schermo con `Scrollable.ensureVisible`, senza
  // dover assegnare una GlobalKey a ciascuna occorrenza dell'intero
  // documento.
  final GlobalKey _activeMatchKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  TextRange? _lastScrolledToMatch;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleScrollIfNeeded(TextRange? activeMatch) {
    if (activeMatch == null || activeMatch == _lastScrolledToMatch) return;
    _lastScrolledToMatch = activeMatch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final matchContext = _activeMatchKey.currentContext;
      if (matchContext == null) return;
      Scrollable.ensureVisible(
        matchContext,
        alignment: 0.3,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void didUpdateWidget(covariant NoteSearchHighlightedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      // Nota diversa (o contenuto cambiato altrove): l'ultima occorrenza
      // verso cui ci si era scrollati non ha più alcun significato.
      _lastScrolledToMatch = null;
    }
  }

  /// Top (in coordinate del testo) della riga della occorrenza attiva.
  /// Il TextPainter usa lo stesso stile e la stessa larghezza del
  /// SelectableText, quindi la riga misurata coincide con quella disegnata.
  double? _activeMatchTop({
    required BuildContext context,
    required String text,
    required TextRange? activeMatch,
    required TextStyle style,
    required double maxWidth,
  }) {
    if (activeMatch == null || text.isEmpty || maxWidth <= 0) return null;
    final start = activeMatch.start.clamp(0, text.length);
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final offset = painter.getOffsetForCaret(
      TextPosition(offset: start),
      Rect.zero,
    );
    painter.dispose();
    return offset.dy;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    final matches = ref.watch(noteSearchMatchesProvider);
    final activeIndex = ref.watch(noteSearchActiveMatchIndexProvider);
    final activeMatch = (activeIndex >= 0 && activeIndex < matches.length)
        ? matches[activeIndex]
        : null;

    _scheduleScrollIfNeeded(activeMatch);

    final baseStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: theme.colorScheme.onSurface,
    );

    final normalHighlight =
        (isDark ? Colors.amber.shade700 : Colors.amber.shade300).withValues(
          alpha: 0.55,
        );
    const activeHighlight = Color(0xFFFB923C); // Orange 400, alto contrasto

    final text = widget.content;
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (var i = 0; i < matches.length; i++) {
      final range = matches[i];
      final start = range.start.clamp(0, text.length);
      final end = range.end.clamp(start, text.length);
      if (start >= end) continue;

      if (start > cursor) {
        spans.add(
          TextSpan(text: text.substring(cursor, start), style: baseStyle),
        );
      }

      final matchText = text.substring(start, end);
      // NIENTE WidgetSpan: Flutter lo appiattisce a U+FFFC quando il testo
      // viene copiato. L'evidenziazione della occorrenza attiva è un normale
      // TextSpan; la posizione per lo scroll è calcolata sotto col TextPainter
      // e materializzata in un anchor invisibile fuori dalla selezione.
      spans.add(
        TextSpan(
          text: matchText,
          style: baseStyle.copyWith(
            backgroundColor: i == activeIndex
                ? activeHighlight
                : normalHighlight,
            color: i == activeIndex ? Colors.black : null,
          ),
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
    }

    final hasTitle = widget.title.trim().isNotEmpty;

    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasTitle) ...[
                Text(
                  widget.title,
                  style: AppTheme.getTextStyleForFont(
                    fontFamily,
                    fontSize: fontSize * 2.2,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSurface,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 16),
                Divider(
                  color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  thickness: 1,
                ),
                const SizedBox(height: 20),
              ],
              LayoutBuilder(
                builder: (context, constraints) {
                  final activeTop = _activeMatchTop(
                    context: context,
                    text: text,
                    activeMatch: activeMatch,
                    style: baseStyle,
                    maxWidth: constraints.maxWidth,
                  );
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SelectableText.rich(
                        TextSpan(style: baseStyle, children: spans),
                      ),
                      if (activeTop != null)
                        Positioned(
                          top: activeTop,
                          left: 0,
                          child: SizedBox(
                            key: _activeMatchKey,
                            width: 1,
                            height: 1,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
