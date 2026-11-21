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
      final s1File = File(path.join(tempDir.path, w1Source))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Service1 {}');
      final s1Gen =
          File(path.join(tempDir.path, 'lib/services/service1.vm.g.dart'))
            ..writeAsStringSync('void main() {}');

      // 3. Create worker 2: ambiguous (two candidate entrypoints for exe)
      final w2Source = 'lib/services/service2.dart';
      final s2File = File(path.join(tempDir.path, w2Source))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}'); // candidate 1
      final s2Gen =
          File(path.join(tempDir.path, 'lib/services/service2.vm.g.dart'))
            ..writeAsStringSync('void main() {}'); // candidate 2

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
        source: non_existing_file.dart
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
  });
}
