@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../lib/src/manifest.dart';

void main() {
  group('SquadronManifest and Defines', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('manifest_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'loads manifest and parses workers, outputs, and defines with worker priority',
        () async {
      final manifestFile =
          File(path.join(tempDir.path, 'squadron.manifest.yaml'))
            ..writeAsStringSync('''
outputs:
  test_out:
    js: test/workers/js
    wasm: test/workers/wasm

workers:
  - source: lib/services/my_service.dart
    outputs: test_out
    defines:
      foo: worker_foo
      bar: worker_bar
    targets:
      - compiler: js
        defines:
          foo: target_foo
          baz: target_baz
      - compiler: wasm
''');

      final manifest = await SquadronManifest.load(manifestFile);
      expect(manifest, isNotNull);
      expect(manifest!.workers, hasLength(1));

      final worker = manifest.workers.first;
      expect(worker.source, equals('lib/services/my_service.dart'));
      expect(worker.outputs, equals('test_out'));
      expect(
          worker.defines,
          equals({
            'foo': 'worker_foo',
            'bar': 'worker_bar',
          }));

      expect(worker.targets, hasLength(2));

      // Target 0 (js): target defines 'foo' and 'baz', but worker defines take priority for 'foo'.
      final jsTarget = worker.targets[0];
      expect(jsTarget.compiler, equals('js'));
      expect(
          jsTarget.defines,
          equals({
            'foo':
                'worker_foo', // worker.defines takes priority over target definition
            'bar': 'worker_bar',
            'baz': 'target_baz',
          }));
    });

    test(
        'accepts optimization-level as both int and string, with inheritance and overrides',
        () async {
      final manifestFile =
          File(path.join(tempDir.path, 'squadron.manifest.yaml'))
            ..writeAsStringSync('''
workers:
  - source: lib/services/service_a.dart
    optimization-level: 3
    targets:
      - compiler: js
        optimization-level: 4
      - compiler: wasm
        optimization-level: "2"
      - compiler: exe
  - source: lib/services/service_b.dart
    targets:
      - compiler: js
        optimization-level: 1
      - compiler: wasm
''');

      final manifest = await SquadronManifest.load(manifestFile);
      expect(manifest, isNotNull);
      expect(manifest!.workers, hasLength(2));

      // Worker A
      final workerA = manifest.workers[0];
      expect(workerA.optimizationLevel, equals('3'));
      expect(workerA.targets, hasLength(3));
      // int 4 on target
      expect(workerA.targets[0].compiler, equals('js'));
      expect(workerA.targets[0].optimizationLevel, equals('4'));
      // string "2" on target
      expect(workerA.targets[1].compiler, equals('wasm'));
      expect(workerA.targets[1].optimizationLevel, equals('2'));
      // inherited int 3 from worker
      expect(workerA.targets[2].compiler, equals('exe'));
      expect(workerA.targets[2].optimizationLevel, equals('3'));

      // Worker B
      final workerB = manifest.workers[1];
      expect(workerB.optimizationLevel, equals('2'));
      expect(workerB.targets, hasLength(2));
      expect(workerB.targets[0].compiler, equals('js'));
      expect(workerB.targets[0].optimizationLevel, equals('1'));
      expect(workerB.targets[1].compiler, equals('wasm'));
      expect(workerB.targets[1].optimizationLevel, equals('2')); // default
    });

    test(
        'supports named optimization levels: none, default, safe, unsafe, aggressive',
        () async {
      final manifestFile =
          File(path.join(tempDir.path, 'squadron.manifest.yaml'))
            ..writeAsStringSync('''
workers:
  - source: lib/services/service_named.dart
    optimization-level: safe
    targets:
      - compiler: js
        optimization-level: aggressive
      - compiler: wasm
        optimization-level: unsafe
      - compiler: exe
        optimization-level: none
  - source: lib/services/service_default.dart
    targets:
      - compiler: js
        optimization-level: default
      - compiler: wasm
''');

      final manifest = await SquadronManifest.load(manifestFile);
      expect(manifest, isNotNull);

      final wNamed = manifest!.workers[0];
      expect(wNamed.optimizationLevel, equals('2')); // safe -> 2
      expect(
          wNamed.targets[0].optimizationLevel, equals('4')); // aggressive -> 4
      expect(wNamed.targets[1].optimizationLevel, equals('3')); // unsafe -> 3
      expect(wNamed.targets[2].optimizationLevel, equals('0')); // none -> 0

      final wDef = manifest.workers[1];
      expect(wDef.targets[0].optimizationLevel, equals('1')); // default -> 1
      expect(wDef.targets[1].optimizationLevel, equals('2')); // omitted
    });

    test('supports top-level defines presets and worker/target references',
        () async {
      final manifestFile =
          File(path.join(tempDir.path, 'squadron.manifest.yaml'))
            ..writeAsStringSync('''
defines:
  prod:
    no_internal_logging: true
    squadron.env: production
  dev:
    debug: true
    squadron.verbose: 1

workers:
  - source: lib/services/service_prod.dart
    defines: prod
    targets:
      - compiler: js
      - compiler: wasm
        defines:
          extra: wasm_extra
  - source: lib/services/service_list.dart
    defines:
      - dev
      - custom_key: custom_val
    targets:
      - compiler: exe
''');

      final manifest = await SquadronManifest.load(manifestFile);
      expect(manifest, isNotNull);
      expect(manifest!.defines, contains('prod'));
      expect(manifest.defines, contains('dev'));
      expect(
          manifest.defines['prod'],
          equals({
            'no_internal_logging': 'true',
            'env': 'production',
          }));
      expect(
          manifest.defines['dev'],
          equals({
            'debug': 'true',
            'verbose': '1',
          }));

      // Worker 0: references prod
      final wProd = manifest.workers[0];
      expect(
          wProd.defines,
          equals({
            'no_internal_logging': 'true',
            'env': 'production',
          }));
      // Target 0: inherits prod
      expect(
          wProd.targets[0].defines,
          equals({
            'no_internal_logging': 'true',
            'env': 'production',
          }));
      // Target 1: has extra + inherits prod
      expect(
          wProd.targets[1].defines,
          equals({
            'no_internal_logging': 'true',
            'env': 'production',
            'extra': 'wasm_extra',
          }));

      // Worker 1: list of dev + custom
      final wList = manifest.workers[1];
      expect(
          wList.defines,
          equals({
            'debug': 'true',
            'verbose': '1',
            'custom_key': 'custom_val',
          }));
      expect(
          wList.targets[0].defines,
          equals({
            'debug': 'true',
            'verbose': '1',
            'custom_key': 'custom_val',
          }));
    });

    test('supports verbatim defines starting with \$', () async {
      final manifestFile =
          File(path.join(tempDir.path, 'squadron.manifest.yaml'))
            ..writeAsStringSync('''
defines:
  shared:
    \$squadron.exact: true
    \$custom_flag: 42
    regular: value

workers:
  - source: lib/services/service.dart
    defines:
      - shared
      - \$worker_flag: worker_val
    targets:
      - compiler: js
        defines:
          \$target_flag: target_val
''');

      final manifest = await SquadronManifest.load(manifestFile);
      expect(manifest, isNotNull);
      final shared = manifest!.defines['shared']!;
      expect(shared['\$squadron.exact'], equals('true'));
      expect(shared['\$custom_flag'], equals('42'));
      expect(shared['regular'], equals('value'));

      final target = manifest.workers[0].targets[0];
      expect(target.defines['\$squadron.exact'], equals('true'));
      expect(target.defines['\$custom_flag'], equals('42'));
      expect(target.defines['regular'], equals('value'));
      expect(target.defines['\$worker_flag'], equals('worker_val'));
      expect(target.defines['\$target_flag'], equals('target_val'));
    });
  });
}
