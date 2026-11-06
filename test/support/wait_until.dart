import 'package:flutter_test/flutter_test.dart';

/// Attende (con polling e timeout) che [condition] diventi vera.
///
/// Fallisce esplicitamente allo scadere del timeout: una condizione mai
/// soddisfatta non deve lasciar proseguire il test, altrimenti il test non
/// distingue un timeout da un successo.
Future<void> waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(interval);
  }
  fail('condizione non raggiunta entro $timeout');
}
