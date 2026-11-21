part of 'heuristics.dart';

/// Advanced heuristic: discovers companion entrypoint files in the workspace
/// given a worker service source, analyzing endpoint usages (IpcEntryPoint, InProcEntryPoint, runProcessWorker).
/// Strictly requires main() for any discovered compilation target.
/// If [allowedCompilers] is specified, only targets matching those compilers are resolved.
Future<HeuristicResult?> _locateByEndpointUsage(
  String workerSource, {
  required String projectRoot,
  required Set<String> allowedCompilers,
  Map<String, String>? outputDirs,
  DartFileAnalyzer? analyzer,
}) async {
  final fileAnalyzer = analyzer ?? DartFileAnalyzer();
  final rootDir = Directory(projectRoot);
  final sourceFile = resolveFile(workerSource, projectRoot);
  if (sourceFile == null) return null;

  final discoveredTargets = <CompilationTarget>[];
  final serviceBaseName = path.basenameWithoutExtension(sourceFile.path);

  final allowsExe = allowedCompilers.contains('exe');
  final allowsJs = allowedCompilers.contains('js');
  final allowsWasm = allowedCompilers.contains('wasm');

  final allFiles = rootDir
      .list(recursive: true)
      .where((f) =>
          f is File &&
          f.path.endsWith('.dart') &&
          !f.path.contains('.dart_tool') &&
          !f.path.contains('build'))
      .cast<File>();

  await for (final file in allFiles) {
    try {
      final analysis = await fileAnalyzer.analyze(file);
      if (analysis.hasMain) {
        final content = await file.readAsString();
        final referencesService = content.contains(serviceBaseName);

        if (referencesService) {
          final isIpcProcess =
              content.contains(RegExp(r'\brunWorkerProcess\b'));
          final isWebWorker = content.contains(RegExp(r'\brunWorkerService\b'));

          final relPath =
              path.relative(file.path, from: projectRoot).replaceAll('\\', '/');

          if (isIpcProcess && allowsExe) {
            discoveredTargets
                .add(CompilationTarget.exe(relPath, outputDirs?['exe']));
          } else if (isWebWorker) {
            discoveredTargets.addAll([
              if (allowsJs) CompilationTarget.js(relPath, outputDirs?['js']),
              if (allowsWasm)
                CompilationTarget.wasm(relPath, outputDirs?['wasm']),
            ]);
          }
        }
      }
    } catch (_) {}
  }

  return HeuristicResult.from(
    workerSource: workerSource,
    discoveredTargets: discoveredTargets,
    method: 'locateByEndpointUsage',
  );
}
