import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:synchronize/synchronize.dart';

import 'compiler.dart';
import 'dart_file_analysis.dart';
import 'heuristics.dart';
import 'manifest.dart';
import 'utils.dart';

Future<void> runStandalone({int concurrency = 2}) async {
  final mainLogger = getLogger();
  final pckRoot = await SquadronManifest.findPackageRoot();
  final manifest = await SquadronManifest.load(pckRoot);
  if (manifest == null) {
    mainLogger.log('No squadron.manifest[.yaml] found in $pckRoot');
    return;
  } else {
    mainLogger.log(
        'Loaded ${manifest.workers.length} workers from ${path.basename(manifest.manifestFile.path)}.');
  }

  final analyzer = DartFileAnalyzer();
  final compiler = WorkerCompiler(projectRoot: pckRoot);
  final semaphore = Semaphore(concurrency, maxCount: concurrency);

  Future<void> processWorker(WorkerDefinition worker) async {
    final logger = getLogger(tag: path.basename(worker.source));

    final targets = await _resolveWorkerTargets(
      worker,
      projectRoot: pckRoot,
      manifestOutputs: manifest.outputs,
      logger: logger,
      analyzer: analyzer,
    );

    for (final target in targets) {
      final lock = await semaphore.enter();
      try {
        logger.log(
            'Standalone: Compiling [${target.compiler}] ${target.source} -> ${target.output}');
        final result = await compiler.compile(
          compiler: target.compiler,
          source: target.source,
          output: target.output,
          defines: target.defines,
          optimizationLevel: target.optimizationLevel,
          logger: logger,
        );
        if (result.exitCode != 0) {
          logger.logAndThrow(
              'Failed to compile [${target.compiler}] ${target.source} with exit code ${result.exitCode}');
        }
        logger.log(
            'Standalone: Target produced ${result.dependencies.length} dependencies');
      } finally {
        lock.release();
      }
    }
  }

  // Launch all workers concurrently, regulated by the semaphore
  await Future.wait(manifest.workers.map(processWorker));

  mainLogger.log('Standalone build completed successfully.');
}

Future<void> runSquadronBuildHook(List<String> args,
    {int concurrency = 2}) async {
  await build(args, (input, output) async {
    final mainLogger = getLogger();
    mainLogger.log('Squadron build hook started...');

    final pckRoot = File(input.packageRoot.toFilePath()).absolute.path;
    final manifest = await SquadronManifest.load(pckRoot);
    if (manifest == null) {
      mainLogger.log('No squadron.manifest[.yaml] found in $pckRoot');
      return;
    }

    // 1. Register top-level configuration dependencies for cache invalidation
    output.dependencies.add(input.packageRoot.resolve('pubspec.lock'));
    output.dependencies
        .add(input.packageRoot.resolve('.dart_tool/package_config.json'));
    output.dependencies.add(manifest.manifestFile.uri);

    // 2. Report manifest status
    mainLogger.log(
        'Loaded ${manifest.workers.length} workers from ${path.basename(manifest.manifestFile.path)}.');

    // 3. Compile workers: only run diagnostics when manifest is partial or wrong
    final analyzer = DartFileAnalyzer();
    final dependencies = <String>{};
    final compiler = WorkerCompiler(projectRoot: pckRoot);
    final semaphore = Semaphore(concurrency, maxCount: concurrency);

    Future<void> processWorker(WorkerDefinition worker) async {
      final logger = getLogger(tag: path.basename(worker.source));
      final targets = await _resolveWorkerTargets(
        worker,
        projectRoot: pckRoot,
        manifestOutputs: manifest.outputs,
        logger: logger,
        analyzer: analyzer,
      );

      for (final target in targets) {
        final lock = await semaphore.enter();
        try {
          logger.log(
              'Compiling [${target.compiler}] ${target.source} -> ${target.output}');
          final result = await compiler.compile(
            compiler: target.compiler,
            source: target.source,
            output: target.output,
            defines: target.defines,
            optimizationLevel: target.optimizationLevel,
            logger: logger,
          );
          if (result.exitCode != 0) {
            logger.logAndThrow(
                'Failed to compile worker target [${target.compiler}] ${target.source} with exit code ${result.exitCode}');
          }

          if (result.dependencies.isNotEmpty) {
            for (final dep in result.dependencies) {
              _registerDependencyUri(dep, dependencies);
            }
          } else {
            _registerSourceDependencies(
              target.source,
              projectRoot: pckRoot,
              dependencies: dependencies,
              analyzer: analyzer,
            );
          }
        } finally {
          lock.release();
        }
      }
    }

    // Launch all workers concurrently, regulated by the semaphore
    await Future.wait(manifest.workers.map(processWorker));

    output.dependencies.addAll(dependencies.map(Uri.file));

    // 4. Emit build log / asset via code_assets
    final assetName = 'squadron_build_result.txt';
    final assetPath = input.outputDirectory.resolve(assetName);
    await File.fromUri(assetPath).writeAsString(
        'Squadron build hook completed successfully at ${DateTime.now()}\n');

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: assetName,
        file: assetPath,
        linkMode: DynamicLoadingBundled(),
      ),
    );
    mainLogger.log('Squadron build hook completed successfully.');
  });
}

/// Resolves compilation targets for a worker with diagnostic-driven heuristics:
/// 1. If the manifest provides fully valid targets (source exists and output is set),
///    use them directly without running diagnostics.
/// 2. If the manifest has valid source but empty output, directly infer output without diagnostics.
/// 3. If the manifest is partial (no targets) or wrong (source file doesn't exist),
///    run worker diagnostics, report ambiguities, and only compile if exactly one candidate is found.
Future<List<CompilationTarget>> _resolveWorkerTargets(
  WorkerDefinition worker, {
  required String projectRoot,
  required Map<String, Map<String, String>> manifestOutputs,
  required BuildLogger logger,
  DartFileAnalyzer? analyzer,
}) async {
  final resolvedTargets = <CompilationTarget>[];
  bool needsDiagnostics = false;

  final outputDirs =
      worker.outputs != null ? manifestOutputs[worker.outputs] : null;

  if (worker.targets.isEmpty) {
    needsDiagnostics = true;
  } else {
    for (final t in worker.targets) {
      if (t.source.isEmpty) {
        needsDiagnostics = true;
        break;
      }
      final srcFile = resolveFile(t.source, projectRoot);
      if (srcFile == null) {
        needsDiagnostics = true;
        break;
      }

      // Valid source: use given output or infer output using the worker's named output folder
      final outputDir = outputDirs?[t.compiler];
      final output = t.output.isNotEmpty
          ? t.output
          : WorkerHeuristics.inferOutput(t.compiler, t.source, outputDir);
      resolvedTargets.add(CompilationTarget(
        compiler: t.compiler,
        source: t.source,
        output: output,
        defines: t.defines,
        optimizationLevel: t.optimizationLevel.isNotEmpty
            ? t.optimizationLevel
            : worker.optimizationLevel,
      ));
    }
  }

  // If manifest was fully valid, return directly without running diagnostics
  if (!needsDiagnostics && resolvedTargets.length == worker.targets.length) {
    return resolvedTargets;
  }

  // Otherwise, run diagnostics for this worker to report errors/discoveries
  await WorkerHeuristics.runWorkerDiagnostics(
    worker,
    projectRoot: projectRoot,
    outputDirs: outputDirs,
    logger: logger,
    analyzer: analyzer,
  );

  // Re-resolve using heuristics, taking named outputDirs into account
  final heuristicGroups = await WorkerHeuristics.resolveTargets(
    worker,
    projectRoot: projectRoot,
    outputDirs: outputDirs,
    analyzer: analyzer,
  );
  final compiledTargets = <CompilationTarget>[];

  for (final group in heuristicGroups) {
    if (group.candidates.isEmpty) {
      logger.log(
        'Skipping [${group.compiler}]: '
        'No entrypoint candidate found.',
      );
    } else if (group.candidates.length > 1) {
      logger.log(
        'Skipping [${group.compiler}]: '
        'Ambiguous target with ${group.candidates.length} candidates.',
      );
    } else {
      final c = group.candidates.first;
      compiledTargets.add(CompilationTarget(
        compiler: group.compiler,
        source: c.source,
        output: c.output,
        defines: c.defines,
        optimizationLevel: c.optimizationLevel.isNotEmpty
            ? c.optimizationLevel
            : worker.optimizationLevel,
      ));
    }
  }

  return compiledTargets;
}

void _registerDependencyUri(String depPath, Set<String> dependencies) {
  if (depPath.toLowerCase().startsWith('dart:')) return;

  final file = resolveFile(depPath)?.absolute;
  if (file == null) return;

  // Ignore Dart SDK internal libraries/snapshots
  final normalizedPath = file.path.toLowerCase();
  if (normalizedPath.contains('/dart-sdk/') ||
      normalizedPath.contains('/lib/_internal/')) {
    return;
  }

  dependencies.add(
    Platform.isWindows
        ? path.canonicalize(file.path).toLowerCase()
        : path.canonicalize(file.path),
  );
}

Future<void> _registerSourceDependencies(
  String sourcePath, {
  required String projectRoot,
  required Set<String> dependencies,
  DartFileAnalyzer? analyzer,
}) async {
  final srcFile = resolveFile(sourcePath, projectRoot);
  if (srcFile != null) {
    _registerDependencyUri(srcFile.path, dependencies);
    try {
      final fileAnalyzer = analyzer ?? DartFileAnalyzer();
      final analysis = await fileAnalyzer.analyze(srcFile);
      final dir = srcFile.parent.path;
      for (final uri in [...analysis.imports, ...analysis.parts]) {
        if (!uri.startsWith('dart:') && !uri.startsWith('package:')) {
          final relFile = resolveFile(uri, dir);
          if (relFile != null) {
            _registerDependencyUri(relFile.path, dependencies);
          }
        }
      }
    } catch (_) {}
  }
}
