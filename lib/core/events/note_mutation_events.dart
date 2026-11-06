import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Segnala le mutazioni delle note che devono raggiungere la sync senza che
/// il dominio delle note conosca il motore di sync.
///
/// PERCHÉ esiste: `SyncNotifier` importa `notesProvider` per leggere e
/// applicare i dati remoti. Se `NotesNotifier` chiamasse direttamente la sync,
/// si ricreerebbe il ciclo note → sync → note. Questo canale vive in `core`,
/// non importa feature, e permette al dominio note di pubblicare un evento
/// senza sapere chi lo consuma.
///
/// Non passa da qui ogni tasto premuto nell'editor: quei salvataggi hanno già
/// i trigger dedicati (cambio nota, inattività, pausa app). Qui arrivano le
/// mutazioni esplicite fuori dall'editor: pin, preferito, metadati,
/// cancellazione e duplicazione.
class NoteMutationEvents extends ChangeNotifier {
  void notifyChanged() => notifyListeners();
}

final noteMutationEventsProvider = Provider<NoteMutationEvents>((ref) {
  final events = NoteMutationEvents();
  ref.onDispose(events.dispose);
  return events;
});
