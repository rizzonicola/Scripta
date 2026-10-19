import 'dart:developer' as developer;

/// Marker per DevTools → Performance (Timeline), per misurare l'avvio e le fasi
/// di rete senza cambiare il comportamento dell'app.
///
/// PERCHÉ: nel codice non c'era alcuna strumentazione, quindi "tempo a lista
/// utilizzabile" e le fasi di `SyncNotifier._init` non si potevano misurare
/// senza modificare il codice a mano. Tutti i nomi iniziano con `scripta.`, così
/// in DevTools si filtrano con quel prefisso.
///
/// Solo `dart:developer`: nessuna dipendenza e nessuna stampa. I metodi non
/// alterano i valori restituiti e le eccezioni della callback passano
/// invariate. Fuori da una sessione di profilazione il costo atteso è il
/// controllo di un flag nel runtime (da confermare confrontando il tempo al
/// primo frame, protocollo M2 del REPORT_APP).
class PerfMarks {
  const PerfMarks._();

  /// Evento istantaneo: un punto sulla timeline.
  static void instant(String name) => developer.Timeline.instantSync(name);

  /// Intervallo asincrono: dall'avvio di [body] al suo completamento, con
  /// valore o con errore. Restituisce il risultato di [body] e ne rilancia
  /// l'eventuale errore senza modificarlo (anche se [body] lancia in modo
  /// sincrono).
  static Future<T> timeAsync<T>(String name, Future<T> Function() body) async {
    final task = developer.TimelineTask();
    task.start(name);
    try {
      return await body();
    } finally {
      task.finish();
    }
  }
}
