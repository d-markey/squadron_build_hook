@TestOn('vm')
library;

import 'package:test/test.dart';

import '../lib/src/compiler.dart';

void main() {
  group('WorkerCompiler depfile parsing', () {
    test('parses simple Makefile depfile', () {
      final content = '''
build/worker.js: /path/to/source.dart /path/to/dep1.dart \\
  /path/to/dep2.dart
''';
      final deps = WorkerCompiler.parseDepfile(content);
      expect(
          deps,
          containsAll([
            '/path/to/source.dart',
            '/path/to/dep1.dart',
            '/path/to/dep2.dart',
          ]));
    });

    test('handles escaped spaces and file:// URIs', () {
      final content = r'''
out.exe: C:\My\ Project\worker.dart file:///C:/Dart/sdk/lib/core.dart
''';
      final deps = WorkerCompiler.parseDepfile(content);
      expect(deps.length, equals(2));
      expect(deps[0], contains('My Project'));
    });

    test('handles CRLF, LF, and CR line continuations', () {
      final content =
          'target: /path/dep1.dart \\\r\n /path/dep2.dart \\\n /path/dep3.dart \\\r /path/dep4.dart';
      final deps = WorkerCompiler.parseDepfile(content);
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
  });
}
