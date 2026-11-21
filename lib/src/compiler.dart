import 'dart:async';
import 'dart:convert';
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

    // Process defines: add 'squadron.' prefix unless key starts with '$' (verbatim)
    final defineArgs = <String>[];
    if (defines != null) {
      for (final entry in defines.entries) {
        if (entry.key.startsWith(r'$')) {
          defineArgs.add('-D${entry.key.substring(1)}=${entry.value}');
        } else {
          defineArgs.add('-Dsquadron.${entry.key}=${entry.value}');
        }
      }
    }

    final optimLvl = optimizationLevel.trim().isEmpty
        ? OptimizationLevel.safe
        : optimizationLevel;

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
          dependencies.addAll(parseDepfile(
            content,
            compiler: compiler,
            projectRoot: projectRoot,
          ));
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

  /// Parses a depfile produced by [compiler] (or auto-detected):
  /// - 'js' (dart2js .deps): line-delimited URIs / file paths.
  /// - 'wasm' / 'exe': Makefile/Ninja format (`<target>: <dep1> <dep2> ...`).
  /// Handles Windows drive letters, backslash-escaped newlines, spaces, and path separators.
  static List<String> parseDepfile(
    String content, {
    String? compiler,
    String? projectRoot,
  }) {
    final deps = <String>[];
    if (content.trim().isEmpty) return deps;

    final isJs = compiler == 'js' ||
        (compiler == null &&
            content.trimLeft().split('\n').first.trim().startsWith('file://'));

    if (isJs) {
      for (final rawLine in const LineSplitter().convert(content)) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        deps.add(_normalizeDepPath(line, projectRoot));
      }
      return deps;
    }

    final normalized = content.replaceAll(RegExp(r'\\(?:\r?\n|\r)'), ' ');
    final match = RegExp(r'(?<!\\):\s+').firstMatch(normalized);
    final rhs = match != null
        ? normalized.substring(match.end).trim()
        : normalized.trim();
    if (rhs.isEmpty) return deps;

    final sb = StringBuffer();
    for (int i = 0; i < rhs.length; i++) {
      final c = rhs[i];
      if (c == '\\' && i + 1 < rhs.length) {
        final next = rhs[i + 1];
        if (next == ' ' || next == '\t') {
          sb.write(next);
          i++;
        } else if (next == '\\') {
          sb.write('\\');
          i++;
        } else if (next == ':') {
          sb.write(':');
          i++;
        } else {
          sb.write('\\');
        }
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
    if ((clean.startsWith('"') && clean.endsWith('"')) ||
        (clean.startsWith("'") && clean.endsWith("'"))) {
      clean = clean.substring(1, clean.length - 1).trim();
    }
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
