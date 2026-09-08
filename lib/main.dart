import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/database/app_database.dart';
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

  runApp(
    const ProviderScope(
      child: ScriptaApp(),
    ),
  );
}
