import 'dart:convert';

import 'dart_compiler_backend.dart';

class JsCompilerBackend extends DartCompilerBackend {
  const JsCompilerBackend();

  @override
  String get name => 'js';

  @override
  bool get supportsDepfileArg => false;

  @override
  String defaultDepfile(String resolvedOutput) => '$resolvedOutput.deps';

  @override
  List<String> parseDepfile(String content, String? projectRoot) {
    final deps = <String>[];
    if (content.trim().isEmpty) return deps;

    for (final rawLine in const LineSplitter().convert(content)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      deps.add(DartCompilerBackend.normalizeDepPath(line, projectRoot));
    }
    return deps;
  }
}
