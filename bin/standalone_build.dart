import 'dart:io';

import '../lib/src/squadron_build_hook.dart';

void main(List<String> args) async {
  final initialDir = Directory.current;
  final targetDir = Directory(args.singleOrNull ?? '.');
  if (!targetDir.existsSync()) {
    print('Directory "${targetDir.path}" not found.');
    exit(-1);
  }
  try {
    Directory.current = targetDir;
    await runStandalone();
  } finally {
    Directory.current = initialDir;
  }
}
