import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/database/app_database.dart';
import 'core/services/session_state_service.dart';
import 'core/services/window_decoration_service.dart';
import 'core/utils/haptic_gating_binding.dart';
import 'core/utils/perf_marks.dart';
import 'features/settings/providers/settings_provider.dart';

void main() async {
  // Sostituisce WidgetsFlutterBinding.ensureInitialized(): la semplice
  // istanziazione registra la binding personalizzata come singleton (stesso
  // meccanismo di ensureInitialized(), vedi doc in haptic_gating_binding.dart),
  // installando il filtro che permette alle intensità "Disattivata" e
  // "Leggera" di sopprimere anche la vibrazione nativa che Flutter genera
  // autonomamente durante la selezione di testo.
  ScriptaWidgetsFlutterBinding();

  // Inizializza il database factory corretto per la piattaforma (sqflite su
  // Android/iOS, sqflite_common_ffi su desktop) PRIMA che qualunque
  // provider Riverpod possa tentare di aprire il database locale
  // (folderProvider/notesProvider/syncProvider lo fanno nel loro
  // costruttore, eseguito alla prima lettura del provider).
  AppDatabase.ensureFactoryInitialized();

  // Apre il database ORA, in parallelo alla lettura delle preferenze più sotto
  // (unico `await` prima del primo frame): quando i provider lo chiederanno
  // sarà già aperto o a metà strada. Non attende e non propaga errori: vedi
  // AppDatabase.warmUp. Va DOPO la riga sopra, che sceglie il factory.
  AppDatabase.warmUp();

  // Listener globale per il fullscreen "di sistema" (F11): registrato a
  // livello di HardwareKeyboard, quindi prima di runApp, così funziona
  // ovunque nell'app indipendentemente da quale widget ha il focus.
  WindowDecorationService.initializeFullScreenShortcut();

  // Ultima posizione dell'utente (modalità Modifica/Visualizza, cartella,
  // nota aperta, pannello mobile), letta PRIMA del primo frame: i provider
  // partono già dallo stato giusto invece di mostrare per un istante quello di
  // default e poi "scattare". Non lancia mai: nel caso peggiore restituisce
  // il default (vedi SessionStateService.load).
  final session = await SessionStateService.load();

  // Impostazioni (tema, font, lingua, aptica), lette come la sessione PRIMA del
  // primo frame: il primo build usa già quelle salvate invece dei default.
  // `SharedPreferences.getInstance()` è memoizzato dal pacchetto, quindi dopo
  // la riga precedente non c'è altro I/O. Non lancia mai (vedi la funzione).
  final settings = await loadSettingsSnapshot();

  // Fine dell'unico lavoro prima del primo frame (vedi PerfMarks).
  PerfMarks.instant('scripta.main.beforeRunApp');

  runApp(
    ProviderScope(
      overrides: [
        sessionSnapshotProvider.overrideWithValue(session),
        settingsSnapshotProvider.overrideWithValue(settings),
      ],
      child: const ScriptaApp(),
    ),
  );
}
