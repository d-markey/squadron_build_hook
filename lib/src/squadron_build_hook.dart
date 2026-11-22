import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:synchronize/synchronize.dart';

import 'backends/compiler_registry.dart';
import 'build_cache.dart';
import 'compiler.dart';
import 'dart_file_analysis.dart';
import 'heuristics/heuristics.dart';
import 'manifest.dart';
import 'utils.dart';

class StandaloneBuildResult {
  const StandaloneBuildResult({
    required this.workersLoaded,
    required this.totalTargets,
    required this.compiledTargets,
    required this.workersNotCompiled,
  });

  final int workersLoaded;
  final int totalTargets;
  final int compiledTargets;
  final List<String> workersNotCompiled;

  bool get success =>
      workersLoaded > 0 &&
      workersNotCompiled.isEmpty &&
      compiledTargets == totalTargets;
}

class WorkerResolutionResult {
  const WorkerResolutionResult({
    required this.associatedTargetsCount,
    required this.targetsToCompile,
    required this.hasAmbiguity,
    this.ambiguityMessage,
  });

  final int associatedTargetsCount;
  final List<CompilationTarget> targetsToCompile;
  final bool hasAmbiguity;
  final String? ambiguityMessage;
}

Future<StandaloneBuildResult> runStandalone({
  int concurrency = 2,
  bool force = false,
  BuildLogger? logger,
  CompilerRegistry? registry,
}) async {
  final mainLogger = logger ?? getLogger();
  final pckRoot = await SquadronManifest.findPackageRoot();
  final manifest = await SquadronManifest.load(pckRoot);
  if (manifest == null) {
    mainLogger.log('No squadron.manifest[.yaml] found in $pckRoot');
    return const StandaloneBuildResult(
      workersLoaded: 0,
      totalTargets: 0,
      compiledTargets: 0,
      workersNotCompiled: [],
    );
  }

  mainLogger.log(
      'Loaded ${manifest.workers.length} workers from ${path.basename(manifest.manifestFile.path)}.');

  final cache = await BuildCache.load(pckRoot);
  final analyzer = DartFileAnalyzer();
  final compiler = WorkerCompiler(projectRoot: pckRoot, registry: registry);
  final semaphore = Semaphore(concurrency, maxCount: concurrency);

  int totalAssociatedTargets = 0;
  int totalCompiledTargets = 0;
  final notCompiledWorkers = <String>[];

  Future<void> processWorker(WorkerDefinition worker) async {
    final workerLogger =
        getLogger(tag: path.basename(worker.source), log: mainLogger.log);

    final resolution = await _resolveWorkerTargets(
      worker,
      projectRoot: pckRoot,
      manifestOutputs: manifest.outputs,
      logger: workerLogger,
      analyzer: analyzer,
      throwOnAmbiguity: false,
    );

    int workerCompiledCount = 0;
    bool compilationFailed = false;

    if (!resolution.hasAmbiguity) {
      for (final target in resolution.targetsToCompile) {
        if (!force &&
            await cache.isTargetUpToDate(target,
                projectRoot: pckRoot, logger: workerLogger)) {
          workerLogger.log(
              'Standalone: Target [${target.compiler}] ${target.source} -> ${target.output} is up-to-date (skipped)');
          workerCompiledCount++;
          continue;
        }

        final lock = await semaphore.enter();
        try {
          workerLogger.log(
              'Standalone: Compiling [${target.compiler}] ${target.source} -> ${target.output}');
          final result = await compiler.compile(
            compiler: target.compiler,
            source: target.source,
            output: target.output,
            defines: target.defines,
            optimizationLevel: target.optimizationLevel,
            logger: workerLogger,
          );
          if (result.exitCode != 0) {
            compilationFailed = true;
            workerLogger.log(
                'Standalone: Failed to compile [${target.compiler}] ${target.source} with exit code ${result.exitCode}');
          } else {
            workerCompiledCount++;
            workerLogger.log(
                'Standalone: Target produced ${result.dependencies.length} dependencies');
            final targetDeps = <String>{};
            if (result.dependencies.isNotEmpty) {
              for (final dep in result.dependencies) {
                _registerDependencyUri(dep, targetDeps);
              }
            } else {
              await _registerSourceDependencies(
                target.source,
                projectRoot: pckRoot,
                dependencies: targetDeps,
                analyzer: analyzer,
              );
            }
            await cache.updateTarget(
              target,
              projectRoot: pckRoot,
              dependencies: targetDeps.toList(),
            );
          }
        } catch (e) {
          compilationFailed = true;
          workerLogger.log(
              'Standalone: Error compiling [${target.compiler}] ${target.source}: $e');
        } finally {
          lock.release();
        }
      }
    } else {
      workerLogger.log(
          'Standalone: Skipping worker ${worker.name} due to ambiguity: ${resolution.ambiguityMessage}');
    }

    final isCompiled = !resolution.hasAmbiguity &&
        !compilationFailed &&
        resolution.associatedTargetsCount > 0 &&
        workerCompiledCount == resolution.associatedTargetsCount;

    totalAssociatedTargets += resolution.associatedTargetsCount;
    totalCompiledTargets += workerCompiledCount;
    if (!isCompiled) {
      notCompiledWorkers.add(worker.name);
    }
  }

  // Launch all workers concurrently, regulated by the semaphore
  await Future.wait(manifest.workers.map(processWorker));

  await cache.save(pckRoot);

  mainLogger.log('Standalone build summary:');
  mainLogger.log('  * Workers loaded: ${manifest.workers.length}');
  mainLogger.log('  * Total associated targets: $totalAssociatedTargets');
  mainLogger.log('  * Targets compiled: $totalCompiledTargets');
  if (notCompiledWorkers.isNotEmpty) {
    mainLogger.log('  * Workers not compiled (${notCompiledWorkers.length}):');
    for (final name in notCompiledWorkers) {
      mainLogger.log('    - $name');
    }
  } else {
    mainLogger.log('Standalone build completed successfully.');
  }

  return StandaloneBuildResult(
    workersLoaded: manifest.workers.length,
    totalTargets: totalAssociatedTargets,
    compiledTargets: totalCompiledTargets,
    workersNotCompiled: notCompiledWorkers,
  );
}

Future<void> runSquadronBuildHook(
  List<String> args, {
  int concurrency = 2,
  bool force = false,
  BuildLogger? logger,
  CompilerRegistry? registry,
}) async {
  await build(args, (input, output) async {
    final mainLogger = logger ?? getLogger();
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
    final cache = await BuildCache.load(pckRoot);
    final analyzer = DartFileAnalyzer();
    final dependencies = <String>{};
    final compiler = WorkerCompiler(projectRoot: pckRoot, registry: registry);
    final semaphore = Semaphore(concurrency, maxCount: concurrency);

    Future<void> processWorker(WorkerDefinition worker) async {
      final logger =
          getLogger(tag: path.basename(worker.source), log: mainLogger.log);

      final workerSrcFile = resolveFile(worker.source, pckRoot);
      if (workerSrcFile == null) {
        logger.logAndThrow('Worker source file not found: ${worker.source}');
      }

      final resolution = await _resolveWorkerTargets(
        worker,
        projectRoot: pckRoot,
        manifestOutputs: manifest.outputs,
        logger: logger,
        analyzer: analyzer,
        throwOnAmbiguity: true,
      );

      if (resolution.hasAmbiguity) {
        logger.logAndThrow(resolution.ambiguityMessage ??
            'Ambiguous target for worker ${worker.name}');
      }

      if (worker.targets.isNotEmpty &&
          resolution.targetsToCompile.length < worker.targets.length) {
        logger.logAndThrow(
            'Worker ${worker.name} has missing/unresolvable targets: expected ${worker.targets.length}, resolved ${resolution.targetsToCompile.length}');
      }

      if (resolution.targetsToCompile.isEmpty) {
        logger.logAndThrow(
            'No valid compilation targets found for worker ${worker.name}');
      }

      for (final target in resolution.targetsToCompile) {
        if (!force &&
            await cache.isTargetUpToDate(target,
                projectRoot: pckRoot, logger: logger)) {
          logger.log(
              'Target [${target.compiler}] ${target.source} -> ${target.output} is up-to-date (skipped)');
          final cachedDeps = cache.getTargetDependencies(
            target,
            projectRoot: pckRoot,
          );
          for (final dep in cachedDeps) {
            _registerDependencyUri(dep, dependencies);
          }
          continue;
        }

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

          final targetDeps = <String>{};
          if (result.dependencies.isNotEmpty) {
            for (final dep in result.dependencies) {
              _registerDependencyUri(dep, targetDeps);
            }
          } else {
            await _registerSourceDependencies(
              target.source,
              projectRoot: pckRoot,
              dependencies: targetDeps,
              analyzer: analyzer,
            );
          }

          await cache.updateTarget(
            target,
            projectRoot: pckRoot,
            dependencies: targetDeps.toList(),
          );
          dependencies.addAll(targetDeps);
        } finally {
          lock.release();
        }
      }
    }

    // Launch all workers concurrently, regulated by the semaphore
    await Future.wait(manifest.workers.map(processWorker));

    await cache.save(pckRoot);

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
Future<WorkerResolutionResult> _resolveWorkerTargets(
  WorkerDefinition worker, {
  required String projectRoot,
  required Map<String, Map<String, String>> manifestOutputs,
  required BuildLogger logger,
  DartFileAnalyzer? analyzer,
  bool throwOnAmbiguity = false,
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
    return WorkerResolutionResult(
      associatedTargetsCount: worker.targets.length,
      targetsToCompile: resolvedTargets,
      hasAmbiguity: false,
    );
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

  final ambiguousGroups =
      heuristicGroups.where((g) => g.candidates.length > 1).toList();

  if (ambiguousGroups.isNotEmpty) {
    final msg = ambiguousGroups.map((g) {
      final candidates = g.candidates.map((c) => c.source).join(', ');
      return 'Ambiguous target [${g.compiler}] with ${g.candidates.length} candidates ($candidates)';
    }).join('; ');

    logger.log('Ambiguity detected for worker ${worker.name}: $msg');

    if (throwOnAmbiguity) {
      logger.logAndThrow('Worker ${worker.name} cannot be compiled: $msg');
    }

    final associatedCount = worker.targets.isNotEmpty
        ? worker.targets.length
        : heuristicGroups.where((g) => g.candidates.isNotEmpty).length;

    return WorkerResolutionResult(
      associatedTargetsCount: associatedCount,
      targetsToCompile: const [],
      hasAmbiguity: true,
      ambiguityMessage: msg,
    );
  }

  final compiledTargets = <CompilationTarget>[];
  for (final group in heuristicGroups) {
    if (group.candidates.isEmpty) {
      logger.log(
        'Skipping [${group.compiler}]: No entrypoint candidate found.',
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

  final associatedCount = worker.targets.isNotEmpty
      ? worker.targets.length
      : compiledTargets.length;

  return WorkerResolutionResult(
    associatedTargetsCount: associatedCount,
    targetsToCompile: compiledTargets,
    hasAmbiguity: false,
  );
}

void _registerDependencyUri(String depPath, Set<String> dependencies) {
  if (depPath.toLowerCase().startsWith('dart:')) return;

  final file = resolveFile(depPath)?.absolute;
  if (file == null) return;

  // Ignore Dart SDK internal libraries/snapshots
  final normalizedPath = file.path.toLowerCase().replaceAll('\\', '/');
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
