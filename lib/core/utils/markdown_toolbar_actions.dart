import 'package:flutter/material.dart';

class MarkdownToolbarActions {
  /// Wraps current selection or inserts with tags (e.g. **bold**)
  static void wrapSelection(
    TextEditingController controller,
    String prefix,
    String suffix, {
    String defaultText = 'text',
  }) {
    final text = controller.text;
    final selection = controller.selection;

    if (!selection.isValid) {
      final newText = '$text$prefix$defaultText$suffix';
      controller.text = newText;
      controller.selection = TextSelection(
        baseOffset: text.length + prefix.length,
        extentOffset: text.length + prefix.length + defaultText.length,
      );
      return;
    }

    final start = selection.start;
    final end = selection.end;

    if (start == end) {
      // No text selected: insert prefix + defaultText + suffix
      final before = text.substring(0, start);
      final after = text.substring(end);
      controller.text = '$before$prefix$defaultText$suffix$after';
      controller.selection = TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + defaultText.length,
      );
    } else {
      // Wrap existing selection
      final selectedText = text.substring(start, end);
      final before = text.substring(0, start);
      final after = text.substring(end);
      controller.text = '$before$prefix$selectedText$suffix$after';
      controller.selection = TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: end + prefix.length,
      );
    }
  }

  /// Prepends prefix at the start of current line (e.g. #, ##, -, 1., - [ ])
  static void prependLine(TextEditingController controller, String prefix) {
    final text = controller.text;
    final selection = controller.selection;

    final cursorPosition = selection.isValid ? selection.start : text.length;

    // Find the start of the current line
    final lineStart = text.lastIndexOf('\n', cursorPosition > 0 ? cursorPosition - 1 : 0);
    final actualStart = lineStart == -1 ? 0 : lineStart + 1;

    final before = text.substring(0, actualStart);
    final after = text.substring(actualStart);

    controller.text = '$before$prefix$after';
    final newOffset = cursorPosition + prefix.length;
    controller.selection = TextSelection.collapsed(offset: newOffset);
  }

  /// Inserts Markdown Table template
  static void insertTable(TextEditingController controller) {
    const tableTemplate =
        '\n| Column 1 | Column 2 | Column 3 |\n| :--- | :--- | :--- |\n| Item 1 | Item 2 | Item 3 |\n| Item 4 | Item 5 | Item 6 |\n';
    insertAtCursor(controller, tableTemplate);
  }

  /// Inserts Markdown Link template
  static void insertLink(TextEditingController controller) {
    wrapSelection(
      controller,
      '[',
      '](https://example.com)',
      defaultText: 'Link Title',
    );
  }

  /// Inserts Markdown Code block template
  static void insertCodeBlock(TextEditingController controller) {
    final text = controller.text;
    final selection = controller.selection;

    if (selection.isValid && selection.start != selection.end) {
      final selected = text.substring(selection.start, selection.end);
      wrapSelection(controller, '```\n', '\n```', defaultText: selected);
    } else {
      insertAtCursor(controller, '\n```dart\n// Code goes here\n```\n');
    }
  }

  /// Inserts text at cursor position
  static void insertAtCursor(TextEditingController controller, String insertText) {
    final text = controller.text;
    final selection = controller.selection;

    if (!selection.isValid) {
      controller.text = '$text$insertText';
      controller.selection =
          TextSelection.collapsed(offset: controller.text.length);
      return;
    }

    final start = selection.start;
    final end = selection.end;
    final before = text.substring(0, start);
    final after = text.substring(end);

    controller.text = '$before$insertText$after';
    controller.selection =
        TextSelection.collapsed(offset: start + insertText.length);
  }
}
