# quickjs_runtime

A pure-Dart QuickJS JavaScript runtime on `dart:ffi` with **synchronous
host callbacks**. No Flutter, no Flutter SDK — `dart pub get && dart test`
is all you need.

- Vendored QuickJS **2024-01-13** sources
- A C bridge (`native/quickjs_bridge.c`) with JSON-based marshaling: JS
  arguments are stringified to JSON in C, passed to a synchronous Dart
  callback (`NativeCallable`), and the JSON result is parsed back into a
  JS value
- One flat C ABI: `qjs_create_runtime`, `qjs_eval`, `qjs_register_host_fn`, …

## Build

```sh
tool/build_quickjs.sh   # produces native/quickjs/libquickjs_bridge.so (gcc)
```

The library is looked up via the `JSR_QUICKJS_LIB` env var, inside this
package's checkout, or in `<cwd>/native/quickjs/` — in that order.

## Usage

```dart
import 'package:quickjs_runtime/quickjs_runtime.dart';

final rt = QuickjsRuntime();
rt.registerHostFunction('add', (argsJson) {
  final args = jsonDecode(argsJson) as List;
  return jsonEncode(args[0] + args[1]);
});
print(rt.eval('add(2, 3)')); // 5
rt.executePendingJobs();     // drain promise reactions
rt.close();
```

## Parallel engines (`runAsync`)

`AsyncEnginePool` adds engine-level parallelism while keeping the
scripting surface synchronous: `runAsync(fn, args)` returns a `Job`
whose `wait()` blocks the calling engine (no promises, no event loop).

```dart
// Top-level (static) — it crosses the isolate spawn boundary.
Future<void> workerMain(AsyncWorkerLink link) async {
  final runtime = QuickjsRuntime();          // consumer wiring here
  try {
    while (true) {
      final request = await link.next();
      if (request == null) return;           // shutdown
      link.complete(runAsyncJobOnRuntime(runtime,
          jobId: request.jobId,
          fnSource: request.fnSource,
          argsJson: request.argsJson));
    }
  } finally {
    runtime.close();
  }
}

final pool = AsyncEnginePool(workers: 4, workerMain: workerMain);
await pool.boot();                           // from main(), event loop alive
pool.attachMainRuntime(rt);                  // adds runAsync/AsyncJob globals
```

```js
// in JS
var job = runAsync(function (x) { return expensive(x); }, [arg]);
var result = job.wait();
var all = runAsync.all([job1, job2, job3]).wait();
```

Boot the pool from `main()` **before** any JS evaluates —
`Isolate.spawn` cannot progress while the isolate is blocked inside an
FFI callback. No timeouts: a dispatched function that never returns
blocks its caller forever, like any infinite script loop.

VM-only (`dart:ffi`): never import from a web-reachable path.

## Node/js compat layer (opt-in)

The bare runtime is a clean-room ES2020 — no `console`, `process`,
`setTimeout`. `installNodeCompat` adds the idioms scripts habitually
reach for, and turns the unsupported ones into self-documenting errors
instead of bare `ReferenceError`s:

```dart
installNodeCompat(rt, NodeCompatConfig(
  env: platformEnv,          // process.env snapshot
  cwd: () => dir,            // process.cwd() / path.resolve base
  randomBytes: secureRandom, // crypto.getRandomValues
  consoleSink: (level, msg) => myLog(level, msg),
));
```

```js
global === globalThis;                 // true
path.join('a', 'b');                   // 'a/b'
process.env.HOME;                      // from the snapshot
require('assert').equal(2 + 2, 4);
new TextEncoder().encode('hi');        // Uint8Array
btoa('hello');                         // 'aGVsbG8='
structuredClone(v);                    // JSON fidelity
setTimeout(f, 10);                     // throws: no event loop — use
                                       // runAsync or run the work directly
typeof Buffer;                         // 'function' (guard-safe)
Buffer(1);                             // throws: use TextEncoder/atob
```

Builtin modules via `require`: `path`, `assert`, `util`. Consumers can
register more (`installNodeCompatModule(rt, 'fs', factory)`) and a
pre-existing `require` loader stays reachable as the fallback.


## Testing

```sh
tool/build_quickjs.sh
dart test
```
