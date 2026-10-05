class AppConstants {
  static const String appName = 'Scripta';
  static const String appVersion = '1.0.0';
  static const String appTagline = 'Minimal & Markdown-First Note Taking';
  static const String githubUrl = 'https://github.com/rizzonicola/Scripta';

  // NESSUN server di default: l'app non deve mai inviare credenziali o dati
  // a un server di terzi senza che l'utente ne abbia indicato uno. Il campo
  // "Server" parte vuoto; questo è solo il segnaposto (dominio riservato
  // example.com, RFC 2606) mostrato come suggerimento di formato.
  static const String serverUrlPlaceholder = 'https://notes.example.com';

  // Breakpoints
  static const double mobileBreakpoint = 600.0;
  static const double tabletBreakpoint = 1024.0;

  // Sidebar widths
  static const double folderSidebarWidth = 240.0;
  static const double notesListWidth = 320.0;

  // Preferences keys
  static const String prefLocale = 'scripta_locale';
  static const String prefThemeMode = 'scripta_theme_mode';
  static const String prefThemeId = 'scripta_theme_id';
  static const String prefFontFamily = 'scripta_font_family';
  static const String prefFontSize = 'scripta_font_size';
  static const String prefLineHeight = 'scripta_line_height';
  static const String prefSortMode = 'scripta_sort_mode';
  // Ordinamento PER VISTA ("Tutte le note" e ogni cartella): mappa JSON
  // scope -> nome del NoteSortOrder, e (solo per le cartelle) mappa JSON
  // scope -> elenco ordinato di id per l'ordine manuale. `prefSortMode` resta
  // solo come valore iniziale di ripiego (compatibilità con versioni precedenti).
  static const String prefSortModeByScope = 'scripta_sort_mode_by_scope';
  static const String prefCustomOrderByScope = 'scripta_custom_order_by_scope';
  static const String prefOnboardingCompleted = 'scripta_onboarding_completed';
  static const String prefHapticIntensity = 'scripta_haptic_intensity';

  // Ripresa della sessione: l'ultima posizione dell'utente (modalità
  // Modifica/Visualizza, cartella, nota aperta, pannello editor su mobile).
  // Puramente locali: non fanno parte del payload di sync. Vedi
  // core/services/session_state_service.dart.
  static const String prefSessionEditorMode = 'scripta_session_editor_mode';
  static const String prefSessionFolderId = 'scripta_session_folder_id';
  static const String prefSessionNoteId = 'scripta_session_note_id';
  static const String prefSessionMobileEditorOpen = 'scripta_session_mobile_editor_open';
}
