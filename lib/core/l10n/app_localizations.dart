import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_it.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fr'),
    Locale('it')
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Scripta'**
  String get appName;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'Minimal, Markdown-First Notes'**
  String get appTagline;

  /// No description provided for @allNotes.
  ///
  /// In en, this message translates to:
  /// **'All Notes'**
  String get allNotes;

  /// No description provided for @folders.
  ///
  /// In en, this message translates to:
  /// **'Folders'**
  String get folders;

  /// No description provided for @newFolder.
  ///
  /// In en, this message translates to:
  /// **'New Folder'**
  String get newFolder;

  /// No description provided for @newSubfolder.
  ///
  /// In en, this message translates to:
  /// **'New Subfolder'**
  String get newSubfolder;

  /// No description provided for @folderName.
  ///
  /// In en, this message translates to:
  /// **'Folder Name'**
  String get folderName;

  /// No description provided for @renameFolder.
  ///
  /// In en, this message translates to:
  /// **'Rename Folder'**
  String get renameFolder;

  /// No description provided for @deleteFolder.
  ///
  /// In en, this message translates to:
  /// **'Delete Folder'**
  String get deleteFolder;

  /// No description provided for @deleteFolderConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this folder and its subfolders?'**
  String get deleteFolderConfirmation;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @searchNotes.
  ///
  /// In en, this message translates to:
  /// **'Search notes...'**
  String get searchNotes;

  /// No description provided for @newNote.
  ///
  /// In en, this message translates to:
  /// **'New Note'**
  String get newNote;

  /// No description provided for @noNotes.
  ///
  /// In en, this message translates to:
  /// **'No notes yet'**
  String get noNotes;

  /// No description provided for @noNotesFound.
  ///
  /// In en, this message translates to:
  /// **'No notes match your search'**
  String get noNotesFound;

  /// No description provided for @createFirstNote.
  ///
  /// In en, this message translates to:
  /// **'Create your first note to get started'**
  String get createFirstNote;

  /// No description provided for @untitledNote.
  ///
  /// In en, this message translates to:
  /// **'Untitled Note'**
  String get untitledNote;

  /// No description provided for @writeMarkdownHere.
  ///
  /// In en, this message translates to:
  /// **'Start writing markdown here...'**
  String get writeMarkdownHere;

  /// No description provided for @readOnly.
  ///
  /// In en, this message translates to:
  /// **'Read Only'**
  String get readOnly;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @modeReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read-Only Mode'**
  String get modeReadOnly;

  /// No description provided for @modeEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit Mode'**
  String get modeEdit;

  /// No description provided for @focusMode.
  ///
  /// In en, this message translates to:
  /// **'Focus Mode'**
  String get focusMode;

  /// No description provided for @exitFocusMode.
  ///
  /// In en, this message translates to:
  /// **'Exit Focus Mode'**
  String get exitFocusMode;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// No description provided for @redo.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get redo;

  /// No description provided for @bold.
  ///
  /// In en, this message translates to:
  /// **'Bold'**
  String get bold;

  /// No description provided for @italic.
  ///
  /// In en, this message translates to:
  /// **'Italic'**
  String get italic;

  /// No description provided for @heading1.
  ///
  /// In en, this message translates to:
  /// **'Heading 1'**
  String get heading1;

  /// No description provided for @heading2.
  ///
  /// In en, this message translates to:
  /// **'Heading 2'**
  String get heading2;

  /// No description provided for @heading3.
  ///
  /// In en, this message translates to:
  /// **'Heading 3'**
  String get heading3;

  /// No description provided for @bulletList.
  ///
  /// In en, this message translates to:
  /// **'Bullet List'**
  String get bulletList;

  /// No description provided for @numberedList.
  ///
  /// In en, this message translates to:
  /// **'Numbered List'**
  String get numberedList;

  /// No description provided for @table.
  ///
  /// In en, this message translates to:
  /// **'Table'**
  String get table;

  /// No description provided for @link.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get link;

  /// No description provided for @codeBlock.
  ///
  /// In en, this message translates to:
  /// **'Code Block'**
  String get codeBlock;

  /// No description provided for @copyCode.
  ///
  /// In en, this message translates to:
  /// **'Copy code'**
  String get copyCode;

  /// No description provided for @codeCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied!'**
  String get codeCopied;

  /// No description provided for @taskList.
  ///
  /// In en, this message translates to:
  /// **'Task List'**
  String get taskList;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @themePalette.
  ///
  /// In en, this message translates to:
  /// **'Color Theme'**
  String get themePalette;

  /// No description provided for @themeDarkTeal.
  ///
  /// In en, this message translates to:
  /// **'Scripta Dark (Teal)'**
  String get themeDarkTeal;

  /// No description provided for @themeOled.
  ///
  /// In en, this message translates to:
  /// **'OLED Black'**
  String get themeOled;

  /// No description provided for @themeNord.
  ///
  /// In en, this message translates to:
  /// **'Nord Frost'**
  String get themeNord;

  /// No description provided for @themeMidnightPurple.
  ///
  /// In en, this message translates to:
  /// **'Midnight Iris'**
  String get themeMidnightPurple;

  /// No description provided for @themeForest.
  ///
  /// In en, this message translates to:
  /// **'Pine & Sage'**
  String get themeForest;

  /// No description provided for @themeCoffee.
  ///
  /// In en, this message translates to:
  /// **'Warm Espresso'**
  String get themeCoffee;

  /// No description provided for @themeCleanLight.
  ///
  /// In en, this message translates to:
  /// **'Scripta Light'**
  String get themeCleanLight;

  /// No description provided for @themeSolarizedLight.
  ///
  /// In en, this message translates to:
  /// **'Warm Paper'**
  String get themeSolarizedLight;

  /// No description provided for @sortBy.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get sortBy;

  /// No description provided for @sortUpdatedDesc.
  ///
  /// In en, this message translates to:
  /// **'Last modified (Newest first)'**
  String get sortUpdatedDesc;

  /// No description provided for @sortUpdatedAsc.
  ///
  /// In en, this message translates to:
  /// **'Last modified (Oldest first)'**
  String get sortUpdatedAsc;

  /// No description provided for @sortCreatedDesc.
  ///
  /// In en, this message translates to:
  /// **'Date created (Newest first)'**
  String get sortCreatedDesc;

  /// No description provided for @sortCreatedAsc.
  ///
  /// In en, this message translates to:
  /// **'Date created (Oldest first)'**
  String get sortCreatedAsc;

  /// No description provided for @sortTitleAsc.
  ///
  /// In en, this message translates to:
  /// **'Title (A to Z)'**
  String get sortTitleAsc;

  /// No description provided for @sortTitleDesc.
  ///
  /// In en, this message translates to:
  /// **'Title (Z to A)'**
  String get sortTitleDesc;

  /// No description provided for @sortCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom (Drag & Drop)'**
  String get sortCustom;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get languageSystem;

  /// No description provided for @languageEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEn;

  /// No description provided for @languageIt.
  ///
  /// In en, this message translates to:
  /// **'Italiano'**
  String get languageIt;

  /// No description provided for @languageFr.
  ///
  /// In en, this message translates to:
  /// **'Français'**
  String get languageFr;

  /// No description provided for @typography.
  ///
  /// In en, this message translates to:
  /// **'Typography'**
  String get typography;

  /// No description provided for @fontFamily.
  ///
  /// In en, this message translates to:
  /// **'Font Family'**
  String get fontFamily;

  /// No description provided for @fontSize.
  ///
  /// In en, this message translates to:
  /// **'Font Size'**
  String get fontSize;

  /// No description provided for @lineHeight.
  ///
  /// In en, this message translates to:
  /// **'Line Spacing'**
  String get lineHeight;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About & Credits'**
  String get about;

  /// No description provided for @aboutDescription.
  ///
  /// In en, this message translates to:
  /// **'Scripta is a minimal, distraction-free markdown note-taking tool built for elegance and flow.'**
  String get aboutDescription;

  /// No description provided for @openSourceLicenses.
  ///
  /// In en, this message translates to:
  /// **'Open Source Licenses'**
  String get openSourceLicenses;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @onboardingWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Scripta'**
  String get onboardingWelcomeTitle;

  /// No description provided for @onboardingWelcomeDesc.
  ///
  /// In en, this message translates to:
  /// **'A modern, distraction-free workspace designed exclusively for pure Markdown writing.'**
  String get onboardingWelcomeDesc;

  /// No description provided for @onboardingDualTitle.
  ///
  /// In en, this message translates to:
  /// **'Dual Mode Power'**
  String get onboardingDualTitle;

  /// No description provided for @onboardingDualDesc.
  ///
  /// In en, this message translates to:
  /// **'Switch seamlessly between distraction-free Editing and beautifully rendered Read-Only preview with selectable text and copyable code blocks.'**
  String get onboardingDualDesc;

  /// No description provided for @onboardingFocusTitle.
  ///
  /// In en, this message translates to:
  /// **'Distraction-Free Focus'**
  String get onboardingFocusTitle;

  /// No description provided for @onboardingFocusDesc.
  ///
  /// In en, this message translates to:
  /// **'One tap hides all sidebars, toolbars, and chrome so you can immerse fully in your thoughts.'**
  String get onboardingFocusDesc;

  /// No description provided for @onboardingFoldersTitle.
  ///
  /// In en, this message translates to:
  /// **'Organized Hierarchy'**
  String get onboardingFoldersTitle;

  /// No description provided for @onboardingFoldersDesc.
  ///
  /// In en, this message translates to:
  /// **'Structure your knowledge with unlimited nested folders, custom note ordering, and instant search.'**
  String get onboardingFoldersDesc;

  /// No description provided for @getStarted.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get getStarted;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteNoteConfirmationTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Note'**
  String get deleteNoteConfirmationTitle;

  /// No description provided for @deleteNoteConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this note? This action cannot be undone.'**
  String get deleteNoteConfirmation;

  /// No description provided for @accountServerSection.
  ///
  /// In en, this message translates to:
  /// **'ACCOUNT & SERVER BACKEND'**
  String get accountServerSection;

  /// No description provided for @syncTogglesSection.
  ///
  /// In en, this message translates to:
  /// **'SYNC TOGGLES (SYNCHRONIZATION TRIGGERS)'**
  String get syncTogglesSection;

  /// No description provided for @manualSync.
  ///
  /// In en, this message translates to:
  /// **'Manual Synchronization'**
  String get manualSync;

  /// No description provided for @manualSyncDesc.
  ///
  /// In en, this message translates to:
  /// **'Trigger immediate bidirectional synchronization'**
  String get manualSyncDesc;

  /// No description provided for @syncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync Now'**
  String get syncNow;

  /// No description provided for @syncOnAppLaunch.
  ///
  /// In en, this message translates to:
  /// **'On App Launch'**
  String get syncOnAppLaunch;

  /// No description provided for @syncOnAppLaunchDesc.
  ///
  /// In en, this message translates to:
  /// **'Fetch latest notes and preferences when opening the app'**
  String get syncOnAppLaunchDesc;

  /// No description provided for @syncOnAppLifecycle.
  ///
  /// In en, this message translates to:
  /// **'On Close / Background (App Lifecycle)'**
  String get syncOnAppLifecycle;

  /// No description provided for @syncOnAppLifecycleDesc.
  ///
  /// In en, this message translates to:
  /// **'Send changes to server when app is paused, backgrounded, or closed'**
  String get syncOnAppLifecycleDesc;

  /// No description provided for @syncOnNoteSwitch.
  ///
  /// In en, this message translates to:
  /// **'On Editor Close / Note Switch'**
  String get syncOnNoteSwitch;

  /// No description provided for @syncOnNoteSwitchDesc.
  ///
  /// In en, this message translates to:
  /// **'Sync as soon as you switch notes or leave the editor'**
  String get syncOnNoteSwitchDesc;

  /// No description provided for @syncOnInactivity.
  ///
  /// In en, this message translates to:
  /// **'Automatic on Inactivity (Debounce)'**
  String get syncOnInactivity;

  /// No description provided for @syncOnInactivityDesc.
  ///
  /// In en, this message translates to:
  /// **'Automatically sync after an idle interval while typing'**
  String get syncOnInactivityDesc;

  /// No description provided for @inactivityInterval.
  ///
  /// In en, this message translates to:
  /// **'Inactivity Interval'**
  String get inactivityInterval;

  /// No description provided for @seconds.
  ///
  /// In en, this message translates to:
  /// **'seconds'**
  String get seconds;

  /// No description provided for @inactivityMinDefault.
  ///
  /// In en, this message translates to:
  /// **'Minimum: 10s • Default: 30s'**
  String get inactivityMinDefault;

  /// No description provided for @serverUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Backend Server URL'**
  String get serverUrlLabel;

  /// No description provided for @usernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get usernameLabel;

  /// No description provided for @passwordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordLabel;

  /// No description provided for @connectLogin.
  ///
  /// In en, this message translates to:
  /// **'Login / Connect to Server'**
  String get connectLogin;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @lastSync.
  ///
  /// In en, this message translates to:
  /// **'Last sync'**
  String get lastSync;

  /// No description provided for @never.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get never;

  /// No description provided for @online.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get online;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @syncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing...'**
  String get syncing;

  /// No description provided for @syncSuccess.
  ///
  /// In en, this message translates to:
  /// **'Synchronization completed successfully!'**
  String get syncSuccess;

  /// No description provided for @syncFailed.
  ///
  /// In en, this message translates to:
  /// **'Synchronization failed (check connection)'**
  String get syncFailed;

  /// No description provided for @fillRequiredFields.
  ///
  /// In en, this message translates to:
  /// **'Please fill in all required fields'**
  String get fillRequiredFields;

  /// No description provided for @licenseGpl.
  ///
  /// In en, this message translates to:
  /// **'GPL 3.0 License'**
  String get licenseGpl;

  /// No description provided for @openSourceTech.
  ///
  /// In en, this message translates to:
  /// **'Open Source Libraries & Technologies:'**
  String get openSourceTech;

  /// No description provided for @creditDrift.
  ///
  /// In en, this message translates to:
  /// **'High-performance reactive local relational database'**
  String get creditDrift;

  /// No description provided for @creditSecureStorage.
  ///
  /// In en, this message translates to:
  /// **'Secure storage on Keystore/Keychain for JWT tokens'**
  String get creditSecureStorage;

  /// No description provided for @creditRiverpod.
  ///
  /// In en, this message translates to:
  /// **'Reactive state management & Dependency Injection'**
  String get creditRiverpod;

  /// No description provided for @creditMarkdown.
  ///
  /// In en, this message translates to:
  /// **'CommonMark & GFM parser and rich viewer'**
  String get creditMarkdown;

  /// No description provided for @creditFonts.
  ///
  /// In en, this message translates to:
  /// **'JetBrains Mono & Inter typography'**
  String get creditFonts;

  /// No description provided for @creditSyncArchive.
  ///
  /// In en, this message translates to:
  /// **'REST API synchronization & ZIP compression'**
  String get creditSyncArchive;

  /// No description provided for @replayTutorial.
  ///
  /// In en, this message translates to:
  /// **'Replay Initial Tutorial'**
  String get replayTutorial;

  /// No description provided for @githubRepo.
  ///
  /// In en, this message translates to:
  /// **'GitHub Repository'**
  String get githubRepo;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fr', 'it'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fr':
      return AppLocalizationsFr();
    case 'it':
      return AppLocalizationsIt();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
