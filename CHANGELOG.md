# 0.1.0

- Initial release: QuickJS 2024-01-13 runtime on `dart:ffi` with
  synchronous host callbacks (`NativeCallable`).
- `QuickjsRuntime`: eval (JSON results), `registerHostFunction`,
  `setGlobal`, `executePendingJobs`, `close`.
- `QuickjsFfi`: flat C ABI bindings to `quickjs_bridge.c`
  (JSON marshaling).
- `tool/build_quickjs.sh` builds `libquickjs_bridge.so` (gcc); lookup via
  `JSR_QUICKJS_LIB`, `.dart_tool/package_config.json`, script dir, or cwd.
