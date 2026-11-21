part of 'heuristics.dart';

/// Searches for candidate files matching naming conventions, checking both
/// the service file's parent directory and other directories in [projectRoot].
Future<List<File>> _findCandidateFiles(
  String projectRoot,
  File sourceFile,
  List<String> candidateNames,
) async {
  final serviceDir = sourceFile.parent;

  final inDirFiles = <String, File>{};
  final missingNames = <String>[];
  for (final name in candidateNames) {
    final f = resolveFile(name, serviceDir.path);
    if (f != null) {
      inDirFiles[name] = f;
    } else {
      missingNames.add(name);
    }
  }

  final inProjectFiles = <String, List<File>>{};
  if (missingNames.isNotEmpty) {
    final rootDir = Directory(projectRoot);
    final searchNames = missingNames.toSet();

    try {
      await for (final entity in rootDir.list(recursive: true)) {
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            !entity.path.contains('.dart_tool') &&
            !entity.path.contains('build')) {
          final fileName = path.basename(entity.path);
          if (searchNames.contains(fileName)) {
            if (!path.equals(entity.parent.path, serviceDir.path)) {
              inProjectFiles.putIfAbsent(fileName, () => []).add(entity);
            }
          }
        }
      }
    } catch (_) {}
  }

  final candidates = <File>[];
  for (final name in candidateNames) {
    final fileInDir = inDirFiles[name];
    if (fileInDir != null) {
      candidates.add(fileInDir);
    }
    final filesInProject = inProjectFiles[name];
    if (filesInProject != null) {
      candidates.addAll(filesInProject);
    }
  }

  return candidates;
}

/// Analyzes a worker source path using naming conventions.
/// Drops files/targets that do not have a main() entry point.
/// If [allowedCompilers] is specified, only targets matching those compilers are resolved.
Future<HeuristicResult?> _locateByNamingConventions(
  String workerSource, {
  required String projectRoot,
  required Set<String> allowedCompilers,
  Map<String, String>? outputDirs,
  DartFileAnalyzer? analyzer,
}) async {
  final sourceFile = resolveFile(workerSource, projectRoot);
  if (sourceFile == null) return null;

  final baseName = path.basenameWithoutExtension(sourceFile.path);

  final allowsExe = allowedCompilers.contains('exe');
  final allowsJs = allowedCompilers.contains('js');
  final allowsWasm = allowedCompilers.contains('wasm');

  final genBaseNames = <String>[baseName];
  if (baseName.contains('_service')) {
    genBaseNames.add(baseName.replaceAll('_service', '_worker'));
  } else if (baseName.contains('_worker')) {
    genBaseNames.add(baseName.replaceAll('_worker', '_service'));
  } else {
    genBaseNames.addAll(['${baseName}_service', '${baseName}_worker']);
  }

  final dartBaseNames = <String>[];
  if (baseName.contains('_service')) {
    dartBaseNames.add(baseName.replaceAll('_service', '_worker'));
    dartBaseNames.add(baseName);
  } else if (baseName.contains('_worker')) {
    dartBaseNames.add(baseName);
    dartBaseNames.add(baseName.replaceAll('_worker', '_service'));
  } else {
    dartBaseNames
        .addAll(['${baseName}_worker', baseName, '${baseName}_service']);
  }

  final discoveredTargets = <CompilationTarget>[];

  if (allowsExe) {
    final exeCandidateNames = [
      for (final b in genBaseNames) '$b.vm.g.dart',
      for (final b in genBaseNames) '$b.g.dart',
      for (final b in dartBaseNames) '$b.dart',
    ];
    final exeCandidates = await _findCandidateFiles(
      projectRoot,
      sourceFile,
      exeCandidateNames,
    );
    final exeSourceFile = await _findFirstEntryPoint(exeCandidates, analyzer);
    if (exeSourceFile != null) {
      final relPath = path
          .relative(exeSourceFile.path, from: projectRoot)
          .replaceAll('\\', '/');
      discoveredTargets.add(CompilationTarget.exe(relPath, outputDirs?['exe']));
    }
  }

  if (allowsJs || allowsWasm) {
    final webCandidateNames = [
      for (final b in genBaseNames) '$b.web.g.dart',
      for (final b in genBaseNames) '$b.g.dart',
      for (final b in dartBaseNames) '$b.dart',
    ];
    final webCandidates = await _findCandidateFiles(
      projectRoot,
      sourceFile,
      webCandidateNames,
    );
    final webSourceFile = await _findFirstEntryPoint(webCandidates, analyzer);

    if (webSourceFile != null) {
      final relPath = path
          .relative(webSourceFile.path, from: projectRoot)
          .replaceAll('\\', '/');
      discoveredTargets.addAll([
        if (allowsJs) CompilationTarget.js(relPath, outputDirs?['js']),
        if (allowsWasm) CompilationTarget.wasm(relPath, outputDirs?['wasm']),
      ]);
    }
  }

  return HeuristicResult.from(
    workerSource: workerSource,
    discoveredTargets: discoveredTargets,
    method: 'locateByNamingConventions',
  );
}
