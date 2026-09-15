import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;

class DividerEmbed {
  const DividerEmbed._();
  static const String kType = 'md_hr';
}

class DividerEmbedBuilder extends quill.EmbedBuilder {
  final Color color;
  DividerEmbedBuilder({required this.color});

  @override
  String get key => DividerEmbed.kType;

  // API-CHECK: vedi nota gemella in table_embed.dart su `EmbedContext`.
  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Divider(color: color, thickness: 1.5),
    );
  }
}
