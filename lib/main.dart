import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/database/app_database.dart';
import 'core/services/session_state_service.dart';
import 'core/services/window_decoration_service.dart';
import 'core/utils/haptic_gating_binding.dart';

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

  runApp(
    ProviderScope(
      overrides: [
        sessionSnapshotProvider.overrideWithValue(session),
      ],
      child: const ScriptaApp(),
    ),
  );
}
