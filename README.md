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

VM-only (`dart:ffi`): never import from a web-reachable path.

## Testing

```sh
tool/build_quickjs.sh
dart test
```
