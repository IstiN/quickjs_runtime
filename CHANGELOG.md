# Unreleased

- **Real timers + `events` + microtask auto-drain.** Promise reactions
  now drain automatically after every eval (capped; Node/GraalJS
  parity — `.then`/`queueMicrotask`/`process.nextTick`/`util.promisify`
  work out of the box; previously reactions never ran). Timers are a
  real sync-drain scheduler driven by `NodeCompatHandle.drainTimers()`
  in three modes (`none`/`ready`/`block`) with injectable clock +
  blocking sleep (`qjs_sleep_ms`), unref'd-timer semantics, a
  per-pass callback cap and a wall-clock bound. `require('events')`
  ships a 1:1 synchronous `EventEmitter`. `util.callbackify` joins
  `promisify` as real. New additive C symbols
  (`qjs_execute_pending_jobs_capped`, `qjs_sleep_ms`) — older .so
  builds keep working via guarded lookups.
- **Sync `fetch`** behind `NodeCompatConfig.httpFetch` (embedding
  provides the transport): real `fetch`/`Headers`/`Response` —
  case-insensitive headers, one-shot body accessors, `TypeError:
  fetch failed` + `cause`, await-compatible plain-value bodies.
- **Node parity pack** (issue #3 follow-up): real `Buffer` (Uint8Array
  subclass, Node encodings + LE/BE accessors), `URL`/`URLSearchParams`
  (WHATWG subset verified against real Node), `console.time`/`table`/
  `group`/`count`/`dir`/`trace`, Node-style `util.inspect`, `os` +
  `url` + `buffer` builtin modules, `process.argv`/`pid`/`hrtime`/
  `uptime`/`memoryUsage`/`stdout`/`stderr`/`on('exit')`,
  `__filename`/`__dirname` (+ `NodeCompatHandle.setScriptPath`),
  typeof-safe `Intl` stubs. Default text codecs are now real UTF-8
  (dart:convert) — the latin-1 approximation is gone; `Buffer` removed
  from tier-2 stubs; `installNodeCompat` returns a
  `NodeCompatHandle`.

- Node/js compat layer (issue #3), opt-in via `installNodeCompat(rt, cfg)`:
  - **Tier 1 — real:** `global`, `console.*` (pluggable sink), `process`
    (env/platform/arch/version/exitCode/cwd/exit), `path` (posix subset),
    `assert` (node-like subset), `util` (subset), `TextEncoder`/
    `TextDecoder` (utf-8), `atob`/`btoa`, `performance.now()`,
    `crypto.randomUUID()`/`getRandomValues()`, `structuredClone`
    (JSON fidelity), `require()` builtin registry + consumer modules
    (`installNodeCompatModule`) + fallback to a pre-existing loader.
  - **Tier 2 — self-documenting stubs:** `Buffer`, `fetch`,
    `AbortController`, `setTimeout`/`setInterval`/`setImmediate`,
    `process.nextTick` — `typeof`-safe, throw the alternative on call.
  - Host hooks: env, cwd, clock, secure random, utf-8/base64 codecs,
    console sink, exit notification. Without hooks, safe defaults.

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
