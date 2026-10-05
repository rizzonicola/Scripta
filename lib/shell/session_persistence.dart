import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/session_state_service.dart';
import '../features/editor/models/editor_state_model.dart';
import '../features/editor/providers/editor_provider.dart';
import '../features/folders/providers/folder_provider.dart';
import '../features/notes/providers/notes_provider.dart';

/// Salva su disco, a ogni cambiamento, l'ultima posizione dell'utente: modalità
/// dell'editor, cartella selezionata e nota aperta. Il ripristino avviene
/// all'avvio tramite [sessionSnapshotProvider] (vedi `main.dart`).
///
/// PERCHÉ un osservatore unico invece di salvare dentro ogni notifier: la nota
/// attiva cambia in molti punti (selezione dalla lista, scorciatoie
/// Avanti/Indietro, creazione, duplicazione, eliminazione con avanzamento
/// automatico, refresh dopo la sync). Ascoltare lo STATO, anziché instrumentare
/// ogni metodo che lo modifica, garantisce che nessun percorso presente o
/// futuro possa cambiare posizione senza che venga salvata, e lascia i notifier
/// privi di conoscenza della persistenza.
///
/// PERCHÉ si salva subito e non "alla chiusura": l'OS può terminare il processo
/// in background senza alcun preavviso affidabile (`paused` non garantisce di
/// fare in tempo). Sono pochi byte, scritti solo su azioni dell'utente (tocchi
/// e scorciatoie), quindi non serve alcun debounce: niente timer pendenti e
/// l'ultima posizione è su disco pochi millisecondi dopo l'azione.
///
/// `ref.listen` non scatta alla registrazione ma solo sui cambi successivi, per
/// cui all'avvio non sovrascrive mai la sessione salvata con i valori
/// transitori di prima del caricamento dal database.
///
/// Va attivato una sola volta, all'avvio: vedi `ScriptaApp.build`.
final sessionPersistenceProvider = Provider<void>((ref) {
  ref.listen<EditorMode>(
    editorProvider.select((s) => s.mode),
    (previous, next) => unawaited(SessionStateService.saveEditorMode(next)),
  );

  ref.listen<String?>(
    folderProvider.select((s) => s.selectedFolderId),
    (previous, next) => unawaited(SessionStateService.saveFolderId(next)),
  );

  ref.listen<String?>(
    notesProvider.select((s) => s.activeNoteId),
    (previous, next) => unawaited(SessionStateService.saveNoteId(next)),
  );
});
