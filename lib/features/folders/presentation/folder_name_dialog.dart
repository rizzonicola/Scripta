import 'package:flutter/material.dart';

/// Dialog con un solo campo di testo per il nome di una cartella (creazione
/// e rinomina).
///
/// Lo [TextEditingController] appartiene allo [State] e viene rilasciato in
/// `dispose()`, cioè solo DOPO la fine dell'animazione di chiusura: il campo
/// resta agganciato a un controller valido per tutta la transizione. In
/// precedenza i controller venivano creati dalla funzione che apriva il
/// dialog e non venivano mai rilasciati.
class FolderNameDialog extends StatefulWidget {
  const FolderNameDialog({
    super.key,
    required this.title,
    required this.hintText,
    required this.cancelLabel,
    required this.confirmLabel,
    this.initialName = '',
  });

  final String title;
  final String hintText;
  final String cancelLabel;
  final String confirmLabel;
  final String initialName;

  /// Mostra il dialog. Restituisce il nome inserito (senza spazi ai bordi,
  /// mai vuoto) oppure `null` se l'utente annulla.
  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String hintText,
    required String cancelLabel,
    required String confirmLabel,
    String initialName = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => FolderNameDialog(
        title: title,
        hintText: hintText,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
        initialName: initialName,
      ),
    );
  }

  @override
  State<FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<FolderNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: widget.hintText,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
