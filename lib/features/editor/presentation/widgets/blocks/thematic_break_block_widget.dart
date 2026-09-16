import 'package:flutter/material.dart';

import 'markdown_block_style.dart';

/// Rendering di un `ThematicBreakNode` (linea di separazione orizzontale).
class ThematicBreakBlockWidget extends StatelessWidget {
  final MarkdownBlockStyle style;

  const ThematicBreakBlockWidget({super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Divider(
        color: style.outlineColor.withValues(alpha: 0.4),
        thickness: 1.5,
      ),
    );
  }
}
