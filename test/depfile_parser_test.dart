@TestOn('vm')
library;

import 'package:test/test.dart';

import 'package:squadron_build_hook/src/backends/exe_backend.dart';
import 'package:squadron_build_hook/src/backends/js_backend.dart';
import 'package:squadron_build_hook/src/backends/wasm_backend.dart';

void main() {
  group('Backend Compiler depfile parsing', () {
    test('ExeCompilerBackend parses simple Makefile depfile', () {
      final content = '''
build/worker.js: /path/to/source.dart /path/to/dep1.dart \\
  /path/to/dep2.dart
''';
      final deps = const ExeCompilerBackend().parseDepfile(content, null);
      expect(
          deps,
          containsAll([
            '/path/to/source.dart',
            '/path/to/dep1.dart',
            '/path/to/dep2.dart',
          ]));
    });

    test('ExeCompilerBackend handles escaped spaces and file:// URIs', () {
      final content = r'''
out.exe: C:\My\ Project\worker.dart file:///C:/Dart/sdk/lib/core.dart
''';
      final deps = const ExeCompilerBackend().parseDepfile(content, null);
      expect(deps.length, equals(2));
      expect(deps[0], contains('My Project'));
    });

    test('ExeCompilerBackend handles CRLF, LF, and CR line continuations', () {
      final content =
          'target: /path/dep1.dart \\\r\n /path/dep2.dart \\\n /path/dep3.dart \\\r /path/dep4.dart';
      final deps = const ExeCompilerBackend().parseDepfile(content, null);
      expect(
        deps,
        equals([
          '/path/dep1.dart',
          '/path/dep2.dart',
          '/path/dep3.dart',
          '/path/dep4.dart',
        ]),
      );
    });

    test('WasmCompilerBackend parses wasm depfile with Windows drive letters without truncating', () {
      const content =
          r'C:\_Projects\github\squadron\test/workers/wasm/echo_worker.dart.wasm: C:\_Projects\github\squadron\test\workers\wasm\echo_worker.dart C:\_Projects\github\squadron\lib\src\worker\worker_response.dart';
      final deps = const WasmCompilerBackend().parseDepfile(content, null);
      expect(deps.length, equals(2));
      expect(
        deps[0],
        equals(r'C:\_Projects\github\squadron\test\workers\wasm\echo_worker.dart'),
      );
      expect(
        deps[1],
        equals(r'C:\_Projects\github\squadron\lib\src\worker\worker_response.dart'),
      );
    });

    test('JsCompilerBackend parses js depfile with line-delimited file:/// URIs', () {
      const content = '''
file:///C:/Flutter/src/flutter/bin/cache/dart-sdk/lib/_internal/dart2js_platform.dill
file:///C:/Flutter/src/flutter/bin/cache/dart-sdk/lib/libraries.json
file:///C:/Users/DMA/AppData/Local/Pub/Cache/hosted/pub.dev/cancelation_token-1.2.0/lib/cancelation_token.dart
file:///C:/Users/DMA/AppData/Local/Pub/Cache/hosted/pub.dev/cancelation_token-1.2.0/lib/src/cancelation_token.dart
file:///C:/Users/DMA/AppData/Local/Pub/Cache/hosted/pub.dev/cancelation_token-1.2.0/lib/src/exceptions/canceled_exception.dart
''';
      final deps = const JsCompilerBackend().parseDepfile(content, null);
      expect(deps.length, equals(5));
      expect(deps[2], contains('cancelation_token.dart'));
      expect(deps[4], contains('canceled_exception.dart'));
    });
  });
}
