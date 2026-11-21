## 0.1.0

- Initial release of `squadron_build_hook`.
- Automated Dart build hook integration (`package:hooks` and `package:code_assets`) to compile Squadron Workers during the build process.
- Multi-target compilation support for JavaScript (`js`), WebAssembly (`wasm`), and native standalone executables (`exe`).
- Declarative configuration via `squadron.manifest.yaml` (or `squadron.manifest`).
- Reusable named `outputs` groups and named shared `defines` presets.
- Flexible compiler define injection (with automatic `squadron.` prefixing) and configurable `optimization-level` (accepting numbers or strings).
- Smart diagnostic-driven heuristics to discover worker companion entry points by naming convention and endpoint usage analysis.
- Dependency tracking and incremental rebuild cache invalidation via `.d` and `.deps` depfile parsing.
- Semaphore-regulated concurrent worker compilation.
- Standalone CLI execution (`dart run squadron_build_hook:standalone_build`).
