@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../lib/src/heuristics.dart';
import '../lib/src/manifest.dart';

void main() {
  group('WorkerHeuristics', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('heuristics_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('locates entrypoint when generated code is in a DIFFERENT directory',
        () async {
      // Create service file in lib/src/services/sample_service.dart
      final serviceDir =
          Directory(path.join(tempDir.path, 'lib', 'src', 'services'))
            ..createSync(recursive: true);
      File(path.join(serviceDir.path, 'sample_service.dart'))
          .writeAsStringSync('class SampleService {}');

      // Create generated entrypoint file in a DIFFERENT folder: bin/generated/sample_service.vm.g.dart
      final genDir = Directory(path.join(tempDir.path, 'bin', 'generated'))
        ..createSync(recursive: true);
      File(path.join(genDir.path, 'sample_service.vm.g.dart'))
          .writeAsStringSync('void main() { print("worker"); }');

      final worker = WorkerDefinition(
        source: 'lib/src/services/sample_service.dart',
        targets: [],
      );

      final targets = await WorkerHeuristics.resolveTargets(
        worker,
        projectRoot: tempDir.path,
      );

      final exeGroup = targets.firstWhere((t) => t.compiler == 'exe');
      expect(exeGroup.candidates, hasLength(1));
      expect(exeGroup.candidates.first.source,
          equals('bin/generated/sample_service.vm.g.dart'));
      expect(exeGroup.candidates.first.method,
          equals('locateByNamingConventions'));
    });

    test('locates companion worker entrypoint in a DIFFERENT directory',
        () async {
      // Create service file in lib/src/services/sample_service.dart
      final serviceDir =
          Directory(path.join(tempDir.path, 'lib', 'src', 'services'))
            ..createSync(recursive: true);
      File(path.join(serviceDir.path, 'sample_service.dart'))
          .writeAsStringSync('class SampleService {}');

      // Create companion worker file in a DIFFERENT folder: test/workers/sample_worker.dart
      final workerDir = Directory(path.join(tempDir.path, 'test', 'workers'))
        ..createSync(recursive: true);
      File(path.join(workerDir.path, 'sample_worker.dart'))
          .writeAsStringSync('void main() { print("worker"); }');

      final worker = WorkerDefinition(
        source: 'lib/src/services/sample_service.dart',
        targets: [],
      );

      final targets = await WorkerHeuristics.resolveTargets(
        worker,
        projectRoot: tempDir.path,
      );

      final exeGroup = targets.firstWhere((t) => t.compiler == 'exe');
      expect(exeGroup.candidates, hasLength(1));
      expect(exeGroup.candidates.first.source,
          equals('test/workers/sample_worker.dart'));
    });

    test(
        'prioritizes higher precedence naming convention in a DIFFERENT directory over lower precedence in SAME directory',
        () async {
      final serviceDir =
          Directory(path.join(tempDir.path, 'lib', 'src', 'services'))
            ..createSync(recursive: true);
      // Service file (same directory) has main()
      File(path.join(serviceDir.path, 'sample_service.dart'))
          .writeAsStringSync('void main() {}');

      // Generated IPC file (different directory) also has main()
      final genDir = Directory(path.join(tempDir.path, 'bin', 'workers'))
        ..createSync(recursive: true);
      File(path.join(genDir.path, 'sample_service.vm.g.dart'))
          .writeAsStringSync('void main() {}');

      final worker = WorkerDefinition(
        source: 'lib/src/services/sample_service.dart',
        targets: [],
      );

      final targets = await WorkerHeuristics.resolveTargets(
        worker,
        projectRoot: tempDir.path,
      );

      final exeGroup = targets.firstWhere((t) => t.compiler == 'exe');
      expect(exeGroup.candidates.first.source,
          equals('bin/workers/sample_service.vm.g.dart'));
    });

    test(
        'locates web entrypoint when generated code is in a DIFFERENT directory',
        () async {
      final serviceDir =
          Directory(path.join(tempDir.path, 'lib', 'src', 'services'))
            ..createSync(recursive: true);
      File(path.join(serviceDir.path, 'sample_service.dart'))
          .writeAsStringSync('class SampleService {}');

      final webGenDir = Directory(path.join(tempDir.path, 'web', 'generated'))
        ..createSync(recursive: true);
      File(path.join(webGenDir.path, 'sample_service.web.g.dart'))
          .writeAsStringSync('void main() {}');

      final worker = WorkerDefinition(
        source: 'lib/src/services/sample_service.dart',
        targets: [],
      );

      final targets = await WorkerHeuristics.resolveTargets(
        worker,
        projectRoot: tempDir.path,
      );

      final jsGroup = targets.firstWhere((t) => t.compiler == 'js');
      expect(jsGroup.candidates, hasLength(1));
      expect(jsGroup.candidates.first.source,
          equals('web/generated/sample_service.web.g.dart'));

      final wasmGroup = targets.firstWhere((t) => t.compiler == 'wasm');
      expect(wasmGroup.candidates, hasLength(1));
      expect(wasmGroup.candidates.first.source,
          equals('web/generated/sample_service.web.g.dart'));
    });
  });
}
