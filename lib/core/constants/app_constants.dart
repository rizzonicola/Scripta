class AppConstants {
  static const String appName = 'Scripta';
  static const String appVersion = '1.0.0';
  static const String appTagline = 'Minimal & Markdown-First Note Taking';
  static const String githubUrl = 'https://github.com/rizzonicola/Scripta';
  static const String appLicense = 'GPL 3.0';

  // Default backend server URL used when the user has never configured one.
  static const String defaultServerUrl = 'https://scripta.poppi.cc';

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
  static const String prefOnboardingCompleted = 'scripta_onboarding_completed';
}
