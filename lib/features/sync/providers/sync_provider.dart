import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/secure_storage_service.dart';
import '../../../core/services/sync_api_service.dart';
import '../../folders/models/folder_node.dart';
import '../../folders/providers/folder_provider.dart';
import '../../notes/models/note_model.dart';
import '../../notes/providers/notes_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/sync_config.dart';
import '../models/sync_models.dart';

final secureStorageProvider = Provider<SecureStorageService>((ref) {
  return const SecureStorageService();
});

final syncApiServiceProvider = Provider<SyncApiService>((ref) {
  return SyncApiService();
});

class SyncNotifier extends StateNotifier<SyncConfig> {
  static const _prefLaunchSync = 'scripta_sync_on_launch';
  static const _prefLifecycleSync = 'scripta_sync_on_lifecycle';
  static const _prefNoteSwitchSync = 'scripta_sync_on_note_switch';
  static const _prefInactivitySync = 'scripta_sync_on_inactivity';
  static const _prefInactivitySeconds = 'scripta_sync_inactivity_seconds';
  static const _prefLastSyncTime = 'scripta_last_sync_timestamp';

  final Ref _ref;
  final SyncApiService _apiService;
  final SecureStorageService _secureStorage;
  Timer? _inactivityTimer;
  Timer? _noteSwitchDebounceTimer;
  late final Future<void> initialized;

  SyncNotifier(this._ref, this._apiService, this._secureStorage)
      : super(const SyncConfig()) {
    initialized = _init();
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    _noteSwitchDebounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();

    final launchSync = prefs.getBool(_prefLaunchSync) ?? true;
    final lifecycleSync = prefs.getBool(_prefLifecycleSync) ?? true;
    final noteSwitchSync = prefs.getBool(_prefNoteSwitchSync) ?? true;
    final inactivitySync = prefs.getBool(_prefInactivitySync) ?? false;
    final inactivitySeconds = prefs.getInt(_prefInactivitySeconds) ?? 30;

    final lastSyncMillis = prefs.getInt(_prefLastSyncTime);
    final lastSyncTime = lastSyncMillis != null
        ? DateTime.fromMillisecondsSinceEpoch(lastSyncMillis)
        : null;

    final savedServerUrl =
        await _secureStorage.getServerUrl() ?? 'http://localhost:8080';
    final savedUsername = await _secureStorage.getUsername();
    final savedToken = await _secureStorage.getAuthToken();

    if (!mounted) return;

    final hasToken = savedToken != null && savedToken.isNotEmpty;

    state = state.copyWith(
      syncOnAppLaunch: launchSync,
      syncOnAppLifecycle: lifecycleSync,
      syncOnNoteSwitch: noteSwitchSync,
      syncOnInactivity: inactivitySync,
      inactivitySeconds: inactivitySeconds.clamp(10, 3600),
      serverUrl: savedServerUrl,
      username: () => savedUsername,
      isAuthenticated: hasToken,
      lastSyncTime: () => lastSyncTime,
    );

    // Initial health check if server url is present
    if (savedServerUrl.isNotEmpty && mounted) {
      await checkConnection();
    }

    // If authenticated and launch sync enabled, trigger sync & fetch remote settings
    if (hasToken && launchSync && mounted) {
      // Defer slightly to let UI settle
      Future.delayed(const Duration(milliseconds: 500), () async {
        if (!mounted) return;
        await fetchRemoteUserSettings();
        if (!mounted) return;
        await triggerSync();
      });
    }
  }

  Future<bool> checkConnection() async {
    final isOnline = await _apiService.checkHealth(state.serverUrl);
    if (!mounted) return isOnline;
    state = state.copyWith(isOnline: isOnline);
    return isOnline;
  }

  Future<bool> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    state = state.copyWith(
      isSyncing: true,
      lastError: () => null,
      serverUrl: serverUrl,
    );

    try {
      final response = await _apiService.login(
        baseUrl: serverUrl,
        username: username,
        password: password,
      );

      await _secureStorage.saveAuthToken(response.token);
      await _secureStorage.saveServerUrl(serverUrl);
      await _secureStorage.saveUsername(response.username);
      await _secureStorage.saveUserId(response.userId);

      state = state.copyWith(
        isAuthenticated: true,
        isOnline: true,
        username: () => response.username,
        isSyncing: false,
        lastError: () => null,
      );

      // Fetch remote settings & run initial sync
      await fetchRemoteUserSettings();
      await triggerSync();

      return true;
    } catch (e) {
      state = state.copyWith(
        isAuthenticated: false,
        isOnline: false,
        isSyncing: false,
        lastError: () => e is SyncApiException ? e.message : e.toString(),
      );
      return false;
    }
  }

  Future<void> logout() async {
    _inactivityTimer?.cancel();
    await _secureStorage.clearAuth();
    state = state.copyWith(
      isAuthenticated: false,
      username: () => null,
      lastSyncMessage: () => null,
      lastError: () => null,
    );
  }

  Future<void> setSyncOnAppLaunch(bool value) async {
    state = state.copyWith(syncOnAppLaunch: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefLaunchSync, value);
  }

  Future<void> setSyncOnAppLifecycle(bool value) async {
    state = state.copyWith(syncOnAppLifecycle: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefLifecycleSync, value);
  }

  Future<void> setSyncOnNoteSwitch(bool value) async {
    state = state.copyWith(syncOnNoteSwitch: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefNoteSwitchSync, value);
  }

  Future<void> setSyncOnInactivity(bool value) async {
    state = state.copyWith(syncOnInactivity: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefInactivitySync, value);
    if (!value) {
      _inactivityTimer?.cancel();
    }
  }

  Future<void> setInactivitySeconds(int seconds) async {
    final clamped = seconds.clamp(10, 300);
    state = state.copyWith(inactivitySeconds: clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefInactivitySeconds, clamped);
  }

  /// Called whenever note contents change to reset inactivity debounce timer
  void notifyEditorActivity() {
    if (!state.isAuthenticated || !state.syncOnInactivity) return;

    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(
      Duration(seconds: state.inactivitySeconds),
      () {
        if (mounted && !state.isSyncing) {
          triggerSync();
        }
      },
    );
  }

  /// Hook for note change / editor close (debounced by 600ms to avoid bursts during rapid navigation)
  void onNoteChangedOrClosed() {
    if (!state.isAuthenticated || !state.syncOnNoteSwitch) return;

    _noteSwitchDebounceTimer?.cancel();
    _noteSwitchDebounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted && !state.isSyncing) {
        triggerSync();
      }
    });
  }

  /// Hook for app lifecycle (pause / exit)
  void onAppPaused() {
    if (state.isAuthenticated && state.syncOnAppLifecycle && !state.isSyncing) {
      triggerSync();
    }
  }

  /// Helper to resolve relative path for a note, taking folders into account
  String _resolveRelativePath(NoteModel note, List<FolderNode> rootFolders) {
    if (note.relativePath != null && note.relativePath!.isNotEmpty) {
      return note.relativePath!;
    }

    final sanitizedTitle = NotesNotifier.sanitizeFileName(
      note.title.trim().isEmpty ? 'nota_${note.id.substring(0, 8)}' : note.title,
    );

    if (note.folderId == null) {
      return '$sanitizedTitle.md';
    }

    // Build folder breadcrumb
    String? buildPath(FolderNode node, String prefix) {
      final current = prefix.isEmpty ? node.name : '$prefix/${node.name}';
      if (node.id == note.folderId) {
        return current;
      }
      for (final child in node.children) {
        final res = buildPath(child, current);
        if (res != null) return res;
      }
      return null;
    }

    for (final root in rootFolders) {
      final folderPath = buildPath(root, '');
      if (folderPath != null) {
        return '$folderPath/$sanitizedTitle.md';
      }
    }

    return '$sanitizedTitle.md';
  }

  /// Synchronizes notes bidirectionally with the server (Last-Write-Wins)
  Future<bool> triggerSync({bool force = false}) async {
    if (!state.isAuthenticated || state.isSyncing) return false;

    final notesNotifier = _ref.read(notesProvider.notifier);
    // Ensure any in-memory debounced note edits are flushed to local storage state
    notesNotifier.flushPendingSaves();
    final notesState = _ref.read(notesProvider);

    // Fast-path optimization:
    // If no notes were modified locally since lastSyncTime and no tombstones exist,
    // skip network calls unless force is requested.
    final lastSync = state.lastSyncTime;
    final hasTombstones = notesNotifier.tombstones.isNotEmpty;
    final hasModifiedNotes = lastSync == null ||
        notesState.notes.any((n) => n.updatedAt.isAfter(lastSync));

    if (!force && !hasTombstones && !hasModifiedNotes) {
      return true;
    }

    final token = await _secureStorage.getAuthToken();
    if (token == null || token.isEmpty) {
      state = state.copyWith(isAuthenticated: false);
      return false;
    }

    state = state.copyWith(
      isSyncing: true,
      lastError: () => null,
      lastSyncMessage: () => 'Sincronizzazione in corso...',
    );

    try {
      final folderState = _ref.read(folderProvider);

      final changes = <NoteChange>[];

      // 1. Prepare active notes
      for (final note in notesState.notes) {
        final relPath = _resolveRelativePath(note, folderState.rootFolders);
        if (note.relativePath != relPath) {
          notesNotifier.updateNoteRelativePath(note.id, relPath);
        }

        changes.add(
          NoteChange(
            relativePath: relPath,
            content: note.content,
            updatedAt: note.updatedAt.millisecondsSinceEpoch,
            deleted: false,
          ),
        );
      }

      // 2. Prepare tombstones (deleted notes)
      final tombstones = notesNotifier.tombstones;
      for (final t in tombstones) {
        final relPath = t['relative_path'] as String? ?? '';
        final updatedAt = t['updated_at'] as int? ?? DateTime.now().millisecondsSinceEpoch;
        if (relPath.isNotEmpty) {
          changes.add(
            NoteChange(
              relativePath: relPath,
              content: '',
              updatedAt: updatedAt,
              deleted: true,
            ),
          );
        }
      }

      // 3. Send sync request to server
      final response = await _apiService.syncNotes(
        baseUrl: state.serverUrl,
        token: token,
        notes: changes,
      );

      // 4. Purge confirmed tombstones
      final acceptedTombstonePaths = response.accepted
          .where((r) => r.deleted)
          .map((r) => r.relativePath)
          .toList();
      if (acceptedTombstonePaths.isNotEmpty) {
        await notesNotifier.purgeTombstones(acceptedTombstonePaths);
      }

      // 5. Apply server wins (server has newer timestamp or new note)
      for (final serverWin in response.serverWins) {
        String? targetFolderId;
        final parts = serverWin.relativePath.split('/');
        if (parts.length > 1) {
          final folderName = parts.first;
          final existingFolder =
              _ref.read(folderProvider.notifier).findByName(folderName);
          if (existingFolder != null && existingFolder.id.isNotEmpty) {
            targetFolderId = existingFolder.id;
          } else {
            // Auto-create folder for incoming note
            final created =
                _ref.read(folderProvider.notifier).addFolder(folderName);
            targetFolderId = created.id;
          }
        }

        notesNotifier.applyServerNote(
          relativePath: serverWin.relativePath,
          content: serverWin.content ?? '',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(serverWin.updatedAt),
          deleted: serverWin.deleted,
          folderId: targetFolderId,
        );
      }

      final now = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefLastSyncTime, now.millisecondsSinceEpoch);

      state = state.copyWith(
        isOnline: true,
        isSyncing: false,
        lastSyncTime: () => now,
        lastSyncMessage: () => 'Sincronizzato (${response.accepted.length} accettate, ${response.serverWins.length} aggiornate)',
        lastError: () => null,
      );

      return true;
    } catch (e) {
      final isAuthError = e is SyncApiException && e.statusCode == 401;
      state = state.copyWith(
        isAuthenticated: isAuthError ? false : state.isAuthenticated,
        isOnline: !isAuthError,
        isSyncing: false,
        lastError: () => e is SyncApiException ? e.message : e.toString(),
        lastSyncMessage: () => isAuthError
            ? 'Sessione scaduta: effettua nuovamente l\'accesso'
            : 'Sincronizzazione non riuscita',
      );
      if (isAuthError) {
        await _secureStorage.clearAuth();
      }
      return false;
    }
  }

  /// Downloads remote user preferences and applies them locally
  Future<void> fetchRemoteUserSettings() async {
    if (!state.isAuthenticated) return;
    final token = await _secureStorage.getAuthToken();
    if (token == null) return;

    try {
      final remoteSettings = await _apiService.getUserSettings(
        baseUrl: state.serverUrl,
        token: token,
      );
      _ref.read(settingsProvider.notifier).applyRemoteSettings(remoteSettings);
    } catch (e) {
      if (e is SyncApiException && e.statusCode == 401) {
        state = state.copyWith(isAuthenticated: false);
        await _secureStorage.clearAuth();
      }
    }
  }

  /// Sends updated preferences to PUT /api/v1/user/settings
  Future<void> pushUserSettings(UserSettingsDto settings) async {
    if (!state.isAuthenticated) return;
    final token = await _secureStorage.getAuthToken();
    if (token == null) return;

    try {
      await _apiService.updateUserSettings(
        baseUrl: state.serverUrl,
        token: token,
        settings: settings,
      );
    } catch (e) {
      if (e is SyncApiException && e.statusCode == 401) {
        state = state.copyWith(isAuthenticated: false);
        await _secureStorage.clearAuth();
      }
    }
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncConfig>((ref) {
  final apiService = ref.watch(syncApiServiceProvider);
  final secureStorage = ref.watch(secureStorageProvider);
  return SyncNotifier(ref, apiService, secureStorage);
});
