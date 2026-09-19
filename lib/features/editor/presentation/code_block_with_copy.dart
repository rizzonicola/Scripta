import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/l10n/app_localizations.dart';

/// Avvolge un blocco di codice di `flutter_md` con una barra superiore che
/// contiene, a destra, il pulsante "Copia".
///
/// PERCHÉ una barra sopra il codice e non un pulsante sovrapposto:
/// `flutter_md` disegna il blocco su canvas e non espone il padding interno,
/// quindi un pulsante in `Stack` cadrebbe sopra la prima riga di codice
/// (specie se lunga). La barra occupa invece il suo spazio: per costruzione
/// non copre mai il codice.
///
/// PERCHÉ il pulsante non finisce mai nella selezione/copia del codice:
///  * la selezione di `flutter_md` è ancorata al modello dati
///    (`Markdown`/`MD$Code`), non ai widget a schermo: tutto ciò che non è
///    nel modello — quindi anche questa barra — non può essere selezionato;
///  * il pulsante "Copia" legge direttamente `MD$Code.text`, cioè solo il
///    sorgente, senza etichette né decorazioni;
///  * per sicurezza la barra è in un `SelectionContainer.disabled`, così
///    resta esclusa anche se un antenato diventasse una `SelectionArea`.
///
/// Lo sfondo (`surfaceColor`, lo stesso del tema Markdown per i blocchi di
/// codice) è dipinto da questo widget dietro l'intera colonna: barra e
/// blocco risultano una sola card, senza tacche agli angoli arrotondati.
class CodeBlockWithCopy extends StatefulWidget {
  const CodeBlockWithCopy({
    super.key,
    required this.code,
    required this.language,
    required this.surfaceColor,
    required this.child,
  });

  /// Solo il sorgente del blocco (`MD$Code.text`): è ciò che viene copiato.
  final String code;

  /// Linguaggio dichiarato nel fence (può essere assente).
  final String? language;

  /// Sfondo condiviso con il blocco disegnato da `flutter_md`.
  final Color surfaceColor;

  /// Il `MarkdownWidget` del blocco di codice.
  final Widget child;

  @override
  State<CodeBlockWithCopy> createState() => _CodeBlockWithCopyState();
}

class _CodeBlockWithCopyState extends State<CodeBlockWithCopy> {
  static const double _radius = 8;
  static const Duration _feedbackDuration = Duration(milliseconds: 1600);

  Timer? _resetTimer;
  bool _copied = false;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(_feedbackDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: muted,
      letterSpacing: 0.3,
    );
    final language = widget.language?.trim() ?? '';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: widget.surfaceColor,
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectionContainer.disabled(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        language,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                    ),
                    if (_copied) ...[
                      Text(l10n.codeCopied, style: labelStyle),
                      const SizedBox(width: 2),
                    ],
                    IconButton(
                      tooltip: MaterialLocalizations.of(context).copyButtonLabel,
                      iconSize: 16,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      visualDensity: VisualDensity.compact,
                      color: _copied ? theme.colorScheme.primary : muted,
                      onPressed: _copy,
                      icon: Icon(
                        _copied
                            ? Icons.check_rounded
                            : Icons.content_copy_rounded,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            widget.child,
          ],
        ),
      ),
    );
  }
}
