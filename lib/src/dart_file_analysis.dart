import 'dart:io';

import 'package:path/path.dart' as path;

class DartFileAnalyzer {
  final _cache = <String, Future<DartFileAnalysis>>{};

  Future<DartFileAnalysis> analyze(File file) {
    final key = path.canonicalize(file.absolute.path);
    return _cache.putIfAbsent(key, () => DartFileAnalysis.analyze(file));
  }
}

class DartFileAnalysis {
  DartFileAnalysis({
    required this.hasMain,
    required this.imports,
    required this.exports,
    required this.parts,
    required this.strippedCode,
  });

  final bool hasMain;
  final List<String> imports;
  final List<String> exports;
  final List<String> parts;
  final String strippedCode;

  static Future<DartFileAnalysis> analyze(File file) async {
    try {
      final code = await file.readAsString();
      return _parseDartCode(code);
    } catch (_) {
      return DartFileAnalysis(
        hasMain: false,
        imports: [],
        exports: [],
        parts: [],
        strippedCode: '',
      );
    }
  }

  /// Specialized helper: skips comments (// ... and /* ... */)
  /// Replaces comment characters with spaces (preserving newlines) in [sb].
  /// Returns the updated position.
  static int _skipComment(String code, int i, [StringBuffer? sb]) {
    final len = code.length;
    if (code.startsWith('//', i)) {
      i += 2;
      sb?.write('  ');
      while (i < len && code[i] != '\n' && code[i] != '\r') {
        sb?.write(' ');
        i++;
      }
      return i;
    } else if (code.startsWith('/*', i)) {
      i += 2;
      sb?.write('  ');
      while (i < len) {
        if (code.startsWith('*/', i)) {
          i += 2;
          sb?.write('  ');
          break;
        } else {
          final c = code[i];
          sb?.write(c == '\n' || c == '\r' ? c : ' ');
          i++;
        }
      }
      return i;
    }
    return i;
  }

  /// Specialized helper: skips string contents, handling raw strings,
  /// triple quotes, escape sequences, and string interpolation (${...}, $var).
  ///
  /// If [extractedValueSb] is provided and the string is not an interpolated
  /// string expression, writes the literal content of the string to [extractedValueSb].
  ///
  /// Replaces contents with spaces in [sb] to preserve code offsets.
  /// Returns the updated position.
  static int _skipString(
    String code,
    int i, [
    StringBuffer? sb,
    StringBuffer? extractedValueSb,
  ]) {
    final len = code.length;
    if (i >= len) return i;

    bool isRaw = false;
    if (code[i] == 'r' || code[i] == 'R') {
      if (i + 1 < len && (code[i + 1] == "'" || code[i + 1] == '"')) {
        isRaw = true;
        sb?.write(' ');
        i++;
      } else {
        return i;
      }
    }

    String quote;
    if (code.startsWith("'''", i) || code.startsWith('"""', i)) {
      quote = code.substring(i, i + 3);
    } else if (code[i] == "'" || code[i] == '"') {
      quote = code[i];
    } else {
      return i;
    }

    final quoteLen = quote.length;
    i += quoteLen;
    for (int q = 0; q < quoteLen; q++) {
      sb?.write(' ');
    }

    bool escaped = false;
    while (i < len) {
      if (!isRaw && escaped) {
        escaped = false;
        extractedValueSb?.write(code[i]);
        final c = code[i];
        sb?.write(c == '\n' || c == '\r' ? c : ' ');
        i++;
      } else if (!isRaw && code[i] == '\\') {
        escaped = true;
        sb?.write(' ');
        i++;
      } else if (code.startsWith(quote, i)) {
        i += quoteLen;
        for (int q = 0; q < quoteLen; q++) {
          sb?.write(' ');
        }
        break;
      } else if (!isRaw && code.startsWith(r'${', i)) {
        // String interpolation with expression ${...}
        sb?.write('  ');
        i += 2;
        i = _skipBlock(code, i - 1, sb); // i - 1 points to '{'
      } else if (!isRaw &&
          code[i] == r'$' &&
          i + 1 < len &&
          _isIdChar(code[i + 1])) {
        // Simple identifier interpolation $foo
        sb?.write('  ');
        i += 2;
        while (i < len && _isIdChar(code[i])) {
          sb?.write(' ');
          i++;
        }
      } else {
        final c = code[i];
        extractedValueSb?.write(c);
        sb?.write(c == '\n' || c == '\r' ? c : ' ');
        i++;
      }
    }
    return i;
  }

  /// Specialized helper: skips block contents for (), [], {}.
  /// Replaces inner contents with spaces in [sb], but keeps the outer delimiters
  /// or replaces them consistently. Returns the updated position.
  static int _skipBlock(String code, int i, [StringBuffer? sb]) {
    final len = code.length;
    if (i >= len) return i;
    final open = code[i];
    String close;
    if (open == '(') {
      close = ')';
    } else if (open == '{') {
      close = '}';
    } else if (open == '[') {
      close = ']';
    } else {
      return i;
    }

    sb?.write(open);
    i++;

    int depth = 1;
    while (i < len && depth > 0) {
      final c = code[i];
      if (c == '/' &&
          i + 1 < len &&
          (code[i + 1] == '/' || code[i + 1] == '*')) {
        i = _skipComment(code, i, sb);
      } else if (c == "'" ||
          c == '"' ||
          ((c == 'r' || c == 'R') &&
              i + 1 < len &&
              (code[i + 1] == "'" || code[i + 1] == '"'))) {
        i = _skipString(code, i, sb);
      } else if (c == open) {
        depth++;
        sb?.write(' ');
        i++;
      } else if (c == close) {
        depth--;
        if (depth == 0) {
          sb?.write(close);
          i++;
          break;
        } else {
          sb?.write(' ');
          i++;
        }
      } else {
        sb?.write(c == '\n' || c == '\r' ? c : ' ');
        i++;
      }
    }
    return i;
  }

  /// Specialized helper: skips an arrow function / expression body `=> ... ;`.
  /// Properly balances any nested parentheses, brackets, blocks, strings, and comments,
  /// replacing them with spaces in [sb] until the terminating semicolon `;`.
  /// Returns the updated position (past the semicolon).
  static int _skipArrowBody(String code, int i, [StringBuffer? sb]) {
    final len = code.length;
    // Skip '=>'
    if (code.startsWith('=>', i)) {
      sb?.write('=>');
      i += 2;
    }

    while (i < len) {
      final c = code[i];
      if (c == '/' &&
          i + 1 < len &&
          (code[i + 1] == '/' || code[i + 1] == '*')) {
        i = _skipComment(code, i, sb);
      } else if (c == "'" ||
          c == '"' ||
          ((c == 'r' || c == 'R') &&
              i + 1 < len &&
              (code[i + 1] == "'" || code[i + 1] == '"'))) {
        i = _skipString(code, i, sb);
      } else if (c == '(' || c == '{' || c == '[') {
        i = _skipBlock(code, i, sb);
      } else if (c == ';') {
        sb?.write(';');
        i++;
        break;
      } else {
        sb?.write(c == '\n' || c == '\r' ? c : ' ');
        i++;
      }
    }
    return i;
  }

  /// Specialized helper: captures all file URIs in an import/export/part directive.
  /// Appends each discovered URI followed by `\0` into [filesSb].
  /// Replaces directive characters in [codeSb] with spaces and terminates with `;`.
  /// Returns the updated position (past the terminating `;`).
  static int _captureDirective(
    String code,
    int i,
    StringBuffer filesSb, {
    StringBuffer? codeSb,
    bool isPartDirective = false,
  }) {
    final len = code.length;

    // Check if this is `part of ...;`
    if (isPartDirective) {
      int checkIdx = i;
      while (checkIdx < len && _isWhitespace(code[checkIdx])) {
        checkIdx++;
      }
      if (code.startsWith('of', checkIdx) &&
          (checkIdx + 2 >= len || !_isIdChar(code[checkIdx + 2]))) {
        // This is `part of ...;`. Skip to terminating ';' without recording parts.
        while (checkIdx < len) {
          final c = code[checkIdx];
          if (c == '/' &&
              checkIdx + 1 < len &&
              (code[checkIdx + 1] == '/' || code[checkIdx + 1] == '*')) {
            checkIdx = _skipComment(code, checkIdx, codeSb);
          } else if (c == "'" ||
              c == '"' ||
              ((c == 'r' || c == 'R') &&
                  checkIdx + 1 < len &&
                  (code[checkIdx + 1] == "'" || code[checkIdx + 1] == '"'))) {
            checkIdx = _skipString(code, checkIdx, codeSb);
          } else if (c == ';') {
            codeSb?.write(';');
            checkIdx++;
            break;
          } else {
            codeSb?.write(c == '\n' || c == '\r' ? c : ' ');
            checkIdx++;
          }
        }
        return checkIdx;
      }
    }

    while (i < len) {
      final c = code[i];
      if (c == '/' &&
          i + 1 < len &&
          (code[i + 1] == '/' || code[i + 1] == '*')) {
        i = _skipComment(code, i, codeSb);
        continue;
      }

      if (c == "'" ||
          c == '"' ||
          ((c == 'r' || c == 'R') &&
              i + 1 < len &&
              (code[i + 1] == "'" || code[i + 1] == '"'))) {
        final uriSb = StringBuffer();
        i = _skipString(code, i, codeSb, uriSb);
        final uri = uriSb.toString();
        if (uri.isNotEmpty) {
          filesSb.write(uri);
          filesSb.writeCharCode(0);
        }
        continue;
      }

      if (c == ';') {
        codeSb?.write(';');
        i++;
        break;
      }

      codeSb?.write(c == '\n' || c == '\r' ? c : ' ');
      i++;
    }

    return i;
  }

  /// Parses Dart code: extracts imports, exports, parts, and strips down code to top-level definitions only
  static DartFileAnalysis _parseDartCode(String code) {
    final importsSb = StringBuffer();
    final exportsSb = StringBuffer();
    final partsSb = StringBuffer();

    final sb = StringBuffer();
    int i = 0;
    final len = code.length;

    while (i < len) {
      final c = code[i];

      // 1. Skip comments altogether
      if (c == '/' &&
          i + 1 < len &&
          (code[i + 1] == '/' || code[i + 1] == '*')) {
        i = _skipComment(code, i, sb);
        continue;
      }

      // 2. Skip string contents
      if (c == "'" ||
          c == '"' ||
          ((c == 'r' || c == 'R') &&
              i + 1 < len &&
              (code[i + 1] == "'" || code[i + 1] == '"'))) {
        i = _skipString(code, i, sb);
        continue;
      }

      // 3. Arrow expression bodies: => ... ;
      if (code.startsWith('=>', i)) {
        i = _skipArrowBody(code, i, sb);
        continue;
      }

      // 4. Capture top-level directives
      if (code.startsWith('import', i) &&
          (i == 0 || !_isIdChar(code[i - 1])) &&
          (i + 6 >= len || !_isIdChar(code[i + 6]))) {
        for (int k = 0; k < 6; k++) {
          sb.write(' ');
        }
        i = _captureDirective(code, i + 6, importsSb, codeSb: sb);
        continue;
      } else if (code.startsWith('export', i) &&
          (i == 0 || !_isIdChar(code[i - 1])) &&
          (i + 6 >= len || !_isIdChar(code[i + 6]))) {
        for (int k = 0; k < 6; k++) {
          sb.write(' ');
        }
        i = _captureDirective(code, i + 6, exportsSb, codeSb: sb);
        continue;
      } else if (code.startsWith('part', i) &&
          (i == 0 || !_isIdChar(code[i - 1])) &&
          (i + 4 >= len || !_isIdChar(code[i + 4]))) {
        for (int k = 0; k < 4; k++) {
          sb.write(' ');
        }
        i = _captureDirective(code, i + 4, partsSb,
            codeSb: sb, isPartDirective: true);
        continue;
      }

      // 5. Skip block bodies for (), [], {}
      if (c == '(' || c == '{' || c == '[') {
        i = _skipBlock(code, i, sb);
        continue;
      }

      sb.write(c);
      i++;
    }

    final strippedCode = sb.toString();

    // Robust check for top-level main function:
    // Matches e.g.:
    //   void main() ...
    //   Future<void> main(List<String> args) async ...
    //   main() => ...
    // Must not match inside class/mixin/enum bodies (already stripped by _skipBlock),
    // and must not match variable declarations like `var main = () {};`.
    final hasMain = _mainFunctionRegex.hasMatch(strippedCode);

    List<String> unpackList(StringBuffer buffer) {
      final str = buffer.toString();
      if (str.isEmpty) return const [];
      return str
          .split(String.fromCharCode(0))
          .where((s) => s.isNotEmpty)
          .toList();
    }

    return DartFileAnalysis(
      hasMain: hasMain,
      imports: unpackList(importsSb),
      exports: unpackList(exportsSb),
      parts: unpackList(partsSb),
      strippedCode: strippedCode,
    );
  }

  static final RegExp _mainFunctionRegex = RegExp(
    r'(?:^|[\s;}])'
    r'(?:(?:void|Future(?:<[^>]+>)?|dynamic|[A-Za-z0-9_<>]+)\s+)?'
    r'main\s*'
    r'\([^)]*\)'
    r'(?:\s+async)?'
    r'\s*(?:\{|=>)',
    multiLine: true,
  );

  static bool _isWhitespace(String c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
  }

  static bool _isIdChar(String c) {
    final codeUnit = c.codeUnitAt(0);
    return (codeUnit >= 65 && codeUnit <= 90) || // A-Z
        (codeUnit >= 97 && codeUnit <= 122) || // a-z
        (codeUnit >= 48 && codeUnit <= 57) || // 0-9
        codeUnit == 95; // _
  }
}
