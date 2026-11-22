import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:squadron_build_hook/src/build_cache.dart';
import 'package:squadron_build_hook/src/manifest.dart';
import 'package:test/test.dart';

void main() {
  group('BuildCache and Content Hashing', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('squadron_cache_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('computeFileHash produce consistent hashes', () async {
      final cache = BuildCache();
      final file = File(path.join(tempDir.path, 'sample.txt'))
        ..writeAsStringSync('Hello World');

      final hash1 = await cache.computeFileHash(file);
      final hash2 = await cache.computeFileHash(file);
      expect(hash1, equals(hash2));
      expect(hash1, isNot(equals(0)));

      file.writeAsStringSync('Hello World Modified');
      final hash3 = await cache.computeFileHash(file);
      expect(hash3, isNot(equals(hash1)));
    });

    test('BuildCache load and save lifecycle', () async {
      final cache = await BuildCache.load(tempDir.path);
      expect(cache.targets, isEmpty);

      final target = CompilationTarget(
        compiler: 'js',
        source: 'lib/worker.dart',
        output: 'web/worker.js',
        defines: {'env': 'prod'},
        optimizationLevel: '2',
      );

      final srcFile = File(path.join(tempDir.path, 'lib/worker.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}');

      File(path.join(tempDir.path, 'web/worker.js'))
        ..createSync(recursive: true)
        ..writeAsStringSync('// compiled js');

      await cache.updateTarget(
        target,
        projectRoot: tempDir.path,
        dependencies: [srcFile.path],
      );

      await cache.save(tempDir.path);

      final loadedCache = await BuildCache.load(tempDir.path);
      expect(loadedCache.targets.length, equals(1));
      expect(
        await loadedCache.isTargetUpToDate(target, projectRoot: tempDir.path),
        isTrue,
      );
    });

    test('isTargetUpToDate detects modifications in source, deps, output, or flags', () async {
      final srcFile = File(path.join(tempDir.path, 'lib/worker.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}');

      final depFile = File(path.join(tempDir.path, 'lib/shared.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Shared {}');

      final outFile = File(path.join(tempDir.path, 'web/worker.js'))
        ..createSync(recursive: true)
        ..writeAsStringSync('// js output');

      final target = CompilationTarget(
        compiler: 'js',
        source: 'lib/worker.dart',
        output: 'web/worker.js',
        defines: {'debug': 'false'},
        optimizationLevel: '2',
      );

      final cache = BuildCache();
      await cache.updateTarget(
        target,
        projectRoot: tempDir.path,
        dependencies: [srcFile.path, depFile.path],
      );

      // 1. Unmodified target is up-to-date
      expect(await cache.isTargetUpToDate(target, projectRoot: tempDir.path), isTrue);

      // 2. Modifying dependency invalidates target
      depFile.writeAsStringSync('class SharedModified {}');
      expect(await cache.isTargetUpToDate(target, projectRoot: tempDir.path), isFalse);

      // Re-update cache
      await cache.updateTarget(
        target,
        projectRoot: tempDir.path,
        dependencies: [srcFile.path, depFile.path],
      );
      expect(await cache.isTargetUpToDate(target, projectRoot: tempDir.path), isTrue);

      // 3. Modifying output file invalidates target
      outFile.writeAsStringSync('// corrupted js output');
      expect(await cache.isTargetUpToDate(target, projectRoot: tempDir.path), isFalse);

      // Restore output file & re-update cache
      outFile.writeAsStringSync('// js output');
      await cache.updateTarget(
        target,
        projectRoot: tempDir.path,
        dependencies: [srcFile.path, depFile.path],
      );
      expect(await cache.isTargetUpToDate(target, projectRoot: tempDir.path), isTrue);

      // 4. Changing defines invalidates target
      final targetChangedDefines = CompilationTarget(
        compiler: 'js',
        source: 'lib/worker.dart',
        output: 'web/worker.js',
        defines: {'debug': 'true'},
        optimizationLevel: '2',
      );
      expect(
        await cache.isTargetUpToDate(targetChangedDefines, projectRoot: tempDir.path),
        isFalse,
      );
    });

    test('BuildCache internal file hash cache reuses cached hashes for shared dependencies', () async {
      final sharedDep = File(path.join(tempDir.path, 'lib/common.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Common {}');

      final target1 = CompilationTarget(
        compiler: 'js',
        source: 'lib/worker1.dart',
        output: 'web/worker1.js',
        defines: {},
        optimizationLevel: '2',
      );

      final target2 = CompilationTarget(
        compiler: 'js',
        source: 'lib/worker2.dart',
        output: 'web/worker2.js',
        defines: {},
        optimizationLevel: '2',
      );

      final cache = BuildCache();
      await cache.updateTarget(
        target1,
        projectRoot: tempDir.path,
        dependencies: [sharedDep.path],
      );

      expect(cache.cachedFileCount, equals(1));

      await cache.updateTarget(
        target2,
        projectRoot: tempDir.path,
        dependencies: [sharedDep.path],
      );

      expect(cache.cachedFileCount, equals(1));
    });
  });
}
