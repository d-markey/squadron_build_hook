@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'package:squadron_build_hook/squadron_build_hook.dart';

class FakeCompilerBackend extends CompilerBackend {
  FakeCompilerBackend(this.name, {this.supportsDepfileArg = true});

  @override
  final String name;

  @override
  final bool supportsDepfileArg;

  int compileCallCount = 0;

  @override
  String defaultDepfile(String resolvedOutput) => '$resolvedOutput.d';

  @override
  List<String> parseDepfile(String content, String? projectRoot) {
    return content.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<CompilationResult> compile({
    required String projectRoot,
    required String source,
    required String output,
    String optimizationLevel = '',
    Map<String, String>? defines,
    String? depfile,
    required BuildLogger logger,
  }) async {
    compileCallCount++;
    final outFile = File(path.isAbsolute(output) ? output : path.join(projectRoot, output));
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync('fake compiled $name');

    if (depfile != null) {
      final depFileObj = File(path.isAbsolute(depfile) ? depfile : path.join(projectRoot, depfile));
      depFileObj.parent.createSync(recursive: true);
      depFileObj.writeAsStringSync('dep1.dart dep2.dart');
    }

    return CompilationResult(
      exitCode: 0,
      dependencies: [path.join(projectRoot, 'lib/dep1.dart')],
      outputLines: ['Fake compilation successful'],
      depfilePath: depfile,
    );
  }
}

void main() {
  group('Compiler Backends and Registry', () {
    test('CompilerRegistry holds and retrieves backends correctly', () {
      final registry = CompilerRegistry();
      final exe = const ExeCompilerBackend();
      registry.register(exe);

      expect(registry.get('exe'), equals(exe));
      expect(registry['exe'], equals(exe));
      expect(() => registry['unknown'], throwsArgumentError);
    });

    test('JsCompilerBackend parses .js.deps format correctly', () {
      final backend = const JsCompilerBackend();
      expect(backend.name, equals('js'));
      expect(backend.supportsDepfileArg, isFalse);
      expect(backend.defaultDepfile('out.js'), equals('out.js.deps'));

      const content = '''
file:///C:/path/to/file1.dart
file:///C:/path/to/file2.dart
''';
      final deps = backend.parseDepfile(content, null);
      expect(deps.length, equals(2));
      expect(deps[0], contains('file1.dart'));
    });

    test('ExeCompilerBackend and WasmCompilerBackend parse .d format correctly', () {
      final exe = const ExeCompilerBackend();
      final wasm = const WasmCompilerBackend();

      expect(exe.name, equals('exe'));
      expect(exe.supportsDepfileArg, isTrue);
      expect(exe.defaultDepfile('out.exe'), equals('out.exe.d'));

      expect(wasm.name, equals('wasm'));
      expect(wasm.supportsDepfileArg, isTrue);
      expect(wasm.defaultDepfile('out.wasm'), equals('out.wasm.d'));

      const content = 'target: /path/dep1.dart /path/dep2.dart';
      final depsExe = exe.parseDepfile(content, null);
      final depsWasm = wasm.parseDepfile(content, null);

      expect(depsExe, equals(['/path/dep1.dart', '/path/dep2.dart']));
      expect(depsWasm, equals(['/path/dep1.dart', '/path/dep2.dart']));
    });

    test('runStandalone accepts custom registry with fake backend compilers', () async {
      final tempDir = await Directory.systemTemp.createTemp('fake_registry_test_');
      try {
        File(path.join(tempDir.path, 'pubspec.yaml'))
            .writeAsStringSync('name: test_pkg\nenvironment:\n  sdk: ^3.4.0\n');

        final wSource = 'lib/services/service1.dart';
        final srcFile = File(path.join(tempDir.path, wSource));
        srcFile.parent.createSync(recursive: true);
        srcFile.writeAsStringSync('void main() {}');

        File(path.join(tempDir.path, 'squadron.manifest.yaml'))
            .writeAsStringSync('''
workers:
  - source: $wSource
    targets:
      - compiler: fake_exe
        source: lib/services/service1.dart
        output: bin/service1.fake
''');

        final fakeBackend = FakeCompilerBackend('fake_exe');
        final registry = CompilerRegistry()..register(fakeBackend);

        final initialDir = Directory.current;
        try {
          Directory.current = tempDir;
          final result = await runStandalone(
            registry: registry,
            logger: getLogger(tag: 'nul', log: (_) {}),
          );
          expect(result.success, isTrue);
          expect(fakeBackend.compileCallCount, equals(1));
        } finally {
          Directory.current = initialDir;
        }
      } finally {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
