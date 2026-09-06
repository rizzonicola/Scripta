import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/database/app_database.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
