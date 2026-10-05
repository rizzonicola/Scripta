import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/editor/models/editor_state_model.dart';
import '../constants/app_constants.dart';

/// Ultima posizione dell'utente, letta UNA volta all'avvio (vedi
/// [SessionStateService.load], chiamata da `main()` prima di `runApp`).
///
/// PERCHÉ un'istantanea letta PRIMA del primo frame, invece di far caricare
/// ogni provider in modo asincrono da solo: `EditorNotifier.build()` e lo
/// stato iniziale di `FolderNotifier` sono sincroni, quindi se il valore
/// ripristinato arrivasse dopo, per qualche millisecondo l'app mostrerebbe la
/// posizione di default ("Modifica", "Tutte le note") e poi "scatterebbe"
/// su quella giusta. Con l'istantanea il primo frame è già quello corretto.
///
/// Gli id (cartella, nota) sono solo RIFERIMENTI da validare: la nota o la
/// cartella potrebbero non esistere più (cancellate da un altro dispositivo e
/// arrivate con la sync). Chi li consuma (`NotesNotifier`, `FolderNotifier`)
/// li controlla contro il database e, se mancano, ripiega sul default.
class SessionSnapshot {
  /// Modalità dell'editor: Modifica o Sola lettura ("Visualizza").
  final EditorMode editorMode;

  /// Cartella selezionata; `null` = "Tutte le note".
  final String? folderId;

  /// Nota aperta nell'editor; `null` = nessuna nota salvata.
  final String? noteId;

  /// Solo layout mobile (pannello singolo): `true` se l'ultima schermata
  /// visibile era l'editor, `false` se era la lista delle note.
  final bool mobileEditorOpen;

  const SessionSnapshot({
    this.editorMode = EditorMode.edit,
    this.folderId,
    this.noteId,
    this.mobileEditorOpen = false,
  });
}

/// Istantanea della sessione precedente. Il valore di default (nessuna
/// sessione: "Modifica", "Tutte le note", prima nota) è quello usato dai
/// test e da `ProviderContainer()` senza override; `main()` lo sostituisce con
/// quello letto da disco.
final sessionSnapshotProvider =
    Provider<SessionSnapshot>((ref) => const SessionSnapshot());

/// Lettura e scrittura su SharedPreferences dell'ultima posizione dell'utente.
///
/// Perché SharedPreferences e non SQLite: sono pochi valori scalari di sola
/// interfaccia, necessari in modo sincrono al primo frame. SQLite richiederebbe
/// aprire il database prima di `runApp`, una migrazione di schema, e metterebbe
/// stato "da schermo" accanto a tabelle che la sync legge e invia al server.
/// È anche lo stesso meccanismo che l'app usa già per tema, font e ordinamenti
/// per vista.
///
/// Nessun metodo lancia eccezioni: un problema di I/O sulle preferenze non
/// deve mai impedire l'avvio dell'app né far fallire un'azione dell'utente. Nel
/// caso peggiore si perde la ripresa della posizione, e si riparte dal default.
class SessionStateService {
  const SessionStateService._();

  /// Legge l'ultima posizione salvata. Con preferenze vuote, illeggibili o con
  /// valori di tipo inatteso restituisce il default.
  static Future<SessionSnapshot> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return SessionSnapshot(
        editorMode: _parseMode(prefs.getString(AppConstants.prefSessionEditorMode)),
        folderId: _cleanId(prefs.getString(AppConstants.prefSessionFolderId)),
        noteId: _cleanId(prefs.getString(AppConstants.prefSessionNoteId)),
        mobileEditorOpen:
            prefs.getBool(AppConstants.prefSessionMobileEditorOpen) ?? false,
      );
    } catch (e, st) {
      debugPrint('SessionStateService: ripristino della sessione non riuscito: $e\n$st');
      return const SessionSnapshot();
    }
  }

  static Future<void> saveEditorMode(EditorMode mode) =>
      _write((prefs) => prefs.setString(AppConstants.prefSessionEditorMode, mode.name));

  /// `null` = "Tutte le note": la chiave viene rimossa.
  static Future<void> saveFolderId(String? folderId) =>
      _writeNullableString(AppConstants.prefSessionFolderId, folderId);

  /// `null` = nessuna nota aperta: la chiave viene rimossa, così al prossimo
  /// avvio non si tenta di riaprire una nota che non c'è più.
  static Future<void> saveNoteId(String? noteId) =>
      _writeNullableString(AppConstants.prefSessionNoteId, noteId);

  static Future<void> saveMobileEditorOpen(bool isOpen) =>
      _write((prefs) => prefs.setBool(AppConstants.prefSessionMobileEditorOpen, isOpen));

  static EditorMode _parseMode(String? name) {
    for (final mode in EditorMode.values) {
      if (mode.name == name) return mode;
    }
    return EditorMode.edit;
  }

  /// Una stringa vuota non è un id valido: la si tratta come "assente".
  static String? _cleanId(String? id) => (id == null || id.isEmpty) ? null : id;

  static Future<void> _writeNullableString(String key, String? value) {
    return _write(
      (prefs) => value == null ? prefs.remove(key) : prefs.setString(key, value),
    );
  }

  static Future<void> _write(Future<bool> Function(SharedPreferences prefs) op) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await op(prefs);
    } catch (e, st) {
      debugPrint('SessionStateService: salvataggio della sessione non riuscito: $e\n$st');
    }
  }
}
