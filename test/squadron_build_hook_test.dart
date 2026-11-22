@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../lib/src/squadron_build_hook.dart';
import '../lib/src/utils.dart';

void main() {
  group('Squadron Build Hook and Standalone Build Stats', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('squadron_stats_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('StandaloneBuildResult correctly computes success status', () {
      const successResult = StandaloneBuildResult(
        workersLoaded: 2,
        totalTargets: 4,
        compiledTargets: 4,
        workersNotCompiled: [],
      );
      expect(successResult.success, isTrue);

      const partialResult = StandaloneBuildResult(
        workersLoaded: 2,
        totalTargets: 4,
        compiledTargets: 2,
        workersNotCompiled: ['lib/ambiguous_worker.dart'],
      );
      expect(partialResult.success, isFalse);
      expect(partialResult.workersNotCompiled,
          equals(['lib/ambiguous_worker.dart']));
      expect(partialResult.totalTargets, equals(4));
      expect(partialResult.compiledTargets, equals(2));
    });

    test(
        'standalone build detects ambiguity, does NOT compile ambiguous worker, and provides stats and uncompiled worker names',
        () async {
      // 1. Create pubspec.yaml so findPackageRoot locates tempDir
      File(path.join(tempDir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: test_pkg\nenvironment:\n  sdk: ^3.4.0\n');

      // 2. Create worker 1: unambiguous
      final w1Source = 'lib/services/service1.dart';
      File(path.join(tempDir.path, w1Source))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Service1 {}');
      final s1Gen =
          File(path.join(tempDir.path, 'lib/services/service1.vm.g.dart'))
            ..writeAsStringSync('void main() {}');

      // 3. Create worker 2: ambiguous (two candidate entrypoints for exe)
      final w2Source = 'lib/services/service2.dart';
      File(path.join(tempDir.path, 'lib/workers/service2_worker_entrypoint.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
            'import \'$w2Source\';'
            'void main() { runWorkerProcess(); }'
        ); // candidate 1 (locateByEndpointUsage)
      File(path.join(tempDir.path, 'lib/workers/service2.vm.g.dart'))
        ..writeAsStringSync('void main() {}'); // candidate 2 (locateByNamingConventions)

      // 4. Create squadron.manifest.yaml
      File(path.join(tempDir.path, 'squadron.manifest.yaml'))
          .writeAsStringSync('''
workers:
  - source: $w1Source
    targets:
      - compiler: exe
        source: ${path.relative(s1Gen.path, from: tempDir.path)}
  - source: $w2Source
    targets:
      - compiler: exe
''');

      final initialDir = Directory.current;
      try {
        Directory.current = tempDir;
        final logs = <String>[];
        final testLogger = getLogger(
          tag: 'TEST',
          log: (line) => logs.add(line),
        );

        final result = await runStandalone(logger: testLogger);

        expect(result.workersLoaded, equals(2));
        // Worker 1 has 1 target. Worker 2 has 1 target. Total = 2 targets.
        expect(result.totalTargets, equals(2));
        // Worker 2 has ambiguous candidates (service2.dart and service2.vm.g.dart), so it is NOT compiled.
        expect(result.workersNotCompiled, contains(w2Source));
        expect(logs.any((l) => l.contains('Workers loaded: 2')), isTrue);
        expect(
            logs.any((l) => l.contains('Total associated targets: 2')), isTrue);
        expect(logs.any((l) => l.contains('Workers not compiled')), isTrue);
      } finally {
        Directory.current = initialDir;
      }
    });

    test('standalone build caches dependencies and skips up-to-date targets on 2nd run', () async {
      File(path.join(tempDir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: test_pkg\nenvironment:\n  sdk: ^3.4.0\n');

      final wSource = 'lib/services/service1.dart';
      final sFile = File(path.join(tempDir.path, wSource))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Service1 {}');
      final sGen =
          File(path.join(tempDir.path, 'lib/services/service1.vm.g.dart'))
            ..writeAsStringSync(
                "import 'service1.dart';\nvoid main() { final _ = Service1(); }");
      final outFile =
          File(path.join(tempDir.path, 'bin/workers/service1.vm.g.dart.exe'));

      File(path.join(tempDir.path, 'squadron.manifest.yaml'))
          .writeAsStringSync('''
workers:
  - source: $wSource
    targets:
      - compiler: exe
        source: ${path.relative(sGen.path, from: tempDir.path)}
        output: ${path.relative(outFile.path, from: tempDir.path)}
''');

      final initialDir = Directory.current;
      try {
        Directory.current = tempDir;

        // --- FIRST RUN ---
        final logs1 = <String>[];
        final logger1 = getLogger(tag: 'RUN1', log: (line) => logs1.add(line));
        final result1 = await runStandalone(logger: logger1);

        expect(result1.success, isTrue);
        expect(result1.compiledTargets, equals(1));
        expect(logs1.any((l) => l.contains('Compiling [exe]')), isTrue);
        expect(outFile.existsSync(), isTrue);

        // --- SECOND RUN (Unchanged) ---
        final logs2 = <String>[];
        final logger2 = getLogger(tag: 'RUN2', log: (line) => logs2.add(line));
        final result2 = await runStandalone(logger: logger2);

        expect(result2.success, isTrue);
        expect(result2.compiledTargets, equals(1));
        expect(logs2.any((l) => l.contains('is up-to-date (skipped)')), isTrue);

        // --- THIRD RUN (Modify source) ---
        sFile.writeAsStringSync('class Service1 { final int x = 1; }');

        final logs3 = <String>[];
        final logger3 = getLogger(tag: 'RUN3', log: (line) => logs3.add(line));
        final result3 = await runStandalone(logger: logger3);

        expect(result3.success, isTrue);
        expect(result3.compiledTargets, equals(1));
        expect(logs3.any((l) => l.contains('Compiling [exe]')), isTrue);
        expect(result3.compiledTargets, equals(1));
        expect(logs3.any((l) => l.contains('Compiling [exe]')), isTrue);
      } finally {
        Directory.current = initialDir;
      }
    });
  });
}
