import 'compiler_backend.dart';
import 'exe_backend.dart';
import 'js_backend.dart';
import 'wasm_backend.dart';

class CompilerRegistry {
  CompilerRegistry();

  final Map<String, CompilerBackend> _backends = {};

  void register(CompilerBackend backend) {
    _backends[backend.name] = backend;
  }

  CompilerBackend? get(String name) => _backends[name];

  CompilerBackend operator [](String name) =>
      _backends[name] ??
      (throw ArgumentError('No compiler backend registered for $name'));

  static CompilerRegistry get defaultRegistry {
    final registry = CompilerRegistry();
    registry.register(const ExeCompilerBackend());
    registry.register(const JsCompilerBackend());
    registry.register(const WasmCompilerBackend());
    return registry;
  }
}
