## 0.2.0

- **Per-Worker Content Hash Caching**: Implemented a robust persistent per-worker and per-target build cache (`.dart_tool/squadron_build_hook/build_cache.json`) using fast 64-bit FNV-1a content hashing of source files and dependency trees. Unchanged worker targets are automatically skipped during builds, drastically improving incremental build speed.
- Refactored compiler architecture into modular backends located in `lib/src/backends`:
  - Pure `CompilerBackend` interface (`compiler_backend.dart`).
  - `DartCompilerBackend` abstract base class handling shared compilation process execution and Makefile/Ninja `.d` depfile parsing.
  - Concrete backend implementations for `exe`, `wasm`, and `js`.
- Introduced `CompilerRegistry` to manage and provide compiler backends.
- Added optional `CompilerRegistry` support to build and run methods (`runStandalone`, `runSquadronBuildHook`, `WorkerCompiler`), enabling easy testability with fake/mock compiler backends.

## 0.1.0

- Initial release of `squadron_build_hook`.
- Automated Dart build hook integration (`package:hooks` and `package:code_assets`) to compile Squadron Workers during the build process.
- Multi-target compilation support for JavaScript (`js`), WebAssembly (`wasm`), and native standalone executables (`exe`).
- Declarative configuration via `squadron.manifest.yaml` (or `squadron.manifest`).
- Reusable named `outputs` groups and named shared `defines` presets.
- Flexible compiler define injection (with automatic `squadron.` prefixing or verbatim defines prefixed with `$`) and configurable `optimization-level` (accepting numbers, strings, or named levels: `none`, `default`, `safe`, `unsafe`, `aggressive`).
- Smart diagnostic-driven heuristics to discover worker companion entry points by naming convention and endpoint usage analysis.
- Dependency tracking and incremental rebuild cache invalidation via `.d` and `.deps` depfile parsing.
- Semaphore-regulated concurrent worker compilation.
- Standalone CLI execution (`dart run squadron_build_hook:standalone_build`).
