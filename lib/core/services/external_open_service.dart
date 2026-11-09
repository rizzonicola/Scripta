import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Da dove arriva una richiesta di apertura esterna.
///
/// La distinzione serve al drag & drop: un file trascinato va inserito nella
/// cartella già selezionata nell'app, mentre "Apri con Scripta" deve chiedere
/// la destinazione all'utente.
enum ExternalOpenSource { system, dragDrop }

/// Richiesta di apertura esterna con la sua provenienza.
class ExternalOpenRequest {
  const ExternalOpenRequest({required this.paths, required this.source});

  final List<String> paths;
  final ExternalOpenSource source;
}

typedef ExternalOpenListener = void Function(ExternalOpenRequest request);

/// File o cartelle che il sistema operativo chiede di aprire in Scripta:
/// "Apri con Scripta", argomenti della riga di comando e drag & drop.
///
/// Il servizio fa da punto d'ingresso unico e da coda: gli eventi possono
/// arrivare PRIMA che l'interfaccia sia pronta (avvio del processo con un file
/// da aprire, evento macOS consegnato durante il launch) e in quel caso
/// restano in [_pending] finché non viene registrato un listener.
///
/// La consegna è volutamente separata dall'elaborazione: qui si normalizzano
/// soltanto percorsi e URI, mentre file/cartelle vengono letti e trasformati
/// in note da `ExternalOpenProcessor` (con i notifier Riverpod già pronti).
class ExternalOpenService {
  ExternalOpenService._();

  static final ExternalOpenService instance = ExternalOpenService._();

  static const MethodChannel _channel = MethodChannel(
    'io.github.scripta/external_open',
  );

  /// Argomenti che iniziano con un trattino sono opzioni del motore Flutter
  /// (o della riga di comando), non file da aprire.
  static Iterable<String> commandLineTargets(List<String> arguments) =>
      arguments.where((arg) => arg.isNotEmpty && !arg.startsWith('-'));

  /// `true` solo sulle piattaforme desktop in cui esiste un ingresso nativo.
  static bool get isSupported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  static final RegExp _windowsDrivePath = RegExp(r'^[A-Za-z]:[\\/]');

  /// Accetta un percorso nativo oppure un URI `file://` (Linux e macOS
  /// passano i file aperti come URI, anche quando contengono spazi o caratteri
  /// percent-encoded). Restituisce `null` per valori vuoti o non-file.
  static String? normalizeOpenTarget(String raw) {
    var value = raw.trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.isEmpty) return null;

    // Su Windows `C:\...` e `\\server\share` non sono URI: vanno restituiti
    // prima di `Uri.tryParse`, che li interpreterebbe come schemi.
    if (_windowsDrivePath.hasMatch(value) || value.startsWith(r'\\')) {
      return value;
    }

    if (value.startsWith('file:')) {
      try {
        return Uri.parse(value).toFilePath();
      } catch (_) {
        return null;
      }
    }

    return value;
  }

  final List<ExternalOpenRequest> _pending = <ExternalOpenRequest>[];
  final Set<ExternalOpenListener> _listeners = <ExternalOpenListener>{};

  bool _initialized = false;

  /// Registra il metodo nativo e accoda gli eventuali file passati sulla riga
  /// di comando. Va chiamato una sola volta, subito dopo il binding Flutter.
  Future<void> initialize(List<String> arguments) async {
    if (!isSupported) return;

    if (!_initialized) {
      _initialized = true;
      _channel.setMethodCallHandler(_handleNativeCall);
    }
    addPaths(commandLineTargets(arguments));
  }

  /// Collega l'interfaccia. Gli eventi arrivati prima di questo momento
  /// vengono consegnati subito; su macOS si chiede anche al nativo se ha
  /// messo da parte file aperti durante il launch.
  void attach(ExternalOpenListener listener) {
    if (!isSupported) return;
    if (_listeners.add(listener)) {
      _flushPending();
      if (Platform.isMacOS) {
        unawaited(_requestPendingFromNative());
      }
    }
  }

  void detach(ExternalOpenListener listener) {
    _listeners.remove(listener);
  }

  /// Ingerisce percorsi o URI da qualunque sorgente (drag & drop, test,
  /// argomenti già normalizzati). [source] distingue l'apertura richiesta dal
  /// sistema dal trascinamento sulla finestra.
  void addPaths(
    Iterable<String> rawPaths, {
    ExternalOpenSource source = ExternalOpenSource.system,
  }) {
    if (!isSupported) return;

    final targets = <String>[];
    for (final raw in rawPaths) {
      final path = normalizeOpenTarget(raw);
      if (path != null) targets.add(path);
    }
    if (targets.isEmpty) return;

    _deliver(ExternalOpenRequest(paths: targets, source: source));
  }

  void _deliver(ExternalOpenRequest request) {
    if (_listeners.isEmpty) {
      _pending.add(request);
      return;
    }
    for (final listener in _listeners.toList(growable: false)) {
      listener(request);
    }
  }

  void _flushPending() {
    if (_pending.isEmpty) return;
    final pending = List<ExternalOpenRequest>.of(_pending);
    _pending.clear();
    for (final listener in _listeners.toList(growable: false)) {
      for (final request in pending) {
        listener(request);
      }
    }
  }

  /// Su macOS `application:openURLs:` può scattare prima che il canale Dart
  /// sia pronto: il nativo conserva i percorsi e li restituisce qui. Se il
  /// canale non è ancora registrato si riprova per un secondo circa, senza
  /// bloccare l'avvio.
  Future<void> _requestPendingFromNative([int attempt = 0]) async {
    try {
      final pending = await _channel.invokeMethod<List<Object?>>('ready');
      if (pending != null) {
        addPaths(pending.whereType<String>());
      }
    } on MissingPluginException {
      if (attempt >= 9 || _listeners.isEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (_listeners.isNotEmpty) {
        await _requestPendingFromNative(attempt + 1);
      }
    } catch (_) {
      // Nessun canale nativo (o implementazione assente): gli eventi
      // successivi arriveranno comunque da `open` o dagli argomenti.
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'open') {
      final arguments = call.arguments;
      if (arguments is List) {
        addPaths(arguments.whereType<String>());
      }
    }
    return null;
  }
}
