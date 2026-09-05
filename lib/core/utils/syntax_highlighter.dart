import 'package:flutter/material.dart';

enum TokenType {
  plain,
  keyword,
  type,
  string,
  number,
  comment,
  punctuation,
  property,
  function,
}

class ScriptaCodeHighlighter {
  static const Set<String> _commonKeywords = {
    'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'default', 'defer', 'do', 'else', 'enum',
    'export', 'extends', 'extension', 'external', 'factory', 'false', 'final',
    'finally', 'fn', 'for', 'function', 'get', 'goto', 'if', 'implements',
    'import', 'in', 'interface', 'is', 'late', 'let', 'match', 'mixin',
    'new', 'null', 'operator', 'override', 'part', 'pub', 'required',
    'rethrow', 'return', 'set', 'static', 'super', 'switch', 'sync', 'this',
    'throw', 'true', 'try', 'type', 'typedef', 'var', 'void', 'while',
    'with', 'yield', 'def', 'elif', 'from', 'lambda', 'not', 'pass',
    'raise', 'struct', 'val', 'package', 'public', 'private', 'protected'
  };

  static const Set<String> _commonTypes = {
    'String', 'int', 'double', 'num', 'bool', 'List', 'Map', 'Set',
    'Widget', 'BuildContext', 'State', 'Future', 'Stream', 'void',
    'Object', 'dynamic', 'Iterable', 'DateTime', 'Duration', 'Uri',
    'File', 'Directory', 'Color', 'TextStyle', 'Container', 'Text',
    'Column', 'Row', 'Scaffold', 'AppBar', 'Icon', 'IconButton',
    'Boolean', 'Integer', 'Float', 'Double', 'Array', 'Promise', 'Record'
  };

  static TextSpan highlight({
    required String code,
    required String language,
    required bool isDark,
    required TextStyle baseStyle,
  }) {
    final lang = language.trim().toLowerCase();

    // Color definitions based on dark / light mode
    final Color keywordColor = isDark ? const Color(0xFFFF7B72) : const Color(0xFFD73A49);   // Coral / Red
    final Color typeColor = isDark ? const Color(0xFF79C0FF) : const Color(0xFF005CC5);      // Cyan / Blue
    final Color stringGreen = isDark ? const Color(0xFF7EE787) : const Color(0xFF22863A);    // Green (for strings in JSON/Dart)
    final Color numberColor = isDark ? const Color(0xFFF2CC60) : const Color(0xFFB08800);    // Warm Gold / Amber
    final Color commentColor = isDark ? const Color(0xFF8B949E) : const Color(0xFF6A737D);   // Muted Slate
    final Color propertyColor = isDark ? const Color(0xFFD2A8FF) : const Color(0xFF6F42C1);  // Purple
    final Color functionColor = isDark ? const Color(0xFFD2A8FF) : const Color(0xFF6F42C1);  // Lavender / Violet
    final Color punctuationColor = isDark ? const Color(0xFFC9D1D9) : const Color(0xFF24292E);

    if (lang == 'json') {
      return _highlightJson(code, baseStyle, propertyColor, stringGreen, numberColor, keywordColor, punctuationColor);
    }

    // Generic Lexer / Tokenizer for C-like, Dart, Python, JS, TS, Shell, etc.
    final List<TextSpan> spans = [];
    final int length = code.length;
    int i = 0;

    while (i < length) {
      final char = code[i];

      // 1. Single-line comment
      if ((char == '/' && i + 1 < length && code[i + 1] == '/') ||
          (char == '#' && (lang == 'python' || lang == 'bash' || lang == 'sh' || lang == 'yaml' || lang == 'yml'))) {
        final start = i;
        while (i < length && code[i] != '\n') {
          i++;
        }
        spans.add(TextSpan(
          text: code.substring(start, i),
          style: baseStyle.copyWith(color: commentColor, fontStyle: FontStyle.italic),
        ));
        continue;
      }

      // 2. Multi-line comment
      if (char == '/' && i + 1 < length && code[i + 1] == '*') {
        final start = i;
        i += 2;
        while (i < length) {
          if (code[i] == '*' && i + 1 < length && code[i + 1] == '/') {
            i += 2;
            break;
          }
          i++;
        }
        spans.add(TextSpan(
          text: code.substring(start, i),
          style: baseStyle.copyWith(color: commentColor, fontStyle: FontStyle.italic),
        ));
        continue;
      }

      // 3. String literals ("...", '...', `...`)
      if (char == '"' || char == "'" || char == '`') {
        final quote = char;
        final start = i;
        i++;
        while (i < length) {
          if (code[i] == '\\') {
            i += 2;
            continue;
          }
          if (code[i] == quote) {
            i++;
            break;
          }
          if (code[i] == '\n' && quote != '`') {
            break; // Unterminated single-line string
          }
          i++;
        }
        spans.add(TextSpan(
          text: code.substring(start, i),
          style: baseStyle.copyWith(color: stringGreen),
        ));
        continue;
      }

      // 4. Numbers
      if (_isDigit(char) || (char == '-' && i + 1 < length && _isDigit(code[i + 1]))) {
        final start = i;
        i++;
        while (i < length && (_isDigit(code[i]) || code[i] == '.' || code[i] == 'x' || code[i] == 'X' || _isHex(code[i]))) {
          i++;
        }
        spans.add(TextSpan(
          text: code.substring(start, i),
          style: baseStyle.copyWith(color: numberColor),
        ));
        continue;
      }

      // 5. Identifiers / Keywords / Functions
      if (_isAlpha(char) || char == '_' || char == r'$') {
        final start = i;
        while (i < length && (_isAlpha(code[i]) || _isDigit(code[i]) || code[i] == '_' || code[i] == r'$')) {
          i++;
        }
        final token = code.substring(start, i);

        // Check if followed by '(' -> function invocation or definition
        int peek = i;
        while (peek < length && code[peek] == ' ') {
          peek++;
        }
        final isFunction = peek < length && code[peek] == '(';

        if (_commonKeywords.contains(token)) {
          spans.add(TextSpan(
            text: token,
            style: baseStyle.copyWith(color: keywordColor, fontWeight: FontWeight.w600),
          ));
        } else if (_commonTypes.contains(token) || (token.length > 1 && token[0] == token[0].toUpperCase() && token[1] == token[1].toLowerCase())) {
          spans.add(TextSpan(
            text: token,
            style: baseStyle.copyWith(color: typeColor, fontWeight: FontWeight.w600),
          ));
        } else if (isFunction) {
          spans.add(TextSpan(
            text: token,
            style: baseStyle.copyWith(color: functionColor),
          ));
        } else {
          spans.add(TextSpan(
            text: token,
            style: baseStyle.copyWith(color: punctuationColor),
          ));
        }
        continue;
      }

      // 6. Punctuations & Whitespace
      spans.add(TextSpan(
        text: char,
        style: baseStyle.copyWith(color: punctuationColor),
      ));
      i++;
    }

    return TextSpan(children: spans);
  }

  static TextSpan _highlightJson(
    String code,
    TextStyle baseStyle,
    Color keyColor,
    Color stringColor,
    Color numberColor,
    Color boolColor,
    Color punctColor,
  ) {
    final List<TextSpan> spans = [];
    final int length = code.length;
    int i = 0;

    while (i < length) {
      final char = code[i];

      // Strings
      if (char == '"') {
        final start = i;
        i++;
        while (i < length) {
          if (code[i] == '\\') {
            i += 2;
            continue;
          }
          if (code[i] == '"') {
            i++;
            break;
          }
          i++;
        }
        final str = code.substring(start, i);

        // Check if this string is a JSON key (followed by ':')
        int peek = i;
        while (peek < length && (code[peek] == ' ' || code[peek] == '\t' || code[peek] == '\r' || code[peek] == '\n')) {
          peek++;
        }
        final isKey = peek < length && code[peek] == ':';

        spans.add(TextSpan(
          text: str,
          style: baseStyle.copyWith(
            color: isKey ? keyColor : stringColor,
            fontWeight: isKey ? FontWeight.w600 : FontWeight.normal,
          ),
        ));
        continue;
      }

      // Numbers
      if (_isDigit(char) || char == '-') {
        final start = i;
        i++;
        while (i < length && (_isDigit(code[i]) || code[i] == '.' || code[i] == 'e' || code[i] == 'E')) {
          i++;
        }
        spans.add(TextSpan(
          text: code.substring(start, i),
          style: baseStyle.copyWith(color: numberColor),
        ));
        continue;
      }

      // true, false, null
      if (_isAlpha(char)) {
        final start = i;
        while (i < length && _isAlpha(code[i])) {
          i++;
        }
        final word = code.substring(start, i);
        if (word == 'true' || word == 'false' || word == 'null') {
          spans.add(TextSpan(
            text: word,
            style: baseStyle.copyWith(color: boolColor, fontWeight: FontWeight.w600),
          ));
        } else {
          spans.add(TextSpan(
            text: word,
            style: baseStyle.copyWith(color: punctColor),
          ));
        }
        continue;
      }

      // Punctuations
      spans.add(TextSpan(
        text: char,
        style: baseStyle.copyWith(color: punctColor),
      ));
      i++;
    }

    return TextSpan(children: spans);
  }

  static bool _isDigit(String char) {
    if (char.isEmpty) return false;
    final code = char.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }

  static bool _isHex(String char) {
    if (char.isEmpty) return false;
    final code = char.codeUnitAt(0);
    return (code >= 48 && code <= 57) ||
           (code >= 65 && code <= 70) ||
           (code >= 97 && code <= 102);
  }

  static bool _isAlpha(String char) {
    if (char.isEmpty) return false;
    final code = char.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }
}
