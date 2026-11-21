import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'utils.dart';

class WorkerCompiler {
  WorkerCompiler({required this.projectRoot});

  final String projectRoot;

  Future<CompilationResult> compile({
    required String compiler,
    required String source,
    required String output,
    String optimizationLevel = '',
    Map<String, String>? defines,
    String? depfile,
    required BuildLogger logger,
  }) async {
    final resolvedSource = _resolvePath(source);
    final resolvedOutput = _resolvePath(output);

    // Ensure output directory exists
    final outDir = Directory(path.dirname(resolvedOutput));
    await outDir.create(recursive: true);

    // 'exe' and 'wasm' support `--depfile=<path>`, while 'js' does not
    final supportsDepfileArg = compiler == 'exe' || compiler == 'wasm';
    final resolvedDepfile = depfile != null
        ? _resolvePath(depfile)
        : (compiler == 'js' ? '$resolvedOutput.deps' : '$resolvedOutput.d');

    final depDir = Directory(path.dirname(resolvedDepfile));
    await depDir.create(recursive: true);

    // Process defines: add 'squadron.' prefix
    final defineArgs = <String>[];
    if (defines != null) {
      for (final entry in defines.entries) {
        defineArgs.add('-Dsquadron.${entry.key}=${entry.value}');
      }
    }

    final optStr = optimizationLevel.trim();
    final cleanOpt = (optStr.startsWith('-O') || optStr.startsWith('-o'))
        ? optStr.substring(2)
        : (optStr.startsWith('O') || optStr.startsWith('o'))
            ? optStr.substring(1)
            : optStr;
    final optimLvl = cleanOpt.isEmpty ? '4' : cleanOpt;
    final args = [
      'compile',
      compiler,
      if (compiler != 'exe') '-O$optimLvl',
      if (supportsDepfileArg) '--depfile=$resolvedDepfile',
      resolvedSource,
      '-o',
      resolvedOutput,
      ...defineArgs,
    ];

    logger.log('*** dart ${args.join(' ')}');
    final process = await Process.start(
      'dart',
      args,
      workingDirectory: projectRoot,
      runInShell: true,
      includeParentEnvironment: true,
    );

    final (:exitCode, :outputLines) = await process.result;
    final dependencies = <String>[];

    if (exitCode == 0) {
      logger.log('* $resolvedSource --> $resolvedOutput: success');
      final depFileObj = File(resolvedDepfile);
      if (await depFileObj.exists()) {
        try {
          final content = await depFileObj.readAsString();
          dependencies.addAll(parseDepfile(content, projectRoot: projectRoot));
        } catch (e) {
          logger.log('Warning: Failed to parse depfile $resolvedDepfile: $e');
        }
      }
    } else {
      logger.log('* $resolvedSource --> $resolvedOutput: error $exitCode');
      outputLines.map((l) => '   $l').forEach(logger.log);
    }

    return CompilationResult(
      exitCode: exitCode,
      dependencies: dependencies,
      outputLines: outputLines,
      depfilePath: resolvedDepfile,
    );
  }

  /// Parses a Makefile/Ninja-style depfile content or a plain dependency list (.js.deps).
  /// Format: `<target>: <dep1> <dep2> ...` or `<dep1>\n<dep2> ...`
  /// Handles backslash-escaped newlines and spaces.
  static List<String> parseDepfile(String content, {String? projectRoot}) {
    final deps = <String>[];
    final normalized = content.replaceAll(RegExp(r'\\(?:\r?\n|\r)'), ' ');
    final colonIdx = normalized.indexOf(':');
    final rhs = colonIdx != -1
        ? normalized.substring(colonIdx + 1).trim()
        : normalized.trim();
    if (rhs.isEmpty) return deps;

    final sb = StringBuffer();
    bool escaped = false;

    for (int i = 0; i < rhs.length; i++) {
      final c = rhs[i];
      if (escaped) {
        sb.write(c);
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        if (sb.isNotEmpty) {
          deps.add(_normalizeDepPath(sb.toString(), projectRoot));
          sb.clear();
        }
      } else {
        sb.write(c);
      }
    }
    if (sb.isNotEmpty) {
      deps.add(_normalizeDepPath(sb.toString(), projectRoot));
    }

    return deps;
  }

  static String _normalizeDepPath(String p, String? projectRoot) {
    var clean = p.trim();
    if (clean.startsWith('file://')) {
      clean = Uri.parse(clean).toFilePath();
    }
    if (projectRoot != null && !path.isAbsolute(clean)) {
      clean = path.normalize(path.join(projectRoot, clean));
    }
    return clean;
  }

  String _resolvePath(String p) =>
      path.isAbsolute(p) ? p : path.join(projectRoot, p);
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
