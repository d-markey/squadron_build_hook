import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../compiler.dart';
import '../utils.dart';
import 'compiler_backend.dart';

abstract class DartCompilerBackend implements CompilerBackend {
  const DartCompilerBackend();

  @override
  bool get supportsDepfileArg => true;

  @override
  String defaultDepfile(String resolvedOutput) => '$resolvedOutput.d';

  @override
  List<String> parseDepfile(String content, String? projectRoot) {
    final deps = <String>[];
    if (content.trim().isEmpty) return deps;

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
          deps.add(normalizeDepPath(sb.toString(), projectRoot));
          sb.clear();
        }
      } else {
        sb.write(c);
      }
    }
    if (sb.isNotEmpty) {
      deps.add(normalizeDepPath(sb.toString(), projectRoot));
    }

    return deps;
  }

  @override
  Future<CompilationResult> compile({
    required String projectRoot,
    required String source,
    required String output,
    String optimizationLevel = '',
    Map<String, String>? defines,
    String? depfile,
    required BuildLogger logger,
  }) async {
    final resolvedSource =
        path.isAbsolute(source) ? source : path.join(projectRoot, source);
    final resolvedOutput =
        path.isAbsolute(output) ? output : path.join(projectRoot, output);

    // Ensure output directory exists
    final outDir = Directory(path.dirname(resolvedOutput));
    await outDir.create(recursive: true);

    final resolvedDepfile = depfile != null
        ? (path.isAbsolute(depfile) ? depfile : path.join(projectRoot, depfile))
        : defaultDepfile(resolvedOutput);

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
      name,
      if (name != 'exe') '-O$optimLvl',
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
          dependencies.addAll(parseDepfile(content, projectRoot));
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

  static String normalizeDepPath(String p, String? projectRoot) {
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
}
