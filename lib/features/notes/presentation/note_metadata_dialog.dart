import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/l10n/desktop_strings.dart';
import '../models/note_model.dart';
import '../providers/notes_provider.dart';

/// Editor dei metadati sincronizzati di una nota. Le etichette stanno
/// in `DesktopStrings` (it/en/fr): sono testi di una funzione desktop e non
/// vale la pena forzare una rigenerazione l10n per ogni nuova voce.
Future<void> showNoteMetadataDialog(
  BuildContext context,
  WidgetRef ref,
  NoteModel note,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => _NoteMetadataDialog(note: note),
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(DesktopStrings.of(context).metadataSaved),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _NoteMetadataDialog extends ConsumerStatefulWidget {
  const _NoteMetadataDialog({required this.note});

  final NoteModel note;

  @override
  ConsumerState<_NoteMetadataDialog> createState() =>
      _NoteMetadataDialogState();
}

class _NoteMetadataDialogState extends ConsumerState<_NoteMetadataDialog> {
  late bool _favorite = widget.note.isFavorite;
  late bool _pinned = widget.note.isPinned;
  late DateTime _createdAt = widget.note.createdAt.toLocal();
  late final DateTime _updatedAt = widget.note.updatedAt.toLocal();
  late final TextEditingController _orderController = TextEditingController(
    text: widget.note.orderIndex.toString(),
  );
  String? _orderError;

  @override
  void dispose() {
    _orderController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final firstDate = DateTime(2000);
    // La creazione non può essere nel futuro: updatedAt viene aggiornato al
    // salvataggio, quindi il limite superiore corretto è "adesso".
    final lastDate = DateTime.now();
    // Una data importata da un backup legacy può stare fuori dall'intervallo
    // consentito dal picker: senza clamp `showDatePicker` fallirebbe.
    final initialDate = _createdAt.isBefore(firstDate)
        ? firstDate
        : (_createdAt.isAfter(lastDate) ? lastDate : _createdAt);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null) return;
    setState(() {
      // Si cambia solo il giorno: l'ora locale originale resta, così la lista
      // non salta per una differenza di orario non voluta.
      _createdAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _createdAt.hour,
        _createdAt.minute,
        _createdAt.second,
        _createdAt.millisecond,
        _createdAt.microsecond,
      );
    });
  }

  void _save() {
    final order = int.tryParse(_orderController.text.trim());
    if (order == null) {
      setState(() {
        _orderError = DesktopStrings.of(context).metadataInvalidOrder;
      });
      return;
    }
    ref
        .read(notesProvider.notifier)
        .updateMetadata(
          widget.note.id,
          isFavorite: _favorite,
          isPinned: _pinned,
          createdAt: _createdAt,
          orderIndex: order,
        );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ds = DesktopStrings.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(ds.metadataTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(ds.metadataFavorite),
                secondary: Icon(
                  _favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: _favorite ? Colors.amber.shade700 : null,
                ),
                value: _favorite,
                onChanged: (value) => setState(() => _favorite = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(ds.metadataPinned),
                secondary: Icon(
                  _pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                ),
                value: _pinned,
                onChanged: (value) => setState(() => _pinned = value),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: Text(ds.metadataCreatedAt),
                subtitle: Text(
                  DateFormat.yMMMd(
                    Localizations.localeOf(context).toString(),
                  ).add_Hm().format(_createdAt),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.edit_calendar_outlined),
                  onPressed: _pickDate,
                ),
                onTap: _pickDate,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.update_rounded),
                title: Text(ds.metadataUpdatedAt),
                subtitle: Text(
                  DateFormat.yMMMd(
                    Localizations.localeOf(context).toString(),
                  ).add_Hm().format(_updatedAt),
                ),
              ),
              TextField(
                controller: _orderController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: ds.metadataOrder,
                  helperText: ds.metadataOrderHint,
                  errorText: _orderError,
                  prefixIcon: const Icon(Icons.format_list_numbered_rounded),
                ),
                onChanged: (_) {
                  if (_orderError != null) setState(() => _orderError = null);
                },
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.note.wordCount} words • '
                '${widget.note.readingTimeMinutes} min',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}
