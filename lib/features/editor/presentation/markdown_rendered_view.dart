import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionControls, cupertinoDesktopTextSelectionControls;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste più una modalità "testo grezzo" separata.
///
/// ARCHITETTURA DELLA SELEZIONE — IL RENDERING DIPENDE DALLA LOGICA
/// ---------------------------------------------------------------------
/// Questa vista NON usa la selezione "visiva" nativa di Flutter come fonte
/// di verità. La fonte di verità è [_LogicalSelection]: una coppia di
/// coordinate puramente logiche — (indice del blocco, offset del
/// carattere) — completamente indipendenti da quali widget risultano
/// montati nella `ListView` virtualizzata in un dato istante.
///
/// Il flusso è a senso unico, "logica → rendering", mai il contrario:
///
///  1. Un gesto reale (drag, tap, doppio tap) viene comunque riconosciuto
///     dal motore nativo di Flutter ([SelectableRegion]) — stabile,
///     mantenuto da Google/Flutter, già dotato di maniglie, lente
///     d'ingrandimento, aptica e accessibilità: non ha senso reinventarlo.
///     Sotto ogni blocco esiste però un doppio livello invisibile
///     ([_SelectableUnit]) — un `Text` trasparente col solo testo in
///     chiaro del blocco — che è ciò che [SelectableRegion] vede e
///     seleziona realmente. Il testo/markdown VISIBILE (`MarkdownBody`) è
///     un layer separato, sempre `selectable: false`: non partecipa mai
///     alla selezione nativa.
///  2. Un `Listener` "passivo" (non entra nell'arena dei gesti, quindi non
///     interferisce col drag nativo) osserva in parallelo le posizioni
///     grezze del puntatore e le traduce in coordinate logiche tramite un
///     hit-test sul blocco toccato — cosa possibile SOLO per il blocco
///     effettivamente sotto il dito/cursore in quell'istante, che per
///     definizione fisica è sempre montato.
///  3. Da quell'unico punto di contatto, [_LogicalSelection] si estende
///     per puro confronto di indici — nessuna geometria — a tutti i
///     blocchi compresi fra l'ancora e il fuoco, MONTATI O MENO. Quando
///     un blocco lontano entra nell'area visibile durante lo scroll, si
///     chiede semplicemente "il mio indice è dentro il range selezionato?"
///     e si colora di conseguenza: zero dipendenza da cosa fosse montato
///     al momento in cui la selezione è stata creata.
///  4. "Seleziona tutto" è lo stesso identico meccanismo, non un caso
///     speciale: imposta [_LogicalSelection] da (0,0) all'ultimo
///     carattere dell'ultimo blocco — O(1), nessuna costruzione forzata di
///     widget, nessuna chiamata a `selectAll()` nativa (quella selezionava
///     solo i blocchi già montati, la causa dei "pezzi mancanti" e del
///     calo di prestazioni segnalati).
///  5. La vernice della selezione nativa di [SelectableRegion] è
///     soppressa (`selectionColor` trasparente): l'UNICA evidenziazione
///     visibile è quella disegnata da [_UnitHighlightPainter] a partire da
///     [_LogicalSelection] — un `TextPainter` sul testo in chiaro del
///     blocco, quindi preciso al singolo carattere.
///
/// Limite onesto, dichiarato: l'hit-test e l'evidenziazione usano lo
/// stesso stile di paragrafo per ogni blocco (non lo stile specifico di
/// heading/blockquote/tabella, che `flutter_markdown_plus` non espone
/// all'esterno). Per titoli, citazioni e tabelle il rettangolo evidenziato
/// può quindi non allinearsi a pixel esatto con la tipografia più grande o
/// indentata — il testo selezionato e copiato resta comunque sempre
/// corretto, perché entrambi derivano dallo stesso [_LogicalDocument].
class MarkdownRenderedView extends ConsumerStatefulWidget {
  final String title;
  final String content;

  const MarkdownRenderedView({
    super.key,
    required this.title,
    required this.content,
  });

  @override
  ConsumerState<MarkdownRenderedView> createState() =>
      _MarkdownRenderedViewState();
}

/// Coordinata logica: indice dell'unità (blocco o titolo, 0-based
/// nell'ordine in cui compaiono nella nota) + offset del carattere
/// all'interno del testo in chiaro di quell'unità.
@immutable
class _LogicalOffset {
  final int unitIndex;
  final int offset;
  const _LogicalOffset(this.unitIndex, this.offset);

  bool _isBeforeOrEqual(_LogicalOffset other) {
    if (unitIndex != other.unitIndex) return unitIndex < other.unitIndex;
    return offset <= other.offset;
  }

  @override
  bool operator ==(Object other) =>
      other is _LogicalOffset &&
      other.unitIndex == unitIndex &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(unitIndex, offset);
}

/// Selezione logica: ancora (dove il gesto è iniziato) e fuoco (dove si
/// trova ora). Normalizzata in [start]/[end] per il rendering e la copia.
@immutable
class _LogicalSelection {
  final _LogicalOffset anchor;
  final _LogicalOffset focus;
  const _LogicalSelection({required this.anchor, required this.focus});

  bool get isCollapsed => anchor == focus;

  _LogicalOffset get start =>
      anchor._isBeforeOrEqual(focus) ? anchor : focus;
  _LogicalOffset get end => anchor._isBeforeOrEqual(focus) ? focus : anchor;

  _LogicalSelection withFocus(_LogicalOffset newFocus) =>
      _LogicalSelection(anchor: anchor, focus: newFocus);
}

/// Una singola unità logica del documento: il titolo, oppure un blocco
/// Markdown. `plainText` è il testo in chiaro (senza marcatori Markdown)
/// usato per hit-test, evidenziazione e copia.
@immutable
class _DocUnit {
  final bool isTitle;
  final String plainText;
  const _DocUnit({required this.isTitle, required this.plainText});
}

/// Rappresentazione logica, puramente testuale, dell'intera nota —
/// ricostruita una sola volta per cambio di `title`/`content`, sempre
/// disponibile per intero in memoria indipendentemente da cosa sia
/// effettivamente disegnato a schermo in un dato istante.
@immutable
class _LogicalDocument {
  const _LogicalDocument({required this.units});

  final List<_DocUnit> units;

  factory _LogicalDocument.build({
    required String title,
    required List<String> blocks,
  }) {
    final parser = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    final units = <_DocUnit>[];

    final trimmedTitle = title.trim();
    if (trimmedTitle.isNotEmpty) {
      units.add(_DocUnit(isTitle: true, plainText: trimmedTitle));
    }
    for (final block in blocks) {
      units.add(_DocUnit(isTitle: false, plainText: _plainTextForBlock(parser, block)));
    }
    return _LogicalDocument(units: units);
  }

  static const _kBlockLevelTags = {
    'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'li', 'blockquote', 'pre', 'tr',
  };

  static String _plainTextForBlock(md.Document parser, String blockMarkdown) {
    final nodes = parser.parseLines(blockMarkdown.split('\n'));
    final buffer = StringBuffer();
    for (final node in nodes) {
      _writePlainText(node, buffer);
    }
    return buffer.toString().trim();
  }

  static void _writePlainText(md.Node node, StringBuffer buffer) {
    if (node is md.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is md.Element) {
      if (node.tag == 'br') {
        buffer.write('\n');
        return;
      }
      final children = node.children;
      if (children != null && children.isNotEmpty) {
        for (final child in children) {
          _writePlainText(child, buffer);
        }
      } else {
        buffer.write(node.textContent);
      }
      if (_kBlockLevelTags.contains(node.tag)) {
        buffer.write('\n');
      }
    }
  }

  /// Testo copiato per un range logico [start, end] (estremi inclusi
  /// all'inizio, esclusi alla fine, come una normale `TextRange`),
  /// calcolato esclusivamente dal testo in chiaro già in memoria — mai
  /// dall'albero dei widget.
  String textInRange(_LogicalOffset start, _LogicalOffset end) {
    if (start.unitIndex == end.unitIndex) {
      final text = units[start.unitIndex].plainText;
      final s = start.offset.clamp(0, text.length);
      final e = end.offset.clamp(0, text.length);
      return s < e ? text.substring(s, e) : '';
    }
    final buffer = StringBuffer();
    for (var i = start.unitIndex; i <= end.unitIndex; i++) {
      final text = units[i].plainText;
      if (i == start.unitIndex) {
        buffer.write(text.substring(start.offset.clamp(0, text.length)));
      } else if (i == end.unitIndex) {
        buffer.write(text.substring(0, end.offset.clamp(0, text.length)));
      } else {
        buffer.write(text);
      }
      if (i != end.unitIndex) buffer.write('\n\n');
    }
    return buffer.toString();
  }
}

class _MarkdownRenderedViewState extends ConsumerState<MarkdownRenderedView> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _regionKey = GlobalKey();
  final GlobalKey<SelectableRegionState> _selectableRegionKey =
      GlobalKey<SelectableRegionState>();
  final FocusNode _selectionFocusNode =
      FocusNode(debugLabel: 'markdown-selection');
  final ContextMenuController _menuController = ContextMenuController();

  /// Extent di cache costante: non deve più crescere durante una
  /// selezione, perché la copertura della selezione non dipende più da
  /// quanti blocchi risultano montati (vedi documentazione di classe).
  static const double _kCacheExtent = 800.0;

  /// Fonte di verità dell'intera selezione (parziale o "tutto"): null
  /// quando non c'è nulla selezionato.
  _LogicalSelection? _selection;

  /// Unità attualmente montate, registrate/rimosse da [_SelectableUnit] —
  /// usate SOLO per l'hit-test del punto toccato in questo istante, mai
  /// per decidere cosa evidenziare (quello lo decide [_selection] da solo).
  final Map<int, _SelectableUnitState> _mountedUnits = {};

  Offset? _pointerDownGlobalPosition;
  Offset? _lastPointerGlobalPosition;
  Timer? _autoScrollTimer;

  List<String>? _cachedBlocks;
  String? _cachedContent;
  String? _cachedTitle;
  _LogicalDocument? _logicalDocument;

  (ThemeData, String, double, double)? _cachedStyleKey;
  late MarkdownStyleSheet _markdownStyleSheet;
  late TextStyle _inlineCodeStyle;
  late TextStyle _titleTextStyle;
  late TextStyle _hitTestStyle;
  late bool _isDark;
  late Color _primaryColor;
  late Color _highlightColor;
  late double _fontSize;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _selectionFocusNode.dispose();
    super.dispose();
  }

  void _handleScroll() {
    // Lo scroll non tocca mai lo stato logico (che è indipendente dal
    // montaggio) — chiude solo il menu contestuale manuale, se aperto,
    // perché la sua posizione è ancorata a un punto fisso dello schermo.
    if (_selection != null) {
      ContextMenuController.removeAny();
    }
  }

  void _registerUnitMount(int index, _SelectableUnitState state) {
    _mountedUnits[index] = state;
  }

  void _unregisterUnitMount(int index, _SelectableUnitState state) {
    if (identical(_mountedUnits[index], state)) {
      _mountedUnits.remove(index);
    }
  }

  // ---------------------------------------------------------------------
  // Hit-test: da una posizione grezza del puntatore a una coordinata
  // logica. Funziona SOLO sull'insieme (piccolo: quanto la viewport)
  // delle unità attualmente montate — è l'unico punto del sistema in cui
  // "il visivo" entra in gioco, ed è inevitabile: non si può sapere dove
  // punta un dito senza guardare cosa c'è disegnato lì sotto.
  // ---------------------------------------------------------------------
  _LogicalOffset? _hitTestGlobalPosition(Offset globalPosition) {
    _SelectableUnitState? nearest;
    double nearestDistance = double.infinity;
    bool nearestIsAbove = false;

    for (final entry in _mountedUnits.entries) {
      final renderBox = entry.value.renderBox;
      if (renderBox == null || !renderBox.attached) continue;
      final topLeft = renderBox.localToGlobal(Offset.zero);
      final rect = topLeft & renderBox.size;

      if (globalPosition.dy >= rect.top && globalPosition.dy <= rect.bottom) {
        return _offsetWithinUnit(entry.key, renderBox, globalPosition);
      }

      final isAbove = globalPosition.dy < rect.top;
      final distance =
          isAbove ? rect.top - globalPosition.dy : globalPosition.dy - rect.bottom;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = entry.value;
        nearestIsAbove = isAbove;
      }
    }

    if (nearest == null) return null;
    final doc = _logicalDocument;
    if (doc == null) return null;
    final length = doc.units[nearest.widget.index].plainText.length;
    return _LogicalOffset(nearest.widget.index, nearestIsAbove ? 0 : length);
  }

  _LogicalOffset _offsetWithinUnit(
      int index, RenderBox renderBox, Offset globalPosition) {
    final doc = _logicalDocument!;
    final unit = doc.units[index];
    final local = renderBox.globalToLocal(globalPosition);
    final width = renderBox.size.width;
    final painter = TextPainter(
      text: TextSpan(text: unit.plainText, style: _hitTestStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width > 0 ? width : double.infinity);
    final position = painter.getPositionForOffset(local);
    return _LogicalOffset(
      index,
      position.offset.clamp(0, unit.plainText.length),
    );
  }

  _LogicalOffset _snapToWordBoundary(
      _LogicalOffset offset, {required bool expandStart}) {
    final doc = _logicalDocument;
    if (doc == null) return offset;
    final text = doc.units[offset.unitIndex].plainText;
    if (text.isEmpty) return offset;
    var i = offset.offset.clamp(0, text.length);
    bool isWordChar(String ch) =>
        ch.trim().isNotEmpty && !_wordBoundaryChars.contains(ch);
    if (expandStart) {
      while (i > 0 && isWordChar(text[i - 1])) {
        i--;
      }
    } else {
      while (i < text.length && isWordChar(text[i])) {
        i++;
      }
    }
    return _LogicalOffset(offset.unitIndex, i);
  }

  static const _wordBoundaryChars = {
    ' ', '\n', '\t', '.', ',', ';', ':', '!', '?', '"', "'", '(', ')', '[', ']',
  };

  // ---------------------------------------------------------------------
  // Puntatore grezzo (osservatore passivo, non entra nell'arena dei
  // gesti: il drag nativo di SelectableRegion continua a funzionare
  // esattamente come sempre, sotto).
  // ---------------------------------------------------------------------
  void _handlePointerDown(PointerDownEvent event) {
    _pointerDownGlobalPosition = event.position;
    _lastPointerGlobalPosition = event.position;

    // Se esiste già una selezione non collassata, questo nuovo tocco
    // potrebbe essere l'utente che ri-afferra una delle due maniglie
    // native per aggiustarla (episodio di gesto separato dal primo: il
    // dito è stato sollevato e riappoggiato). Se il punto toccato è
    // vicino a UNO dei due estremi correnti, teniamo fermo l'estremo
    // opposto e trattiamo quello vicino come il punto che si sposterà
    // (vedi `_updateFocusFromPointer`) — altrimenti (tocco lontano da
    // entrambi) non tocchiamo nulla qui: sarà `_handleNativeSelectionChanged`
    // a decidere, in base a cosa riconosce il motore nativo, se si tratta
    // di un nuovo gesto altrove o di una deselezione.
    final existing = _selection;
    if (existing != null && !existing.isCollapsed) {
      final downOffset = _hitTestGlobalPosition(event.position);
      if (downOffset != null) {
        final nearStart = _isNearExistingEndpoint(downOffset, existing.start);
        final nearEnd = _isNearExistingEndpoint(downOffset, existing.end);
        if (nearStart && !nearEnd) {
          _selection = _LogicalSelection(anchor: existing.end, focus: existing.start);
        } else if (nearEnd && !nearStart) {
          _selection = _LogicalSelection(anchor: existing.start, focus: existing.end);
        }
      }
    }
  }

  /// Approssimazione "logica" (non in pixel) di vicinanza a un estremo
  /// esistente: stessa unità e a non più di una ventina di caratteri di
  /// distanza — sufficiente per distinguere "sto ri-afferrando questa
  /// maniglia" da "sto iniziando una selezione altrove", senza dover
  /// interrogare geometria/pixel aggiuntivi.
  bool _isNearExistingEndpoint(_LogicalOffset touched, _LogicalOffset endpoint) {
    if (touched.unitIndex != endpoint.unitIndex) return false;
    return (touched.offset - endpoint.offset).abs() <= 20;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _lastPointerGlobalPosition = event.position;
    if (_selection == null) return;
    _updateFocusFromPointer(event.position);
    _maybeAutoScroll(event.position);
  }

  void _handlePointerUp(PointerUpEvent event) {
    _lastPointerGlobalPosition = event.position;
    _stopAutoScroll();
    _pointerDownGlobalPosition = null;
    if (_selection != null && !_selection!.isCollapsed) {
      _showSelectionMenu(anchorGlobal: event.position);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _stopAutoScroll();
    _pointerDownGlobalPosition = null;
  }

  void _updateFocusFromPointer(Offset globalPosition) {
    final focus = _hitTestGlobalPosition(globalPosition);
    if (focus == null) return;
    final current = _selection;
    if (current == null || current.focus == focus) return;
    setState(() => _selection = current.withFocus(focus));
  }

  void _maybeAutoScroll(Offset pointerGlobalPosition) {
    final renderBox = _regionKey.currentContext?.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.attached) return;
    final local = renderBox.globalToLocal(pointerGlobalPosition);
    const edge = 56.0;
    final height = renderBox.size.height;

    double direction = 0;
    double overshoot = 0;
    if (local.dy < edge) {
      direction = -1;
      overshoot = edge - local.dy;
    } else if (local.dy > height - edge) {
      direction = 1;
      overshoot = local.dy - (height - edge);
    }

    if (direction == 0) {
      _stopAutoScroll();
      return;
    }

    _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final pos = _lastPointerGlobalPosition;
      if (pos == null || _selection == null || !_scrollController.hasClients) {
        _stopAutoScroll();
        return;
      }
      final speed = (overshoot / 4).clamp(2.0, 18.0);
      final target = (_scrollController.offset + direction * speed)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      if (target != _scrollController.offset) {
        _scrollController.jumpTo(target);
      }
      _updateFocusFromPointer(pos);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  // ---------------------------------------------------------------------
  // Ponte fra il motore nativo (usato solo per riconoscere l'inizio/fine
  // di un episodio di selezione) e quello logico.
  // ---------------------------------------------------------------------
  void _handleNativeSelectionChanged(SelectedContent? content) {
    final isEmpty = (content?.plainText ?? '').isEmpty;
    HapticsHelper.reportSelectionState(isCollapsed: isEmpty);

    if (isEmpty) {
      _stopAutoScroll();
      if (_selection != null) {
        setState(() => _selection = null);
        ContextMenuController.removeAny();
      }
      return;
    }

    if (_selection != null) return; // già tracciata dal nostro motore

    final downPos = _pointerDownGlobalPosition;
    if (downPos == null) return;
    final rawAnchor = _hitTestGlobalPosition(downPos);
    if (rawAnchor == null) return;

    final movePos = _lastPointerGlobalPosition ?? downPos;
    final noRealDragYet = (movePos - downPos).distance < 4.0;

    _LogicalOffset anchor;
    _LogicalOffset focus;
    if (noRealDragYet) {
      // Tap singolo o doppio tap: il motore nativo ha comunque
      // riconosciuto una selezione (tipicamente "la parola sotto il
      // tocco") — replichiamo lo stesso comportamento sul nostro motore.
      anchor = _snapToWordBoundary(rawAnchor, expandStart: true);
      focus = _snapToWordBoundary(rawAnchor, expandStart: false);
    } else {
      anchor = rawAnchor;
      focus = _hitTestGlobalPosition(movePos) ?? rawAnchor;
    }

    setState(() => _selection = _LogicalSelection(anchor: anchor, focus: focus));
  }

  /// "Seleziona tutto": stesso identico meccanismo di una selezione
  /// parziale, solo con estremi che coprono l'intero documento — nessun
  /// trascinamento simulato, nessuna `selectAll()` nativa, nessuna
  /// costruzione forzata di widget.
  Future<void> _performLogicalSelectAll() async {
    final doc = _logicalDocument;
    if (doc == null || doc.units.isEmpty) return;

    final lastUnit = doc.units.length - 1;
    setState(() {
      _selection = _LogicalSelection(
        anchor: const _LogicalOffset(0, 0),
        focus: _LogicalOffset(lastUnit, doc.units[lastUnit].plainText.length),
      );
    });
    HapticsHelper.reportSelectionState(isCollapsed: false);

    if (_scrollController.hasClients) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final renderBox = _regionKey.currentContext?.findRenderObject();
    Offset anchor;
    if (renderBox is RenderBox && renderBox.attached) {
      final topLeft = renderBox.localToGlobal(Offset.zero);
      anchor = Offset(topLeft.dx + renderBox.size.width / 2, topLeft.dy + 32);
    } else {
      anchor = Offset.zero;
    }
    _showSelectionMenu(anchorGlobal: anchor);
  }

  void _showSelectionMenu({required Offset anchorGlobal}) {
    if (!mounted || _selection == null || _selection!.isCollapsed) return;
    _menuController.show(
      context: context,
      contextMenuBuilder: (menuContext) {
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: TextSelectionToolbarAnchors(primaryAnchor: anchorGlobal),
          buttonItems: <ContextMenuButtonItem>[
            ContextMenuButtonItem(
              type: ContextMenuButtonType.copy,
              onPressed: () {
                ContextMenuController.removeAny();
                _copyLogicalSelection();
                _clearSelection();
              },
            ),
            ContextMenuButtonItem(
              label: 'Deseleziona',
              onPressed: () {
                ContextMenuController.removeAny();
                _clearSelection();
              },
            ),
          ],
        );
      },
    );
  }

  void _clearSelection() {
    _stopAutoScroll();
    if (_selection == null) return;
    setState(() => _selection = null);
  }

  /// Testo da copiare per la selezione logica corrente: calcolato
  /// esclusivamente da [_LogicalDocument.textInRange], mai dall'albero dei
  /// widget — corretto carattere per carattere indipendentemente da
  /// quanto della nota sia effettivamente montato.
  String get _textToCopy {
    final sel = _selection;
    final doc = _logicalDocument;
    if (sel == null || doc == null || sel.isCollapsed) return '';
    return doc.textInRange(sel.start, sel.end);
  }

  void _copyLogicalSelection() {
    final text = _textToCopy;
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
  }

  void _ensureStyles(
    ThemeData theme,
    String fontFamily,
    double fontSize,
    double lineHeight,
  ) {
    final key = (theme, fontFamily, fontSize, lineHeight);
    if (_cachedStyleKey == key) return;
    _cachedStyleKey = key;

    _isDark = theme.brightness == Brightness.dark;
    _primaryColor = theme.colorScheme.primary;
    _highlightColor = _primaryColor.withValues(alpha: 0.32);
    _fontSize = fontSize;

    final baseTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: theme.colorScheme.onSurface,
    );
    _hitTestStyle = baseTextStyle;

    _inlineCodeStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize * 0.9,
      height: 1.4,
      color: theme.colorScheme.primary,
    );

    _titleTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize * 2.2,
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );

    _markdownStyleSheet = MarkdownStyleSheet(
      p: baseTextStyle,
      h1: AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * 2.0,
        fontWeight: FontWeight.w800,
        color: theme.colorScheme.onSurface,
        height: 1.3,
      ),
      h2: AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * 1.6,
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurface,
        height: 1.3,
      ),
      h3: AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * 1.3,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurface,
        height: 1.3,
      ),
      blockquote: baseTextStyle.copyWith(
        fontStyle: FontStyle.italic,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
      ),
      blockquoteDecoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.primary,
            width: 4,
          ),
        ),
      ),
      blockquotePadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      code: _inlineCodeStyle,
      codeblockDecoration: const BoxDecoration(),
      codeblockPadding: EdgeInsets.zero,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
      ),
      tableBorder: TableBorder.all(
        color: theme.colorScheme.outline.withValues(alpha: 0.4),
        width: 1,
        borderRadius: BorderRadius.circular(4),
      ),
      tableHead: AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * 0.95,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      ),
      tableBody: baseTextStyle.copyWith(
        fontSize: fontSize * 0.95,
      ),
      tableHeadAlign: TextAlign.center,
      tableCellsPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      listBullet: baseTextStyle.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
      checkbox: TextStyle(
        color: theme.colorScheme.primary,
      ),
      a: TextStyle(
        color: theme.colorScheme.primary,
        decoration: TextDecoration.underline,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  TextSelectionControls get _platformSelectionControls {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return cupertinoTextSelectionControls;
      case TargetPlatform.macOS:
        return cupertinoDesktopTextSelectionControls;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return materialTextSelectionControls;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    if (_cachedContent != widget.content || _cachedTitle != widget.title) {
      _cachedContent = widget.content;
      _cachedTitle = widget.title;
      final effectiveContent =
          widget.content.isEmpty ? '*Nessun contenuto*' : widget.content;
      _cachedBlocks = _splitMarkdownIntoBlocks(effectiveContent);
      _logicalDocument = _LogicalDocument.build(
        title: widget.title,
        blocks: _cachedBlocks!,
      );
      // La nota è cambiata: qualunque selezione precedente si riferiva al
      // documento vecchio e non ha più significato su quello nuovo.
      _selection = null;
      _mountedUnits.clear();
    }

    _ensureStyles(theme, fontFamily, fontSize, lineHeight);

    return _buildFormattedView(theme);
  }

  Widget _buildFormattedView(ThemeData theme) {
    final doc = _logicalDocument!;

    return DefaultSelectionStyle(
      // La vernice nativa è intenzionalmente invisibile: l'unica
      // evidenziazione mostrata è quella disegnata da
      // [_UnitHighlightPainter] a partire da [_selection] (vedi doc di
      // classe). Le maniglie/lente d'ingrandimento native restano visibili
      // e funzionanti: non dipendono da questo colore.
      selectionColor: Colors.transparent,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyA, control: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
          SingleActivator(LogicalKeyboardKey.keyA, meta: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
          SingleActivator(LogicalKeyboardKey.keyC, control: true):
              CopySelectionTextIntent.copy,
          SingleActivator(LogicalKeyboardKey.keyC, meta: true):
              CopySelectionTextIntent.copy,
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
              onInvoke: (intent) {
                unawaited(_performLogicalSelectAll());
                return null;
              },
            ),
            CopySelectionTextIntent:
                CallbackAction<CopySelectionTextIntent>(
              onInvoke: (intent) {
                _copyLogicalSelection();
                return null;
              },
            ),
          },
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerUp,
            onPointerCancel: _handlePointerCancel,
            child: SelectableRegion(
              key: _selectableRegionKey,
              focusNode: _selectionFocusNode,
              selectionControls: _platformSelectionControls,
              onSelectionChanged: _handleNativeSelectionChanged,
              // Il menu nativo resta vuoto di proposito: quello mostrato
              // all'utente è sempre il nostro, aperto esplicitamente da
              // [_showSelectionMenu] con testo e stato coerenti col
              // motore logico (vedi doc di classe).
              contextMenuBuilder: (context, state) => const SizedBox.shrink(),
              child: KeyedSubtree(
                key: _regionKey,
                child: ScrollConfiguration(
                  behavior: _NoGlowScrollBehavior(),
                  child: ListView.builder(
                    key: const ValueKey('markdown-formatted-listview'),
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
                    cacheExtent: _kCacheExtent,
                    itemCount: doc.units.length,
                    itemBuilder: (context, index) {
                      final unit = doc.units[index];
                      final visibleChild = unit.isTitle
                          ? _buildTitleWidget(theme)
                          : _buildMarkdownBlock(index);
                      return _SelectableUnit(
                        index: index,
                        plainText: unit.plainText,
                        hitTestStyle: _hitTestStyle,
                        selection: _selection,
                        highlightColor: _highlightColor,
                        onMount: _registerUnitMount,
                        onUnmount: _unregisterUnitMount,
                        child: visibleChild,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleWidget(ThemeData theme) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: _titleTextStyle,
            ),
            const SizedBox(height: 16),
            Divider(
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
              thickness: 1,
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildMarkdownBlock(int unitIndex) {
    final blockText = _cachedBlocks![_blockIndexFor(unitIndex)];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _MarkdownBlockView(
              key: ValueKey('rendered-block-$unitIndex-${blockText.hashCode}'),
              blockText: blockText,
              styleSheet: _markdownStyleSheet,
              inlineCodeStyle: _inlineCodeStyle,
              fontSize: _fontSize,
              isDark: _isDark,
              primaryColor: _primaryColor,
            ),
          ),
        ),
      ),
    );
  }

  /// L'indice di unità include il titolo (se presente) come unità 0; i
  /// blocchi Markdown veri e propri partono quindi da 1 in quel caso, da 0
  /// altrimenti. `_cachedBlocks` invece è sempre indicizzato solo sui
  /// blocchi, da qui questa piccola conversione.
  int _blockIndexFor(int unitIndex) {
    final hasTitle = _logicalDocument!.units.isNotEmpty &&
        _logicalDocument!.units.first.isTitle;
    return hasTitle ? unitIndex - 1 : unitIndex;
  }

  List<String> _splitMarkdownIntoBlocks(String content) {
    final lines = content.split('\n');
    final blocks = <String>[];
    final currentBlock = <String>[];
    bool inCodeBlock = false;

    for (final line in lines) {
      if (line.trimLeft().startsWith('```')) {
        inCodeBlock = !inCodeBlock;
        currentBlock.add(line);
        if (!inCodeBlock) {
          blocks.add(currentBlock.join('\n'));
          currentBlock.clear();
        }
        continue;
      }

      if (inCodeBlock) {
        currentBlock.add(line);
        continue;
      }

      if (line.trim().isEmpty) {
        if (currentBlock.isNotEmpty) {
          blocks.add(currentBlock.join('\n'));
          currentBlock.clear();
        }
      } else {
        currentBlock.add(line);
      }
    }

    if (currentBlock.isNotEmpty) {
      blocks.add(currentBlock.join('\n'));
    }

    return blocks.isEmpty ? [''] : blocks;
  }
}

/// Involucro per ogni unità (titolo o blocco): traccia il proprio
/// montaggio presso lo State genitore (per l'hit-test del puntatore),
/// porta con sé un doppio invisibile selezionabile dal motore nativo, e
/// disegna l'evidenziazione — tutto derivato da [selection], mai il
/// contrario.
class _SelectableUnit extends StatefulWidget {
  final int index;
  final String plainText;
  final TextStyle hitTestStyle;
  final _LogicalSelection? selection;
  final Color highlightColor;
  final void Function(int index, _SelectableUnitState state) onMount;
  final void Function(int index, _SelectableUnitState state) onUnmount;
  final Widget child;

  const _SelectableUnit({
    required this.index,
    required this.plainText,
    required this.hitTestStyle,
    required this.selection,
    required this.highlightColor,
    required this.onMount,
    required this.onUnmount,
    required this.child,
  });

  @override
  State<_SelectableUnit> createState() => _SelectableUnitState();
}

class _SelectableUnitState extends State<_SelectableUnit> {
  @override
  void initState() {
    super.initState();
    widget.onMount(widget.index, this);
  }

  @override
  void dispose() {
    widget.onUnmount(widget.index, this);
    super.dispose();
  }

  RenderBox? get renderBox => context.findRenderObject() as RenderBox?;

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    return Stack(
      children: [
        if (selection != null)
          Positioned.fill(
            child: IgnorePointer(
              child: _UnitHighlightPainter(
                index: widget.index,
                plainText: widget.plainText,
                style: widget.hitTestStyle,
                selection: selection,
                color: widget.highlightColor,
              ),
            ),
          ),
        // Doppio invisibile: è QUESTO che il motore nativo di selezione
        // vede e trascina — usa esattamente il testo in chiaro del
        // motore logico, così le maniglie native restano coerenti con
        // l'evidenziazione disegnata sopra.
        Opacity(
          opacity: 0,
          child: Text(widget.plainText, style: widget.hitTestStyle),
        ),
        widget.child,
      ],
    );
  }
}

/// Disegna i rettangoli di evidenziazione per un'unità, esclusivamente a
/// partire dalla selezione logica: se l'unità è interamente compresa fra
/// l'inizio e la fine del range, un unico rettangolo pieno; altrimenti (al
/// più le due unità agli estremi del range) i rettangoli esatti calcolati
/// da `TextPainter.getBoxesForSelection` sul testo in chiaro dell'unità.
class _UnitHighlightPainter extends StatelessWidget {
  final int index;
  final String plainText;
  final TextStyle style;
  final _LogicalSelection selection;
  final Color color;

  const _UnitHighlightPainter({
    required this.index,
    required this.plainText,
    required this.style,
    required this.selection,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final s = selection.start;
    final e = selection.end;
    if (index < s.unitIndex || index > e.unitIndex) {
      return const SizedBox.shrink();
    }

    final localStart = index == s.unitIndex ? s.offset.clamp(0, plainText.length) : 0;
    final localEnd = index == e.unitIndex ? e.offset.clamp(0, plainText.length) : plainText.length;
    if (localStart >= localEnd) return const SizedBox.shrink();

    if (localStart == 0 && localEnd == plainText.length) {
      return DecoratedBox(decoration: BoxDecoration(color: color));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.hasBoundedWidth ? constraints.maxWidth : double.infinity;
        final painter = TextPainter(
          text: TextSpan(text: plainText, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width);
        final boxes = painter.getBoxesForSelection(
          TextSelection(baseOffset: localStart, extentOffset: localEnd),
        );
        return Stack(
          children: [
            for (final box in boxes)
              Positioned(
                left: box.left,
                top: box.top,
                width: (box.right - box.left).clamp(0, double.infinity),
                height: (box.bottom - box.top).clamp(0, double.infinity),
                child: DecoratedBox(decoration: BoxDecoration(color: color)),
              ),
          ],
        );
      },
    );
  }
}

class _MarkdownBlockView extends StatefulWidget {
  final String blockText;
  final MarkdownStyleSheet styleSheet;
  final TextStyle inlineCodeStyle;
  final double fontSize;
  final bool isDark;
  final Color primaryColor;

  const _MarkdownBlockView({
    super.key,
    required this.blockText,
    required this.styleSheet,
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
    required this.primaryColor,
  });

  @override
  State<_MarkdownBlockView> createState() => _MarkdownBlockViewState();
}

class _MarkdownBlockViewState extends State<_MarkdownBlockView> {
  Widget? _cachedChild;
  String? _cachedText;
  MarkdownStyleSheet? _cachedStyleSheet;
  double? _cachedFontSize;
  bool? _cachedIsDark;
  Color? _cachedPrimaryColor;

  bool get _cacheHit =>
      _cachedChild != null &&
      _cachedText == widget.blockText &&
      _cachedStyleSheet == widget.styleSheet &&
      _cachedFontSize == widget.fontSize &&
      _cachedIsDark == widget.isDark &&
      _cachedPrimaryColor == widget.primaryColor;

  @override
  Widget build(BuildContext context) {
    if (_cacheHit) {
      return _cachedChild!;
    }

    _cachedText = widget.blockText;
    _cachedStyleSheet = widget.styleSheet;
    _cachedFontSize = widget.fontSize;
    _cachedIsDark = widget.isDark;
    _cachedPrimaryColor = widget.primaryColor;

    _cachedChild = MarkdownBody(
      data: widget.blockText,
      selectable: false,
      styleSheet: widget.styleSheet,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      onTapLink: (text, href, title) async {
        if (href != null && href.isNotEmpty) {
          final uri = Uri.tryParse(href);
          if (uri != null && await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        }
      },
      builders: {
        'code': _CodeBlockBuilder(
          inlineCodeStyle: widget.inlineCodeStyle,
          fontSize: widget.fontSize,
          isDark: widget.isDark,
        ),
      },
    );

    return _cachedChild!;
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final TextStyle inlineCodeStyle;
  final double fontSize;
  final bool isDark;

  _CodeBlockBuilder({
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
  });

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final String text = element.textContent;

    if (element.attributes.containsKey('class') || text.contains('\n')) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            text.trimRight(),
            style: GoogleFonts.jetBrainsMono(
              fontSize: fontSize * 0.85,
              height: 1.4,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: inlineCodeStyle,
      ),
    );
  }
}

class _NoGlowScrollBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}
