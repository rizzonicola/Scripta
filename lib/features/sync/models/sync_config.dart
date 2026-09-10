import '../../../core/constants/app_constants.dart';

class SyncConfig {
  final bool syncOnAppLaunch;
  final bool syncOnAppLifecycle;
  final bool syncOnNoteSwitch;
  final bool syncOnInactivity;
  final int inactivitySeconds; // minimum 10, default 30
  final String serverUrl;
  final String? username;
  final bool isAuthenticated;
  final bool isOnline;
  final bool isSyncing;
  final DateTime? lastSyncTime;
  final String? lastSyncMessage;
  final String? lastError;

  const SyncConfig({
    this.syncOnAppLaunch = true,
    this.syncOnAppLifecycle = true,
    this.syncOnNoteSwitch = true,
    this.syncOnInactivity = false,
    this.inactivitySeconds = 30,
    this.serverUrl = AppConstants.defaultServerUrl,
    this.username,
    this.isAuthenticated = false,
    this.isOnline = false,
    this.isSyncing = false,
    this.lastSyncTime,
    this.lastSyncMessage,
    this.lastError,
  });

  SyncConfig copyWith({
    bool? syncOnAppLaunch,
    bool? syncOnAppLifecycle,
    bool? syncOnNoteSwitch,
    bool? syncOnInactivity,
    int? inactivitySeconds,
    String? serverUrl,
    String? Function()? username,
    bool? isAuthenticated,
    bool? isOnline,
    bool? isSyncing,
    DateTime? Function()? lastSyncTime,
    String? Function()? lastSyncMessage,
    String? Function()? lastError,
  }) {
    return SyncConfig(
      syncOnAppLaunch: syncOnAppLaunch ?? this.syncOnAppLaunch,
      syncOnAppLifecycle: syncOnAppLifecycle ?? this.syncOnAppLifecycle,
      syncOnNoteSwitch: syncOnNoteSwitch ?? this.syncOnNoteSwitch,
      syncOnInactivity: syncOnInactivity ?? this.syncOnInactivity,
      inactivitySeconds: inactivitySeconds ?? this.inactivitySeconds,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username != null ? username() : this.username,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      isOnline: isOnline ?? this.isOnline,
      isSyncing: isSyncing ?? this.isSyncing,
      lastSyncTime: lastSyncTime != null ? lastSyncTime() : this.lastSyncTime,
      lastSyncMessage:
          lastSyncMessage != null ? lastSyncMessage() : this.lastSyncMessage,
      lastError: lastError != null ? lastError() : this.lastError,
    );
  }

  // Uguaglianza per valore: senza questa, `StateNotifier` (che confronta
  // `_state == value` prima di notificare i listener) tratta OGNI
  // `copyWith` come "cambiato" anche quando produce valori identici a
  // quelli già presenti — rilevante soprattutto per il poll periodico di
  // connettività (ogni 25s), che altrimenti farebbe ricostruire tutti i
  // widget che osservano `syncProvider` anche quando `isOnline` non cambia
  // davvero.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SyncConfig &&
        other.syncOnAppLaunch == syncOnAppLaunch &&
        other.syncOnAppLifecycle == syncOnAppLifecycle &&
        other.syncOnNoteSwitch == syncOnNoteSwitch &&
        other.syncOnInactivity == syncOnInactivity &&
        other.inactivitySeconds == inactivitySeconds &&
        other.serverUrl == serverUrl &&
        other.username == username &&
        other.isAuthenticated == isAuthenticated &&
        other.isOnline == isOnline &&
        other.isSyncing == isSyncing &&
        other.lastSyncTime == lastSyncTime &&
        other.lastSyncMessage == lastSyncMessage &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hash(
        syncOnAppLaunch,
        syncOnAppLifecycle,
        syncOnNoteSwitch,
        syncOnInactivity,
        inactivitySeconds,
        serverUrl,
        username,
        isAuthenticated,
        isOnline,
        isSyncing,
        lastSyncTime,
        lastSyncMessage,
        lastError,
      );
}
