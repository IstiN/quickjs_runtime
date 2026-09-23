# 0.2.0

- `AsyncEnginePool`: pre-spawned engine-worker isolates for parallel
  JavaScript execution over the synchronous host-callback bridge.
  Consumer owns the worker body (top-level `AsyncWorkerMain` with an
  `AsyncWorkerLink` next/complete protocol, or a simpler
  `AsyncJobExecutor` one-engine-per-job hook); the pool owns transport
  and lifecycle — dispatch/wait mailbox protocol (pthreads condvar via
  `native_synchronization`), FIFO backpressure, fire-and-forget envelope
  caching, dead-worker error completion.
- `runAsync(fn, args)` scripting surface: `AsyncEnginePool.attachMainRuntime`
  registers the `__jsrDispatchHost`/`__jsrWaitHost` host functions and
  the prelude exposing `runAsync`/`AsyncJob`/`runAsync.all` with a
  **blocking** `wait()`.
- `runAsyncJobOnRuntime`: runs one dispatched (closure-free) function on
  a consumer-wired runtime and returns its `AsyncJobEnvelope`.

# 0.1.0

- Initial release: QuickJS 2024-01-13 runtime on `dart:ffi` with
  synchronous host callbacks (`NativeCallable`).
- `QuickjsRuntime`: eval (JSON results), `registerHostFunction`,
  `setGlobal`, `executePendingJobs`, `close`.
- `QuickjsFfi`: flat C ABI bindings to `quickjs_bridge.c`
  (JSON marshaling).
- `tool/build_quickjs.sh` builds `libquickjs_bridge.so` (gcc); lookup via
  `JSR_QUICKJS_LIB`, `.dart_tool/package_config.json`, script dir, or cwd.
