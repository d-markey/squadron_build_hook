import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

class CompilationTarget {
  CompilationTarget({
    required this.compiler,
    required this.source,
    required this.output,
    this.defines = const {},
    this.optimizationLevel = '',
  });

  CompilationTarget.exe(
    String source, [
    String? outputDir,
    Map<String, String>? defines,
    String? optimizationLevel,
  ]) : this(
          compiler: 'exe',
          source: source,
          output: path
              .join(outputDir ?? 'bin/workers', '${path.basename(source)}.exe')
              .replaceAll('\\', '/'),
          defines: defines ?? const {},
          optimizationLevel: optimizationLevel ?? '',
        );

  CompilationTarget.js(
    String source, [
    String? outputDir,
    Map<String, String>? defines,
    String? optimizationLevel,
  ]) : this(
          compiler: 'js',
          source: source,
          output: path
              .join(outputDir ?? 'web/workers', '${path.basename(source)}.js')
              .replaceAll('\\', '/'),
          defines: defines ?? const {},
          optimizationLevel: optimizationLevel ?? '',
        );

  CompilationTarget.wasm(
    String source, [
    String? outputDir,
    Map<String, String>? defines,
    String? optimizationLevel,
  ]) : this(
          compiler: 'wasm',
          source: source,
          output: path
              .join(outputDir ?? 'web/workers', '${path.basename(source)}.wasm')
              .replaceAll('\\', '/'),
          defines: defines ?? const {},
          optimizationLevel: optimizationLevel ?? '',
        );

  final String compiler;
  final String source;
  final String output;
  final Map<String, String> defines;
  final String optimizationLevel;

  static CompilationTarget fromMap(
    Map map,
    Map<String, String> defaultDefines, [
    String? defaultOptLevel,
    Map<String, Map<String, String>>? manifestDefines,
  ]) {
    final mergedDefines = <String, String>{};
    SquadronManifest._loadDefines(
      map['defines'],
      mergedDefines,
      manifestDefines,
    );
    mergedDefines.addAll(defaultDefines);

    final optLevel =
        map['optimization-level']?.toString() ?? defaultOptLevel ?? '';

    return CompilationTarget(
      compiler: (map['compiler'] as String?) ?? '',
      source: (map['source'] as String?) ?? '',
      output: (map['output'] as String?) ?? '',
      defines: mergedDefines,
      optimizationLevel: optLevel,
    );
  }
}

class WorkerDefinition {
  WorkerDefinition({
    required this.source,
    required this.targets,
    this.outputs,
    this.defines = const {},
    this.optimizationLevel = '',
  });

  final String source;
  final List<CompilationTarget> targets;
  final String? outputs;
  final Map<String, String> defines;
  final String optimizationLevel;

  static WorkerDefinition fromMap(
    Map map, [
    Map<String, Map<String, String>>? manifestDefines,
  ]) {
    final defaultDefines = <String, String>{};
    SquadronManifest._loadDefines(
      map['defines'],
      defaultDefines,
      manifestDefines,
    );
    final defaultOptLevel = map['optimization-level']?.toString() ?? '';

    final targetsList = (map['targets'] as List?)
            ?.map((t) => CompilationTarget.fromMap(
                  t as Map,
                  defaultDefines,
                  defaultOptLevel,
                  manifestDefines,
                ))
            .toList() ??
        const [];

    return WorkerDefinition(
      source: (map['source'] as String?) ?? '',
      targets: targetsList,
      outputs: map['outputs'] as String?,
      defines: defaultDefines,
      optimizationLevel: defaultOptLevel,
    );
  }
}

class SquadronManifest {
  SquadronManifest({
    required this.manifestFile,
    required this.workers,
    this.outputs = const {},
    this.defines = const {},
  });

  final File manifestFile;
  final List<WorkerDefinition> workers;

  /// Named output folders per compiler:
  /// e.g. `{ 'tests': { 'js': 'test/workers/js', 'wasm': 'test/workers/wasm' } }`
  final Map<String, Map<String, String>> outputs;

  /// Named shared defines:
  /// e.g. `{ 'prod': { 'no_internal_logging': 'true' } }`
  final Map<String, Map<String, String>> defines;

  /// Finds the package root by searching upwards from [startDir] for a directory containing `pubspec.yaml`.
  static Future<String> findPackageRoot([String? startDir]) async {
    var dir = Directory(startDir ?? Directory.current.absolute.path).absolute;
    while (!await File(path.join(dir.path, 'pubspec.yaml')).exists()) {
      if (dir.parent.path == dir.path) {
        return Directory.current.absolute.path;
      }
      dir = dir.parent;
    }
    return dir.path;
  }

  static void _loadDefines(
    Object? rawDefinesOrMap,
    Map<String, String> mergedDefines, [
    Map<String, Map<String, String>>? manifestDefines,
  ]) {
    if (rawDefinesOrMap == null) return;

    Object? raw = rawDefinesOrMap;
    if (raw is Map && raw.containsKey('defines')) {
      raw = raw['defines'];
      if (raw == null) return;
    }

    if (raw is String) {
      final named = manifestDefines?[raw];
      if (named != null) {
        mergedDefines.addAll(named);
      }
      return;
    }

    if (raw is List) {
      for (final item in raw) {
        _loadDefines(item, mergedDefines, manifestDefines);
      }
      return;
    }

    if (raw is Map) {
      for (final entry in raw.entries) {
        final keyStr = entry.key.toString();
        if ((entry.value == null || entry.value.toString().isEmpty) &&
            manifestDefines != null &&
            manifestDefines.containsKey(keyStr)) {
          mergedDefines.addAll(manifestDefines[keyStr]!);
          continue;
        }

        var key = keyStr;
        if (key.startsWith('squadron.')) {
          // normalize keys (remove "squadron.")
          key = key.substring('squadron.'.length);
        }
        final val = entry.value;
        if (val == null || val.toString().isEmpty) {
          // Empty value (e.g. "no_internal_logging:") removes the symbol
          mergedDefines.remove(key);
        } else {
          mergedDefines[key] = val.toString();
        }
      }
    }
  }

  static Map<String, Map<String, String>> _parseTopLevelDefines(Object? raw) {
    final result = <String, Map<String, String>>{};
    if (raw == null) return result;

    void addGroup(String name, Object? val) {
      final map = result.putIfAbsent(name, () => <String, String>{});
      if (val is Map) {
        for (final entry in val.entries) {
          var key = entry.key.toString();
          if (key.startsWith('squadron.')) {
            key = key.substring('squadron.'.length);
          }
          final v = entry.value;
          if (v != null && v.toString().isNotEmpty) {
            map[key] = v.toString();
          }
        }
      } else if (val is List) {
        for (final item in val) {
          if (item is Map) {
            for (final entry in item.entries) {
              var key = entry.key.toString();
              if (key.startsWith('squadron.')) {
                key = key.substring('squadron.'.length);
              }
              final v = entry.value;
              if (v != null && v.toString().isNotEmpty) {
                map[key] = v.toString();
              }
            }
          }
        }
      }
    }

    if (raw is Map) {
      for (final entry in raw.entries) {
        addGroup(entry.key.toString(), entry.value);
      }
    } else if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          for (final entry in item.entries) {
            addGroup(entry.key.toString(), entry.value);
          }
        }
      }
    }

    return result;
  }

  static Future<File?> _asFile(Object target) async {
    if (target is File) return target;
    return (target is String && await FileSystemEntity.isFile(target))
        ? File(target)
        : null;
  }

  static Future<Directory?> _asAbsoluteDir(Object target) async {
    if (target is Directory) return target;
    return (target is String && await FileSystemEntity.isDirectory(target))
        ? Directory(target).absolute
        : null;
  }

  /// Locates and loads a manifest from [target] (folder path, file path, or File).
  /// Returns `null` if no manifest file exists or could be found.
  static Future<SquadronManifest?> load(Object target) async {
    var file = await _asFile(target);
    if (file == null) {
      final dir = await _asAbsoluteDir(target);
      if (dir == null) return null;

      final yamlFile = File(path.join(dir.path, 'squadron.manifest.yaml'));
      if (await yamlFile.exists()) {
        file = yamlFile;
      } else {
        final bareFile = File(path.join(dir.path, 'squadron.manifest'));
        if (await bareFile.exists()) {
          file = bareFile;
        }
      }
    }

    if (file == null) return null;

    final content = await file.readAsString();
    final doc = loadYaml(content);
    if (doc is! Map) return null;

    final definesMap = _parseTopLevelDefines(doc['defines']);

    final workersList = (doc['workers'] as List?)
            ?.cast<Map>()
            .map((m) => WorkerDefinition.fromMap(m, definesMap))
            .toList() ??
        [];

    final outputsMap = <String, Map<String, String>>{};
    final rawOutputs = doc['outputs'];
    if (rawOutputs is Map) {
      for (final entry in rawOutputs.entries) {
        final name = entry.key.toString();
        final compilerMap = <String, String>{};
        final val = entry.value;
        if (val is Map) {
          for (final cEntry in val.entries) {
            compilerMap[cEntry.key.toString()] =
                cEntry.value.toString().replaceAll('\\', '/');
          }
        } else if (val is List) {
          for (final item in val) {
            if (item is Map) {
              final c = item['compiler']?.toString();
              final out = item['output']?.toString();
              if (c != null && out != null) {
                compilerMap[c] = out.replaceAll('\\', '/');
              }
            }
          }
        }
        outputsMap[name] = compilerMap;
      }
    } else if (rawOutputs is List) {
      for (final item in rawOutputs) {
        if (item is Map) {
          for (final entry in item.entries) {
            final name = entry.key.toString();
            final compilerMap = <String, String>{};
            final val = entry.value;
            if (val is List) {
              for (final sub in val) {
                if (sub is Map) {
                  final c = sub['compiler']?.toString();
                  final out = sub['output']?.toString();
                  if (c != null && out != null) {
                    compilerMap[c] = out.replaceAll('\\', '/');
                  }
                }
              }
            } else if (val is Map) {
              for (final sub in val.entries) {
                compilerMap[sub.key.toString()] =
                    sub.value.toString().replaceAll('\\', '/');
              }
            }
            outputsMap[name] = compilerMap;
          }
        }
      }
    }

    return SquadronManifest(
      manifestFile: file,
      workers: workersList,
      outputs: outputsMap,
      defines: definesMap,
    );
  }
}
