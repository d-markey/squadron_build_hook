import 'dart:io';

import 'package:path/path.dart' as path;

import 'dart_file_analysis.dart';
import 'manifest.dart';
import 'utils.dart';

part 'heuristics_by_entry_point.dart';
part 'heuristics_by_naming_convention.dart';

class WorkerHeuristics {
  /// Default output path inference for a given compiler and source file.
  /// If [outputDir] is provided, output is placed inside [outputDir].
  static String inferOutput(String compiler, String source,
      [String? outputDir]) {
    final fileName = path.basename(source);
    final ext = switch (compiler) {
      'exe' => '.exe',
      'js' => '.js',
      'wasm' => '.wasm',
      _ => '.$compiler',
    };

    if (outputDir != null && outputDir.isNotEmpty) {
      return path.join(outputDir, '$fileName$ext').replaceAll('\\', '/');
    }

    switch (compiler) {
      case 'exe':
        return 'bin/workers/$fileName.exe';
      case 'js':
        return 'web/workers/$fileName.js';
      case 'wasm':
        return 'web/workers/$fileName.wasm';
      default:
        return 'build/workers/$fileName.$compiler';
    }
  }

  /// Merges and deduplicates targets from both heuristics for a given [worker].
  static Future<List<CompilationTargets>> resolveTargets(
    WorkerDefinition worker, {
    required String projectRoot,
    Map<String, String>? outputDirs,
    DartFileAnalyzer? analyzer,
  }) async {
    final manifestTargetsByCompiler = <String, CompilationTarget>{
      for (final t in worker.targets) t.compiler: t,
    };

    final allowedCompilers = worker.targets.isNotEmpty
        ? manifestTargetsByCompiler.keys.toSet()
        : const {'exe', 'js', 'wasm'};

    final fileAnalyzer = analyzer ?? DartFileAnalyzer();

    final h = await Future.wait([
      _locateByNamingConventions(
        worker.source,
        projectRoot: projectRoot,
        allowedCompilers: allowedCompilers,
        outputDirs: outputDirs,
        analyzer: fileAnalyzer,
      ),
      _locateByEndpointUsage(
        worker.source,
        projectRoot: projectRoot,
        allowedCompilers: allowedCompilers,
        outputDirs: outputDirs,
        analyzer: fileAnalyzer,
      )
    ]);

    final merged = <String, CompilationTargets>{};
    merged.addEntries(allowedCompilers.map((compiler) => MapEntry(compiler,
        CompilationTargets(compiler: compiler, worker: worker.source))));

    // Consolidate heuristics results in `h` to CompilationTargets
    for (final res in h) {
      if (res == null) continue;
      for (final t in res.discoveredTargets) {
        final targets = merged[t.compiler];
        if (targets == null) continue;

        final manifestTarget = manifestTargetsByCompiler[t.compiler];
        String source = t.source;
        if (manifestTarget != null && manifestTarget.source.isNotEmpty) {
          final manifestSourceFile =
              resolveFile(manifestTarget.source, projectRoot);
          if (manifestSourceFile != null) {
            source = manifestTarget.source;
          }
        }
        final output =
            (manifestTarget != null && manifestTarget.output.isNotEmpty)
                ? manifestTarget.output
                : t.output;

        final defines = {...?manifestTarget?.defines, ...worker.defines};

        final candidate = (
          method: res.method,
          source: source,
          output: output,
          defines: defines,
          optimizationLevel:
              (manifestTarget != null && manifestTarget.optimizationLevel.isNotEmpty)
                  ? manifestTarget.optimizationLevel
                  : worker.optimizationLevel,
        );

        if (!targets.candidates.any((c) =>
            c.source == candidate.source && c.output == candidate.output)) {
          targets.candidates.add(candidate);
        }
      }
    }

    // For any manifest target explicitly declared in the manifest,
    // if no heuristic candidates were found, add it from the manifest directly
    for (final entry in manifestTargetsByCompiler.entries) {
      final targets = merged[entry.key];
      if (targets != null &&
          targets.candidates.isEmpty &&
          entry.value.source.isNotEmpty) {
        final manifestSourceFile = resolveFile(entry.value.source, projectRoot);
        if (manifestSourceFile != null) {
          final output = entry.value.output.isNotEmpty
              ? entry.value.output
              : inferOutput(
                  entry.key, entry.value.source, outputDirs?[entry.key]);
          targets.candidates.add((
            method: 'manifest',
            source: entry.value.source,
            output: output,
            defines: entry.value.defines,
            optimizationLevel: entry.value.optimizationLevel.isNotEmpty
                ? entry.value.optimizationLevel
                : worker.optimizationLevel,
          ));
        }
      }
    }

    return merged.values.toList();
  }

  /// Runs diagnostics for a SINGLE [worker].
  static Future<void> runWorkerDiagnostics(
    WorkerDefinition worker, {
    String? projectRoot,
    required BuildLogger logger,
    Map<String, String>? outputDirs,
    DartFileAnalyzer? analyzer,
  }) async {
    logger.log('Running diagnostics...');
    final root = projectRoot ?? Directory.current.absolute.path;
    final fileAnalyzer = analyzer ?? DartFileAnalyzer();

    final workerSourceFile = resolveFile(worker.source, root);
    if (workerSourceFile == null) {
      logger
          .log('  [ERROR] Worker source file does not exist: ${worker.source}');
    }

    logger.log('  Manifest targets count: ${worker.targets.length}');
    for (final t in worker.targets) {
      final targetFile =
          t.source.isNotEmpty ? resolveFile(t.source, root) : null;
      final fileStatus = t.source.isEmpty
          ? ' [WARNING: no source defined]'
          : (targetFile == null ? ' [ERROR: source file not found]' : '');
      logger.log(
          '    - [${t.compiler}] src: ${t.source}$fileStatus -> out: ${t.output}');
    }

    final allowedCompilers = worker.targets.isNotEmpty
        ? worker.targets.map((t) => t.compiler).toSet()
        : const {'exe', 'js', 'wasm'};

    final h1 = await _locateByNamingConventions(
      worker.source,
      projectRoot: root,
      allowedCompilers: allowedCompilers,
      outputDirs: outputDirs,
      analyzer: fileAnalyzer,
    );
    if (h1 != null) {
      logger.log(
          '  [locateByNamingConventions] ${h1.discoveredTargets.length} targets');
      for (final t in h1.discoveredTargets) {
        logger
            .log('    - [${t.compiler}] src: ${t.source} -> out: ${t.output}');
      }
    }

    final h2 = await _locateByEndpointUsage(
      worker.source,
      projectRoot: root,
      allowedCompilers: allowedCompilers,
      outputDirs: outputDirs,
      analyzer: fileAnalyzer,
    );
    if (h2 != null) {
      logger.log(
          '  [locateByEndpointUsage] ${h2.discoveredTargets.length} targets');
      for (final t in h2.discoveredTargets) {
        logger
            .log('    - [${t.compiler}] src: ${t.source} -> out: ${t.output}');
      }
    }

    final resolved = await resolveTargets(worker,
        projectRoot: root, outputDirs: outputDirs, analyzer: fileAnalyzer);
    logger.log('  [resolveTargets (merged)] ${resolved.length} targets');
    for (final t in resolved) {
      if (t.candidates.isEmpty) {
        logger.log('    - [${t.compiler}] [NO CANDIDATE FOUND]');
      } else if (t.candidates.length > 1) {
        logger.log(
            '    - [${t.compiler}] [AMBIGUOUS: ${t.candidates.length} candidates]');
        for (final candidate in t.candidates) {
          logger.log(
              '        ? [${candidate.method}] src: ${candidate.source} -> out: ${candidate.output}');
        }
      } else {
        final candidate = t.candidates.first;
        logger.log(
            '    - [${t.compiler}] [${candidate.method}] src: ${candidate.source} -> out: ${candidate.output}');
      }
    }
  }

  /// Runs diagnostics comparing manifest targets vs both heuristic methods for all workers.
  static Future<void> runDiagnostics(
    SquadronManifest manifest, {
    String? projectRoot,
    required BuildLogger logger,
    DartFileAnalyzer? analyzer,
  }) async {
    final fileAnalyzer = analyzer ?? DartFileAnalyzer();
    logger.log('=== Squadron Workers Heuristics Diagnostics ===');
    for (final worker in manifest.workers) {
      final outputDirs =
          worker.outputs != null ? manifest.outputs[worker.outputs] : null;
      await runWorkerDiagnostics(
        worker,
        projectRoot: projectRoot,
        logger: logger,
        outputDirs: outputDirs,
        analyzer: fileAnalyzer,
      );
    }
    logger.log('=============================================');
  }
}

/// Checks if a Dart file contains a main() entry point function using DartFileAnalysis.
Future<bool> _hasMain(File file, [DartFileAnalyzer? analyzer]) async =>
    (await (analyzer ?? DartFileAnalyzer()).analyze(file)).hasMain;

Future<File?> _findFirstEntryPoint(
  Iterable<File?> candidates, [
  DartFileAnalyzer? analyzer,
]) async {
  for (var candidate in candidates.nonNulls) {
    if (await _hasMain(candidate, analyzer)) return candidate;
  }
  return null;
}

class HeuristicResult {
  HeuristicResult._({
    required this.workerSource,
    required this.discoveredTargets,
    required this.method,
  });

  static HeuristicResult? from({
    required List<CompilationTarget> discoveredTargets,
    required String workerSource,
    required String method,
  }) =>
      discoveredTargets.isEmpty
          ? null
          : HeuristicResult._(
              workerSource: workerSource,
              discoveredTargets: discoveredTargets,
              method: method,
            );

  final String workerSource;
  final List<CompilationTarget> discoveredTargets;
  final String method;
}

class CompilationTargets {
  CompilationTargets({
    required this.worker,
    required this.compiler,
  });

  final String worker;
  final String compiler;
  final candidates = <({
    String method,
    String source,
    String output,
    Map<String, String> defines,
    String optimizationLevel
  })>[];
}
