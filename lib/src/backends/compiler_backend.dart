import 'dart:async';

import '../compiler.dart';
import '../utils.dart';

abstract class CompilerBackend {
  String get name;

  bool get supportsDepfileArg;

  String defaultDepfile(String resolvedOutput);

  List<String> parseDepfile(String content, String? projectRoot);

  Future<CompilationResult> compile({
    required String projectRoot,
    required String source,
    required String output,
    String optimizationLevel = '',
    Map<String, String>? defines,
    String? depfile,
    required BuildLogger logger,
  });
}
