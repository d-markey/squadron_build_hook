@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../lib/src/dart_file_analysis.dart';

void main() {
  group('DartFileAnalysis', () {
    test('extracts standard and conditional imports', () async {
      final code = '''
import 'dart:io';
import 'package:squadron/squadron.dart' as sq;
import 'impl_vm.dart' if (dart.library.js_interop) 'impl_web.dart' if (dart.library.html) 'impl_legacy.dart';
export 'exports/public_api.dart';
part 'worker.g.dart';
part of 'library.dart';

void main() {
  print('hello');
}
''';

      final file = File('test_sample_analysis.dart');
      file.writeAsStringSync(code);
      try {
        final analysis = await DartFileAnalysis.analyze(file);
        expect(
            analysis.imports,
            equals([
              'dart:io',
              'package:squadron/squadron.dart',
              'impl_vm.dart',
              'impl_web.dart',
              'impl_legacy.dart',
            ]));
        expect(analysis.exports, equals(['exports/public_api.dart']));
        expect(analysis.parts, equals(['worker.g.dart']));
        expect(analysis.hasMain, isTrue);
      } finally {
        if (file.existsSync()) file.deleteSync();
      }
    });

    test('detects main variants: void, Future, async, arrow functions',
        () async {
      final cases = <String, bool>{
        'void main() {}': true,
        'Future<void> main(List<String> args) async {}': true,
        'void main() => runApp();': true,
        'Future main() async => 42;': true,
        'int main(List<String> args) { return 0; }': true,
        '// void main() {}': false,
        '/* void main() {} */': false,
        'final main = () => print("not a function");': false,
        'class Foo { void main() {} }': false,
      };

      for (final entry in cases.entries) {
        final file = File('test_sample_main.dart');
        file.writeAsStringSync(entry.key);
        try {
          final analysis = await DartFileAnalysis.analyze(file);
          expect(
            analysis.hasMain,
            equals(entry.value),
            reason: 'Failed for case: ${entry.key}',
          );
        } finally {
          if (file.existsSync()) file.deleteSync();
        }
      }
    });

    test(
        'correctly skips strings and comments containing semicolons and quotes',
        () async {
      final code = '''
import 'package:foo/foo.dart?query=1;query=2'; // comment with ; and 'quote'
/* multi-line comment
   import 'bad.dart';
   void main() {}
*/

void notMain() {
  final s = "string with ; and void main() {} inside";
  final raw = r'raw string with ;';
}

void main() {
}
''';
      final file = File('test_sample_escape.dart');
      file.writeAsStringSync(code);
      try {
        final analysis = await DartFileAnalysis.analyze(file);
        expect(
            analysis.imports, equals(['package:foo/foo.dart?query=1;query=2']));
        expect(analysis.hasMain, isTrue);
      } finally {
        if (file.existsSync()) file.deleteSync();
      }
    });

    test('DartFileAnalyzer caches analysis results across calls', () async {
      final code = 'void main() {}';
      final file = File('test_sample_cache.dart')..writeAsStringSync(code);
      try {
        final analyzer = DartFileAnalyzer();
        final analysis1 = await analyzer.analyze(file);
        final analysis2 = await analyzer.analyze(file);
        expect(identical(analysis1, analysis2), isTrue);
      } finally {
        if (file.existsSync()) file.deleteSync();
      }
    });
  });
}
