import 'dart:developer' show Timeline, TimelineTask;

/// Marker di prestazione per DevTools → Performance (vista Timeline).
///
/// PERCHÉ esiste: senza marker, "tempo a lista utilizzabile" e le fasi di
/// rete dell'avvio non si possono misurare senza modificare il codice a mano.
/// Con questi, `flutter run --profile` + DevTools mostrano quando partono e
/// quanto durano apertura del database, caricamento delle note, health check,
/// impostazioni e prima sync.
///
/// Non cambia il comportamento dell'app: restituisce lo stesso valore (o
/// rilancia lo stesso errore) di ciò che avvolge, non scrive su console e non
/// usa dipendenze. Fuori da una sessione di profiling gli eventi non vengono
/// registrati; il costo residuo è una chiamata per evento (IPOTESI: il
/// controllo di un flag nel runtime. Da confermare confrontando il tempo al
/// primo frame, protocollo M2 del REPORT_APP, con e senza marker).
class PerfMarks {
  const PerfMarks._();

  /// Prefisso comune: in DevTools basta filtrare per "scripta." per vedere
  /// solo questi eventi.
  static const String _prefix = 'scripta.';

  /// Evento istantaneo: "qui è successo X" (es. subito prima di `runApp`).
  static void mark(String name) => Timeline.instantSync('$_prefix$name');

  /// Esegue [body] dentro un intervallo con durata. Adatto alle fasi
  /// ASINCRONE (apertura DB, richieste di rete), dove `Timeline.timeSync`
  /// non basterebbe perché misurerebbe solo la parte sincrona. L'intervallo
  /// si chiude anche se [body] lancia, e l'errore arriva al chiamante
  /// invariato.
  static Future<T> timeAsync<T>(String name, Future<T> Function() body) async {
    final task = TimelineTask()..start('$_prefix$name');
    try {
      return await body();
    } finally {
      task.finish();
    }
  }
}
