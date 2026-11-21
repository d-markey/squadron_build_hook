import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

File? resolveFile(String relPath, [String fromDir = '']) {
  final f = File(
    fromDir.trim().isEmpty ? relPath : path.join(fromDir, relPath),
  );
  return f.existsSync() ? f : null;
}

typedef BuildLogger = ({
  void Function(String) log,
  Never Function(String) logAndThrow
});

// ANSI escape codes
const _reset = '\x1B[0m';
const _yellow = '\x1B[33m';
const _dim = '\x1B[2m';

BuildLogger getLogger({String tag = '', void Function(String)? log}) {
  final trace = log ?? print;
  final useColor = identical(trace, print);

  final rawTag = tag.isEmpty ? '[HOOK]' : '[$tag]';
  tag = useColor ? '$_yellow$rawTag$_reset' : tag;

  final sw = Stopwatch()..start();
  final elapsed = useColor
      ? (() => '$_dim[${sw.elapsed}]$_reset')
      : (() => '[${sw.elapsed}]');

  return (
    log: (String message) {
      trace('$tag ${elapsed()} $message');
    },
    logAndThrow: (String message) {
      trace('$tag ${elapsed()} $message');
      throw Exception('$rawTag $message');
    }
  );
}

extension ProcessExt on Process {
  Future<({int exitCode, List<String> outputLines})> get result async {
    final output = <String>[];

    void Function(String) $log(String channel) => (String line) {
          final trimmed = line.trimRight();
          if (trimmed.isNotEmpty) {
            output.add('$channel $trimmed');
          }
        };

    final logStdOut = $log('[out]'), logStdErr = $log('[err]');

    final outDone = this
        .stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(logStdOut);

    final errDone = this
        .stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(logStdErr);

    int exitCode;
    try {
      exitCode = await this.exitCode;
      await Future.wait([outDone, errDone]);
    } catch (ex, st) {
      exitCode = 255;
      output.add('${ex.runtimeType}: $ex');
      output.add(st.toString());
    }

    return (exitCode: exitCode, outputLines: output);
  }
}
