import 'backends/compiler_registry.dart';
import 'backends/exe_backend.dart';
import 'backends/js_backend.dart';
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

  /// Parses a depfile produced by [compiler] (or auto-detected):
  /// - 'js' (dart2js .deps): line-delimited URIs / file paths.
  /// - 'wasm' / 'exe': Makefile/Ninja format (`<target>: <dep1> <dep2> ...`).
  /// Handles Windows drive letters, backslash-escaped newlines, spaces, and path separators.
  static List<String> parseDepfile(
    String content, {
    String? compiler,
    String? projectRoot,
    CompilerRegistry? registry,
  }) {
    final reg = registry ?? CompilerRegistry.defaultRegistry;
    final backend = compiler != null ? reg.get(compiler) : null;
    if (backend != null) {
      return backend.parseDepfile(content, projectRoot);
    }
    // Fallback auto-detection if compiler is null or not found
    final isJs = content.trimLeft().split('\n').first.trim().startsWith('file://');
    if (isJs) {
      return const JsCompilerBackend().parseDepfile(content, projectRoot);
    } else {
      return const ExeCompilerBackend().parseDepfile(content, projectRoot);
    }
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
