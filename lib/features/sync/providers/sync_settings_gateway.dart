import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/sync_models.dart';

/// Operazioni del motore di sync che servono a `SettingsNotifier` per inviare
/// al server le preferenze di aspetto.
///
/// PERCHÉ esiste: le impostazioni chiamano `syncProvider` per la PUT, mentre
/// `SyncNotifier` deve poter leggere/applicare le stesse impostazioni durante
/// la sync. Importarsi a vicenda creava un ciclo fra i due provider. Il verso
/// "sync → impostazioni" resta diretto (il motore deve poter applicare la
/// fotografia remota); solo il verso "impostazioni → sync" passa da questa
/// interfaccia neutra:
///
///     sync_provider → settings_provider
///     settings_provider → sync_settings_gateway
///
/// `SyncNotifier` si registra alla costruzione. Se il gateway non è ancora
/// disponibile (nessuna sessione di sync creata) l'invio resta in coda finché
/// non arriva un flush successivo: non viene mai perso silenziosamente.
abstract interface class SyncSettingsGateway {
  bool get isAuthenticated;

  /// Restituisce false se la PUT è fallita: il chiamante conserva il payload
  /// e ritenta più tardi.
  Future<bool> pushUserSettings(UserSettingsDto settings);
}

/// Registro mutabile del gateway. Vive in un file neutro (importa solo modelli
/// e Riverpod) così nessuno dei due provider deve importare l'altro.
class SyncSettingsGatewayRegistry {
  SyncSettingsGateway? gateway;

  void register(SyncSettingsGateway value) {
    gateway = value;
  }

  void unregister(SyncSettingsGateway value) {
    if (identical(gateway, value)) gateway = null;
  }
}

final syncSettingsGatewayProvider = Provider<SyncSettingsGatewayRegistry>(
  (ref) => SyncSettingsGatewayRegistry(),
);
