import 'backends/compiler_registry.dart';
import 'utils.dart';

class WorkerCompiler {
  WorkerCompiler({
    required this.projectRoot,
    CompilerRegistry? registry,
  }) : registry = registry ?? CompilerRegistry.defaultRegistry;

  final String projectRoot;
  final CompilerRegistry registry;

  Future<CompilationResult> compile({
    required String compiler,
    required String source,
    required String output,
    String optimizationLevel = '',
    Map<String, String>? defines,
    String? depfile,
    required BuildLogger logger,
  }) async {
    final backend = registry[compiler];
    return await backend.compile(
      projectRoot: projectRoot,
      source: source,
      output: output,
      optimizationLevel: optimizationLevel,
      defines: defines,
      depfile: depfile,
      logger: logger,
    );
  }
}

class CompilationResult {
  CompilationResult({
    required this.exitCode,
    required this.dependencies,
    required this.outputLines,
    this.depfilePath,
  });

  final int exitCode;
  final List<String> dependencies;
  final List<String> outputLines;
  final String? depfilePath;

  bool get success => exitCode == 0;
}

sealed class OptimizationLevel {
  static const none = '0';
  static const def = '1';
  static const safe = '2';
  static const unsafe = '3';
  static const aggressive = '4';

  static String parse(Object? level) {
    if (level == null) return none;
    final s = level.toString().trim();
    if (s.isEmpty) return none;
    if (int.tryParse(s) != null) return s;
    switch (s.toLowerCase()) {
      case 'none':
        return none;
      case 'def':
      case 'default':
        return def;
      case 'safe':
        return safe;
      case 'unsafe':
        return unsafe;
      case 'aggressive':
        return aggressive;
      default:
        return level.toString();
    }
  }
}
