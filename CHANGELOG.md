# 0.3.0

- **Sync `fetch`** (opt-in): `NodeCompatConfig.httpFetch` hook + real
  `Headers`/`Response` (`text()`/`json()`/`arrayBuffer()`, `bodyUsed`,
  `ok`/`status`/`headers`); failures surface as
  `TypeError: fetch failed` with `cause`. Bodies are plain values, so
  `await res.text()` works through them; `AbortSignal` is not
  supported (documented deviation). Without the hook, `fetch` stays a
  self-documenting stub — the runtime remains I/O-clean.
- **Real timers + microtask auto-drain + events**: promise reactions,
  `queueMicrotask` and `process.nextTick` now actually run — the
  QuickJS pending-job queue is drained (capped) after every successful
  eval. `setTimeout`/`setInterval`/`setImmediate` + `clear*` are real,
  host-driven callbacks via `NodeCompatHandle.drainTimers()` in
  `ready` (default, UI-safe) / `block` (sleeps until the nearest
  reffed timer — CLI "setTimeout as sleep") / `none` modes, with
  `unref()`, a callback-count guard and a wall-clock budget.
  `require('events')` provides the full synchronous `EventEmitter`.
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
  - **Tier 2 — self-documenting stub:** `AbortController` —
    `typeof`-safe, throws the alternative on call (fetch has no signal
    support yet).
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
