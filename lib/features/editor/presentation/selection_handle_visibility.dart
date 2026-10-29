import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        RenderAnimatedOpacity,
        RenderBox,
        RenderFollowerLayer,
        RenderObject,
        RenderOffstage,
        RenderOpacity;

/// Nome del tipo privato con cui il `SelectionOverlay` di Flutter costruisce
/// ciascuna maniglia (un `StatefulWidget` per maniglia, nell'overlay radice).
///
/// `flutter_md` non espone nulla sulle maniglie, quindi l'unico modo di
/// vederle dall'app è cercarle per questo nome. È FRAGILE per costruzione: se
/// Flutter lo rinominasse non si troverebbe più nessuna maniglia e
/// `_MarkdownRenderedViewState._selectionHandlesNeedRebuild` risponderebbe
/// «ricostruisci» a ogni richiamo (al peggio un lampeggio, nient'altro si
/// romperebbe). È lo stesso criterio di una versione precedente; cambia COSA si
/// guarda una volta trovato il widget (vedi [SelectionHandleStatus]). I build
/// di release non usano `--obfuscate`, quindi il nome è leggibile anche lì.
const String _kSelectionHandleTypeName = '_SelectionHandleOverlay';

/// Stato "reale" di UNA maniglia di selezione: la maniglia è DIPINTA oppure
/// esiste soltanto come widget?
///
/// PERCHÉ NON BASTA SAPERE CHE LA MANIGLIA ESISTE (causa più probabile del
/// sintomo «le maniglie non riappaiono» visto sul tablet)
/// -----------------------------------------------------------------------
/// Una versione precedente della vista rispondeva «sì» appena
/// nell'overlay radice c'era un widget `_SelectionHandleOverlay`. Ma quel
/// widget resta montato per tutta la vita del `SelectionOverlay` anche quando
/// NON si vede, per almeno tre motivi indipendenti:
///  * **non è collegato** ([isLinked]): la maniglia è un follower
///    (`CompositedTransformFollower`) il cui `LayerLink` ha per leader il
///    render object dell'ESTREMO della selezione (dal changelog di
///    `flutter_md` 0.2.0: «Selection endpoints push `LeaderLayer`s from the
///    render objects»; il codice del pacchetto non è stato letto). Se quel
///    render object non è montato (blocco fuori da viewport + `cacheExtent`)
///    o è stato rimontato e nessuno ha ricollegato il link, `LayerLink.leader`
///    è `null` (doc API di Flutter) e, con `showWhenUnlinked: false` (come il
///    framework costruisce le maniglie: ricordato a memoria,
///    `_SelectionHandleOverlay` non è stato riletto), il follower non dipinge
///    nulla (doc di `showWhenUnlinked`);
///  * **opacità zero** ([opacity]): `startHandlesVisible` /
///    `endHandlesVisible` di `SelectionOverlay` pilotano una `FadeTransition`
///    che dissolve la maniglia senza smontarla (doc API di
///    `SelectionOverlay.startHandlesVisible`);
///  * **`Offstage`** ([isOffstage]) in un antenato.
///
/// Per questo qui si risale la catena dei `RenderObject` dalla foglia della
/// maniglia fino alla radice moltiplicando le opacità e controllando follower
/// scollegati e `RenderOffstage`: sono le stesse cose che decidono se un pixel
/// arriva sullo schermo.
@immutable
class SelectionHandleStatus {
  const SelectionHandleStatus({
    required this.isLinked,
    required this.opacity,
    required this.isOffstage,
    this.rect,
  });

  /// `false` se la maniglia segue un `LayerLink` senza leader e non è
  /// configurata per mostrarsi da scollegata: il widget c'è ma non viene
  /// dipinto (tipicamente l'estremo della selezione non è montato).
  final bool isLinked;

  /// Opacità effettiva: prodotto di tutte le opacità (`FadeTransition`,
  /// `Opacity`) dalla foglia della maniglia alla radice dell'albero.
  final double opacity;

  /// `true` se un antenato è un `Offstage` attivo.
  final bool isOffstage;

  /// Rettangolo globale della maniglia vera e propria (la foglia, non l'area
  /// di tocco allargata), calcolato con la trasformazione dell'ULTIMO frame
  /// composto; `null` se non misurabile.
  final Rect? rect;

  /// La maniglia viene davvero dipinta (collegata, opaca, non fuori scena).
  /// Non dice dove: per quello vedi [isVisibleIn].
  bool get isPainted => isLinked && opacity > 0 && !isOffstage;

  /// [isPainted] e il rettangolo cade (almeno in parte) dentro [viewport].
  bool isVisibleIn(Rect viewport) {
    final handleRect = rect;
    return isPainted && handleRect != null && handleRect.overlaps(viewport);
  }

  @override
  String toString() =>
      'SelectionHandleStatus(painted: $isPainted, '
      'linked: $isLinked, opacity: ${opacity.toStringAsFixed(2)}, '
      'offstage: $isOffstage, rect: $rect)';
}

/// Stato reale di TUTTE le maniglie di selezione presenti nell'overlay radice
/// (di norma 0 oppure 2: inizio e fine). Lista vuota se non ce n'è nessuna.
///
/// Il criterio per TROVARE le maniglie è per nome del tipo (vedi
/// [_kSelectionHandleTypeName]); quello che conta è però cosa si misura una
/// volta trovate: non «esiste», ma «è dipinta» ([SelectionHandleStatus]).
/// Se una maniglia non è analizzabile (render object assente, eccezione
/// durante la misura) è riportata come NON dipinta: l'errore è nella
/// direzione che ricostruisce l'overlay (al peggio un lampeggio) e non in
/// quella che lascia le maniglie nascoste.
List<SelectionHandleStatus> inspectSelectionHandles(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return const <SelectionHandleStatus>[];

  final statuses = <SelectionHandleStatus>[];
  void visit(Element element) {
    final candidate = element.widget;
    if (candidate is StatefulWidget &&
        candidate.runtimeType.toString() == _kSelectionHandleTypeName) {
      statuses.add(_statusOf(element));
      // Una maniglia non ne contiene altre: non serve scendere.
      return;
    }
    element.visitChildren(visit);
  }

  (overlay.context as Element).visitChildren(visit);
  return statuses;
}

SelectionHandleStatus _statusOf(Element element) {
  const unknown = SelectionHandleStatus(
    isLinked: false,
    opacity: 0,
    isOffstage: false,
  );
  try {
    final top = element.renderObject;
    if (top == null) return unknown;
    final leaf = _firstLeaf(top);

    var opacity = 1.0;
    var isLinked = true;
    var isOffstage = false;
    // Dalla foglia alla radice: la `FadeTransition` della maniglia sta SOTTO
    // il follower, `Offstage`/`Opacity` eventuali stanno SOPRA: risalendo si
    // incontrano tutti.
    for (RenderObject? node = leaf; node != null; node = node.parent) {
      if (node is RenderAnimatedOpacity) {
        opacity *= node.opacity.value;
      } else if (node is RenderOpacity) {
        opacity *= node.opacity;
      } else if (node is RenderOffstage) {
        if (node.offstage) {
          isOffstage = true;
        }
      } else if (node is RenderFollowerLayer) {
        if (!node.showWhenUnlinked && node.link.leader == null) {
          isLinked = false;
        }
      }
    }

    // Il rettangolo si misura su un DISCENDENTE del follower, mai sul
    // follower stesso: `RenderFollowerLayer.applyPaintTransform` applica la
    // trasformazione dell'ultimo frame composto ai figli, mentre la posizione
    // del follower nel suo genitore non sa nulla del leader.
    final Rect? rect = leaf is RenderBox && leaf.attached && leaf.hasSize
        ? leaf.localToGlobal(Offset.zero) & leaf.size
        : null;

    return SelectionHandleStatus(
      isLinked: isLinked,
      opacity: opacity,
      isOffstage: isOffstage,
      rect: rect,
    );
  } catch (_) {
    return unknown;
  }
}

/// Scende lungo il primo figlio di ogni `RenderObject` fino alla foglia: per
/// una maniglia è la catena Follower > FadeTransition > Container > ... >
/// disegno della maniglia, tutta a figlio singolo.
RenderObject _firstLeaf(RenderObject start) {
  var current = start;
  while (true) {
    RenderObject? first;
    current.visitChildren((child) {
      first ??= child;
    });
    final next = first;
    if (next == null) return current;
    current = next;
  }
}
