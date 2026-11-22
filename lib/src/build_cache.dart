import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'manifest.dart';
import 'utils.dart';

/// 64-bit FNV-1a content hashing for files and byte sequences.
int computeBytesHash(List<int> bytes) {
  int hash = -3750763034362895579; // 14695981039346656037 in signed 64-bit int
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * 1099511628211);
  }
  return hash;
}

Future<int> computeFileHash(File file) async {
  if (!await file.exists()) return 0;
  try {
    return computeBytesHash(await file.readAsBytes());
  } catch (_) {
    return 0;
  }
}

class TargetCacheEntry {
  TargetCacheEntry({
    required this.compiler,
    required this.source,
    required this.output,
    required this.optimizationLevel,
    required this.defines,
    required this.outputHash,
    required this.dependencies,
  });

  factory TargetCacheEntry.fromJson(Map<String, dynamic> json) {
    final depsJson = json['dependencies'] as Map<String, dynamic>? ?? {};
    final depsMap = <String, int>{};
    for (final entry in depsJson.entries) {
      final val = entry.value;
      if (val is int) {
        depsMap[entry.key] = val;
      } else if (val != null) {
        depsMap[entry.key] = int.tryParse(val.toString()) ?? 0;
      }
    }

    final definesJson = json['defines'] as Map<String, dynamic>? ?? {};
    final definesMap = <String, String>{};
    for (final entry in definesJson.entries) {
      definesMap[entry.key] = entry.value?.toString() ?? '';
    }

    return TargetCacheEntry(
      compiler: json['compiler'] as String? ?? '',
      source: json['source'] as String? ?? '',
      output: json['output'] as String? ?? '',
      optimizationLevel: json['optimizationLevel'] as String? ?? '',
      defines: definesMap,
      outputHash: (json['outputHash'] is int)
          ? json['outputHash'] as int
          : int.tryParse(json['outputHash']?.toString() ?? '0') ?? 0,
      dependencies: depsMap,
    );
  }

  final String compiler;
  final String source;
  final String output;
  final String optimizationLevel;
  final Map<String, String> defines;
  final int outputHash;

  /// Map of dependency file path -> content hash
  final Map<String, int> dependencies;

  Map<String, dynamic> toJson() => {
        'compiler': compiler,
        'source': source,
        'output': output,
        'optimizationLevel': optimizationLevel,
        'defines': defines,
        'outputHash': outputHash,
        'dependencies': dependencies,
      };
}

class BuildCache {
  BuildCache({
    Map<String, TargetCacheEntry>? targets,
  }) : targets = targets ?? {};

  factory BuildCache.fromJson(Map<String, dynamic> json) {
    final rawTargets = json['targets'] as Map<String, dynamic>? ?? {};
    final targetsMap = <String, TargetCacheEntry>{};
    for (final entry in rawTargets.entries) {
      if (entry.value is Map<String, dynamic>) {
        targetsMap[entry.key] = TargetCacheEntry.fromJson(
          entry.value as Map<String, dynamic>,
        );
      } else if (entry.value is Map) {
        targetsMap[entry.key] = TargetCacheEntry.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        );
      }
    }
    return BuildCache(targets: targetsMap);
  }

  final Map<String, TargetCacheEntry> targets;

  static String cacheFilePath(String projectRoot) => path.normalize(
        path.join(projectRoot, '.dart_tool', 'squadron_build_hook',
            'build_cache.json'),
      );

  static Future<BuildCache> load(String projectRoot) async {
    final file = File(cacheFilePath(projectRoot));
    if (!await file.exists()) {
      return BuildCache();
    }
    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) return BuildCache();
      final doc = jsonDecode(content);
      if (doc is Map<String, dynamic>) {
        return BuildCache.fromJson(doc);
      } else if (doc is Map) {
        return BuildCache.fromJson(doc.cast<String, dynamic>());
      }
    } catch (_) {}
    return BuildCache();
  }

  Future<void> save(String projectRoot) async {
    final file = File(cacheFilePath(projectRoot));
    await file.parent.create(recursive: true);
    final encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(toJson()));
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'targets': targets.map((k, v) => MapEntry(k, v.toJson())),
      };

  static String normalizePath(String p, [String? projectRoot]) {
    final absPath = (projectRoot != null &&
            projectRoot.isNotEmpty &&
            !path.isAbsolute(p))
        ? path.join(projectRoot, p)
        : p;
    final canonical = path.canonicalize(absPath);
    return Platform.isWindows ? canonical.toLowerCase() : canonical;
  }

  Future<bool> isTargetUpToDate(
    CompilationTarget target, {
    required String projectRoot,
    BuildLogger? logger,
  }) async {
    final targetKey = normalizePath(target.output, projectRoot);
    final entry = targets[targetKey];
    if (entry == null) {
      logger?.log('Cache miss: no target entry for $targetKey');
      return false;
    }

    if (entry.compiler != target.compiler) {
      logger?.log(
          'Cache miss: compiler mismatch (${entry.compiler} vs ${target.compiler})');
      return false;
    }
    if (normalizePath(entry.source, projectRoot) !=
        normalizePath(target.source, projectRoot)) {
      logger?.log('Cache miss: source mismatch');
      return false;
    }
    if (entry.optimizationLevel != target.optimizationLevel) {
      logger?.log('Cache miss: opt level mismatch');
      return false;
    }
    if (!_mapsEqual(entry.defines, target.defines)) {
      logger?.log('Cache miss: defines mismatch');
      return false;
    }

    // Check output file
    final outFile = File(normalizePath(target.output, projectRoot));
    if (!await outFile.exists()) {
      logger?.log('Cache miss: output file does not exist: ${outFile.path}');
      return false;
    }
    if (await computeFileHash(outFile) != entry.outputHash) {
      logger?.log('Cache miss: output file hash mismatch');
      return false;
    }

    // Check dependencies
    if (entry.dependencies.isEmpty) {
      logger?.log('Cache miss: no dependencies recorded');
      return false;
    }
    for (final depEntry in entry.dependencies.entries) {
      final depFile = File(depEntry.key);
      if (!await depFile.exists()) {
        logger?.log(
            'Cache miss: dependency file does not exist: ${depEntry.key}');
        return false;
      }
      if (await computeFileHash(depFile) != depEntry.value) {
        logger?.log(
            'Cache miss: dependency file hash mismatch: ${depEntry.key}');
        return false;
      }
    }

    return true;
  }

  Future<void> updateTarget(
    CompilationTarget target, {
    required String projectRoot,
    required List<String> dependencies,
  }) async {
    final targetKey = normalizePath(target.output, projectRoot);
    final outFile = File(normalizePath(target.output, projectRoot));
    final outputHash =
        await outFile.exists() ? await computeFileHash(outFile) : 0;

    final depHashes = <String, int>{};
    for (final dep in dependencies) {
      final normPath = normalizePath(dep, projectRoot);
      final depFile = File(normPath);
      if (await depFile.exists()) {
        depHashes[normPath] = await computeFileHash(depFile);
      }
    }

    targets[targetKey] = TargetCacheEntry(
      compiler: target.compiler,
      source: target.source,
      output: target.output,
      optimizationLevel: target.optimizationLevel,
      defines: Map.from(target.defines),
      outputHash: outputHash,
      dependencies: depHashes,
    );
  }

  List<String> getTargetDependencies(
    CompilationTarget target, {
    required String projectRoot,
  }) {
    final targetKey = normalizePath(target.output, projectRoot);
    final entry = targets[targetKey];
    if (entry == null) return const [];
    return entry.dependencies.keys.toList();
  }

  bool _mapsEqual(Map<String, String> m1, Map<String, String> m2) {
    if (m1.length != m2.length) return false;
    for (final key in m1.keys) {
      if (!m2.containsKey(key) || m1[key] != m2[key]) return false;
    }
    return true;
  }
}
