// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Scripta';

  @override
  String get appTagline => 'Minimal, Markdown-First Notes';

  @override
  String get allNotes => 'All Notes';

  @override
  String get folders => 'Folders';

  @override
  String get newFolder => 'New Folder';

  @override
  String get newSubfolder => 'New Subfolder';

  @override
  String get folderName => 'Folder Name';

  @override
  String get renameFolder => 'Rename Folder';

  @override
  String get deleteFolder => 'Delete Folder';

  @override
  String get deleteFolderConfirmation =>
      'Are you sure you want to delete this folder and its subfolders?';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirm => 'Confirm';

  @override
  String get save => 'Save';

  @override
  String get searchNotes => 'Search notes...';

  @override
  String get newNote => 'New Note';

  @override
  String get noNotes => 'No notes yet';

  @override
  String get noNotesFound => 'No notes match your search';

  @override
  String get createFirstNote => 'Create your first note to get started';

  @override
  String get untitledNote => 'Untitled Note';

  @override
  String get writeMarkdownHere => 'Start writing markdown here...';

  @override
  String get readOnly => 'Read Only';

  @override
  String get edit => 'Edit';

  @override
  String get modeReadOnly => 'Read-Only Mode';

  @override
  String get modeEdit => 'Edit Mode';

  @override
  String get focusMode => 'Focus Mode';

  @override
  String get exitFocusMode => 'Exit Focus Mode';

  @override
  String get undo => 'Undo';

  @override
  String get redo => 'Redo';

  @override
  String get bold => 'Bold';

  @override
  String get italic => 'Italic';

  @override
  String get heading1 => 'Heading 1';

  @override
  String get heading2 => 'Heading 2';

  @override
  String get heading3 => 'Heading 3';

  @override
  String get bulletList => 'Bullet List';

  @override
  String get numberedList => 'Numbered List';

  @override
  String get table => 'Table';

  @override
  String get link => 'Link';

  @override
  String get codeBlock => 'Code Block';

  @override
  String get copyCode => 'Copy code';

  @override
  String get codeCopied => 'Copied!';

  @override
  String get taskList => 'Task List';

  @override
  String get settings => 'Settings';

  @override
  String get theme => 'Theme';

  @override
  String get themeSystem => 'System Default';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themePalette => 'Color Theme';

  @override
  String get themeDarkTeal => 'Scripta Dark (Teal)';

  @override
  String get themeOled => 'OLED Black';

  @override
  String get themeNord => 'Nord Frost';

  @override
  String get themeMidnightPurple => 'Midnight Iris';

  @override
  String get themeForest => 'Pine & Sage';

  @override
  String get themeCoffee => 'Warm Espresso';

  @override
  String get themeCleanLight => 'Scripta Light';

  @override
  String get themeSolarizedLight => 'Warm Paper';

  @override
  String get sortBy => 'Sort by';

  @override
  String get sortUpdatedDesc => 'Last modified (Newest first)';

  @override
  String get sortUpdatedAsc => 'Last modified (Oldest first)';

  @override
  String get sortCreatedDesc => 'Date created (Newest first)';

  @override
  String get sortCreatedAsc => 'Date created (Oldest first)';

  @override
  String get sortTitleAsc => 'Title (A to Z)';

  @override
  String get sortTitleDesc => 'Title (Z to A)';

  @override
  String get sortCustom => 'Custom (Drag & Drop)';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System Default';

  @override
  String get languageEn => 'English';

  @override
  String get languageIt => 'Italiano';

  @override
  String get languageFr => 'Français';

  @override
  String get typography => 'Typography';

  @override
  String get fontFamily => 'Font Family';

  @override
  String get fontSize => 'Font Size';

  @override
  String get lineHeight => 'Line Spacing';

  @override
  String get about => 'About & Credits';

  @override
  String get aboutDescription =>
      'Scripta is a minimal, distraction-free markdown note-taking tool built for elegance and flow.';

  @override
  String get openSourceLicenses => 'Open Source Licenses';

  @override
  String get version => 'Version';

  @override
  String get onboardingWelcomeTitle => 'Welcome to Scripta';

  @override
  String get onboardingWelcomeDesc =>
      'A modern, distraction-free workspace designed exclusively for pure Markdown writing.';

  @override
  String get onboardingDualTitle => 'Dual Mode Power';

  @override
  String get onboardingDualDesc =>
      'Switch seamlessly between distraction-free Editing and beautifully rendered Read-Only preview with selectable text and copyable code blocks.';

  @override
  String get onboardingFocusTitle => 'Distraction-Free Focus';

  @override
  String get onboardingFocusDesc =>
      'One tap hides all sidebars, toolbars, and chrome so you can immerse fully in your thoughts.';

  @override
  String get onboardingFoldersTitle => 'Organized Hierarchy';

  @override
  String get onboardingFoldersDesc =>
      'Structure your knowledge with unlimited nested folders, custom note ordering, and instant search.';

  @override
  String get getStarted => 'Get Started';

  @override
  String get next => 'Next';

  @override
  String get skip => 'Skip';

  @override
  String get delete => 'Delete';

  @override
  String get deleteNoteConfirmationTitle => 'Delete Note';

  @override
  String get deleteNoteConfirmation =>
      'Are you sure you want to delete this note? This action cannot be undone.';

  @override
  String get accountServerSection => 'ACCOUNT & SERVER BACKEND';

  @override
  String get syncTogglesSection => 'SYNC TOGGLES (SYNCHRONIZATION TRIGGERS)';

  @override
  String get manualSync => 'Manual Synchronization';

  @override
  String get manualSyncDesc =>
      'Trigger immediate bidirectional synchronization';

  @override
  String get syncNow => 'Sync Now';

  @override
  String get syncOnAppLaunch => 'On App Launch';

  @override
  String get syncOnAppLaunchDesc =>
      'Fetch latest notes and preferences when opening the app';

  @override
  String get syncOnAppLifecycle => 'On Close / Background (App Lifecycle)';

  @override
  String get syncOnAppLifecycleDesc =>
      'Send changes to server when app is paused, backgrounded, or closed';

  @override
  String get syncOnNoteSwitch => 'On Editor Close / Note Switch';

  @override
  String get syncOnNoteSwitchDesc =>
      'Sync as soon as you switch notes or leave the editor';

  @override
  String get syncOnInactivity => 'Automatic on Inactivity (Debounce)';

  @override
  String get syncOnInactivityDesc =>
      'Automatically sync after an idle interval while typing';

  @override
  String get inactivityInterval => 'Inactivity Interval';

  @override
  String get seconds => 'seconds';

  @override
  String get inactivityMinDefault => 'Minimum: 10s • Default: 30s';

  @override
  String get serverUrlLabel => 'Backend Server URL';

  @override
  String get usernameLabel => 'Username';

  @override
  String get passwordLabel => 'Password';

  @override
  String get connectLogin => 'Login / Connect to Server';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get lastSync => 'Last sync';

  @override
  String get never => 'Never';

  @override
  String get online => 'Online';

  @override
  String get offline => 'Offline';

  @override
  String get syncing => 'Syncing...';

  @override
  String get syncSuccess => 'Synchronization completed successfully!';

  @override
  String get syncFailed => 'Synchronization failed (check connection)';

  @override
  String get fillRequiredFields => 'Please fill in all required fields';

  @override
  String get licenseGpl => 'GPL 3.0 License';

  @override
  String get openSourceTech => 'Open Source Libraries & Technologies:';

  @override
  String get creditDrift =>
      'High-performance reactive local relational database';

  @override
  String get creditSecureStorage =>
      'Secure storage on Keystore/Keychain for JWT tokens';

  @override
  String get creditRiverpod =>
      'Reactive state management & Dependency Injection';

  @override
  String get creditMarkdown => 'CommonMark & GFM parser and rich viewer';

  @override
  String get creditFonts => 'JetBrains Mono & Inter typography';

  @override
  String get creditSyncArchive => 'REST API synchronization & ZIP compression';

  @override
  String get replayTutorial => 'Replay Initial Tutorial';

  @override
  String get githubRepo => 'GitHub Repository';
}
