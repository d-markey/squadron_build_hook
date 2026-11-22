import 'dart_compiler_backend.dart';

class WasmCompilerBackend extends DartCompilerBackend {
  const WasmCompilerBackend();

  @override
  String get name => 'wasm';
}
