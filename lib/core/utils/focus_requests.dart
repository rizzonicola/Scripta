import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Contatore "richiesta di focus": incrementarlo chiede al widget che lo
/// ascolta di portare il focus sul proprio campo di testo. Serve alle
/// scorciatoie globali (Ctrl+F, Ctrl+Shift+F) per raggiungere campi che
/// vivono in altre parti dell'albero senza condividere FocusNode.
class FocusRequestNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state = state + 1;
}

/// Focus sul campo di ricerca globale (lista note).
final globalSearchFocusRequestProvider =
    NotifierProvider<FocusRequestNotifier, int>(FocusRequestNotifier.new);

/// Focus sul campo della ricerca interna alla nota.
final noteSearchFocusRequestProvider =
    NotifierProvider<FocusRequestNotifier, int>(FocusRequestNotifier.new);
