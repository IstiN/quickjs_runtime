/// dart:ffi bindings to the QuickJS C bridge (`libquickjs_bridge.so`).
///
/// The bridge exposes a flat C ABI with JSON-based marshaling: JS arguments
/// are stringified to JSON in C, passed to a synchronous Dart callback, and
/// the JSON result string is parsed back into a JS value.
///
/// Build the native library with `tool/build_quickjs.sh`, which produces
/// `native/quickjs/libquickjs_bridge.so`.
///
/// This file is VM-only (dart:ffi); never import it from a web-reachable
/// path.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Native signature of a host callback: receives a JSON args string and
/// returns a malloc'd JSON result string (or `nullptr` for JS `undefined`).
/// The bridge frees the returned string with `free()`.
typedef _HostCallbackNative = Pointer<Utf8> Function(Pointer<Utf8> argsJson);

/// Resolves the absolute path to `libquickjs_bridge.so`.
///
/// Looks in (1) the `JSR_QUICKJS_LIB` env var, (2) this package's checkout
/// as recorded in the current `.dart_tool/package_config.json` (covers
/// `dart run`/`dart test`/`flutter test` in any app that depends on the
/// package), (3) relative to [Platform.script] and (4) the current working
/// directory (source checkouts that vendor the build output). Returns the
/// first existing candidate so the DynamicLibrary.open error carries a
/// recognizable path.
String _resolveLibraryPath() {
  final envOverride = Platform.environment['JSR_QUICKJS_LIB'];
  if (envOverride != null && envOverride.isNotEmpty) return envOverride;

  final candidates = <String>[
    ...?_packageCheckoutPaths(),
    Platform.script.resolve('native/quickjs/libquickjs_bridge.so').toFilePath(),
    '${Directory.current.path}/native/quickjs/libquickjs_bridge.so',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return candidates.first;
}

/// Paths to this package's own checkout(s) from `.dart_tool/package_config.json`,
/// or `null` when no config is readable (e.g. compiled binaries).
List<String>? _packageCheckoutPaths() {
  final config = File(
    '${Directory.current.path}/.dart_tool/package_config.json',
  );
  if (!config.existsSync()) return null;
  final roots = <String>[];
  try {
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    for (final pkg in packages.cast<Map>()) {
      if (pkg['name'] != 'quickjs_runtime') continue;
      final root = Uri.parse(pkg['rootUri'] as String);
      if (!root.isScheme('file')) continue;
      // Hosted checkouts have no trailing slash in rootUri; git checkouts
      // do. Normalize so the join always produces a valid path.
      var rootPath = Uri.decodeComponent(root.path);
      if (!rootPath.endsWith('/')) rootPath = '$rootPath/';
      roots.add('${rootPath}native/quickjs/libquickjs_bridge.so');
    }
  } catch (_) {
    return null;
  }
  return roots.isEmpty ? null : roots;
}

/// Low-level QuickJS FFI bindings.
///
/// Prefer [QuickjsRuntime] — this class is an implementation detail. Handles
/// are untyped ([Pointer<Void>]) because the C bridge treats `JSRuntime*` and
/// `JSContext*` as opaque pointers; the caller must pass the correct handle
/// to each function.
class QuickjsFfi {
  /// Path to the shared library, overridable for tests.
  static String libraryPath = _resolveLibraryPath();

  late final DynamicLibrary _lib;

  late final Pointer<Void> Function() _createRuntime;
  late final Pointer<Void> Function(Pointer<Void> runtime) _createContext;
  late final void Function(Pointer<Void> runtime, Pointer<Void> context)
      _destroy;
  late final void Function() _resetCallbacks;
  late final int Function(
    Pointer<Void> context,
    Pointer<Utf8> name,
    Pointer<NativeFunction<_HostCallbackNative>> callback,
  ) _registerHostFn;
  late final Pointer<Utf8> Function(
    Pointer<Void> context,
    Pointer<Utf8> code,
    Pointer<Utf8> filename,
    Pointer<Pointer<Utf8>> errMsg,
  ) _eval;
  late final int Function(
    Pointer<Void> context,
    Pointer<Utf8> name,
    Pointer<Utf8> json,
  ) _setGlobalJson;
  late final int Function(Pointer<Void> context) _executePendingJobs;
  late final int Function(Pointer<Void> context, int maxJobs)
      _executePendingJobsCapped;
  late final int Function(int ms) _sleepMs;

  /// Loads the shared library and resolves symbols.
  QuickjsFfi() {
    _lib = DynamicLibrary.open(libraryPath);

    _createRuntime = _lib
        .lookup<NativeFunction<Pointer<Void> Function()>>('qjs_create_runtime')
        .asFunction();

    _createContext = _lib
        .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
          'qjs_create_context',
        )
        .asFunction();

    _destroy = _lib
        .lookup<NativeFunction<Void Function(Pointer<Void>, Pointer<Void>)>>(
          'qjs_destroy',
        )
        .asFunction();

    _resetCallbacks = _lib
        .lookup<NativeFunction<Void Function()>>('qjs_reset_callbacks')
        .asFunction();

    _registerHostFn = _lib
        .lookup<
            NativeFunction<
                Int32 Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<NativeFunction<_HostCallbackNative>>,
                )>>('qjs_register_host_fn')
        .asFunction();

    _eval = _lib
        .lookup<
            NativeFunction<
                Pointer<Utf8> Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Pointer<Utf8>>,
                )>>('qjs_eval')
        .asFunction();

    _setGlobalJson = _lib
        .lookup<
            NativeFunction<
                Int32 Function(Pointer<Void>, Pointer<Utf8>,
                    Pointer<Utf8>)>>('qjs_set_global_json')
        .asFunction();

    // Added after the bridge was first extracted; older builds (e.g. the
    // library dmtools-dart vendored before consuming this package) do not
    // export it. Degrade to a no-op so those binaries keep working.
    if (_lib.providesSymbol('qjs_execute_pending_jobs')) {
      _executePendingJobs = _lib
          .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
            'qjs_execute_pending_jobs',
          )
          .asFunction();
    } else {
      _executePendingJobs = (_) => 0;
    }

    // Additive, newer-build symbols (see the doc comments on the public
    // wrappers). Degrade to equivalents that keep older .so binaries working:
    // uncapped pending-job drain and a no-op sleep.
    if (_lib.providesSymbol('qjs_execute_pending_jobs_capped')) {
      _executePendingJobsCapped = _lib
          .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
            'qjs_execute_pending_jobs_capped',
          )
          .asFunction();
    } else {
      _executePendingJobsCapped = (context, _) => _executePendingJobs(context);
    }
    if (_lib.providesSymbol('qjs_sleep_ms')) {
      _sleepMs = _lib
          .lookup<NativeFunction<Int32 Function(Int32)>>('qjs_sleep_ms')
          .asFunction();
    } else {
      _sleepMs = (_) => -1;
    }
  }

  /// Creates a QuickJS runtime handle.
  Pointer<Void> createRuntime() => _createRuntime();

  /// Creates a context from [runtime].
  Pointer<Void> createContext(Pointer<Void> runtime) => _createContext(runtime);

  /// Destroys [context] then [runtime].
  void destroy(Pointer<Void> runtime, Pointer<Void> context) =>
      _destroy(runtime, context);

  /// Resets the global host callback registry.
  void resetCallbacks() => _resetCallbacks();

  /// Registers [callback] as a global JS function named [name].
  ///
  /// The callback receives the JSON-encoded arguments and returns the
  /// JSON-encoded result (or `null` for JS `undefined`). It executes
  /// synchronously on the calling thread. [callback] is a raw function
  /// pointer; the caller owns its lifetime — keep the originating
  /// `NativeCallable` alive and `close()` it when done.
  int registerHostFn(
    Pointer<Void> context,
    String name,
    Pointer<NativeFunction<_HostCallbackNative>> callback,
  ) {
    final namePtr = name.toNativeUtf8();
    final rc = _registerHostFn(context, namePtr, callback);
    malloc.free(namePtr);
    return rc;
  }

  /// Evaluates [code]. Returns the JSON result string, or `null` on error or
  /// when the result is JS `undefined`. On error [errMsg] (if non-null)
  /// receives the JS exception message.
  String? eval(
    Pointer<Void> context,
    String code,
    String filename,
    List<String?>? errMsg,
  ) {
    final codePtr = code.toNativeUtf8();
    final filenamePtr = filename.toNativeUtf8();
    final errPtr = malloc<Pointer<Utf8>>();
    errPtr.value = nullptr;

    final resultPtr = _eval(context, codePtr, filenamePtr, errPtr);

    malloc.free(codePtr);
    malloc.free(filenamePtr);

    String? error;
    if (errPtr.value.address != 0) {
      error = errPtr.value.toDartString();
      malloc.free(errPtr.value);
    }
    malloc.free(errPtr);

    if (errMsg != null) {
      errMsg.clear();
      if (error != null) errMsg.add(error);
    }

    if (resultPtr.address == 0) return null;
    final result = resultPtr.toDartString();
    malloc.free(resultPtr);

    // The bridge returns the literal C string "undefined" when the JS result
    // is `undefined`: JS_JSONStringify of undefined yields JS_UNDEFINED, which
    // JS_ToCString renders as "undefined". Map that to Dart null so a host
    // function that returns null round-trips as undefined. A JS string with
    // the value "undefined" would instead be quoted ("\"undefined\""), so this
    // discriminator is unambiguous.
    if (result == 'undefined') return null;
    return result;
  }

  /// Sets a global variable named [name] from [json].
  int setGlobalJson(Pointer<Void> context, String name, String json) {
    final namePtr = name.toNativeUtf8();
    final jsonPtr = json.toNativeUtf8();
    final rc = _setGlobalJson(context, namePtr, jsonPtr);
    malloc.free(namePtr);
    malloc.free(jsonPtr);
    return rc;
  }

  /// Drains pending jobs (promise reactions) queued on [context].
  ///
  /// Returns the number of executed jobs, or `-1` when a job threw. A no-op
  /// when the loaded library predates `qjs_execute_pending_jobs`.
  int executePendingJobs(Pointer<Void> context) => _executePendingJobs(context);

  /// Like [executePendingJobs], but stops after [maxJobs] executed jobs so a
  /// self-re-enqueueing microtask chain (`function f(){ Promise.resolve()
  /// .then(f); } f();`) cannot hang the host thread. Falls back to the
  /// uncapped drain when the loaded library predates the capped symbol.
  int executePendingJobsCapped(Pointer<Void> context, int maxJobs) =>
      _executePendingJobsCapped(context, maxJobs);

  /// Blocks the calling thread for [ms] milliseconds.
  ///
  /// Returns `false` when the loaded library predates `qjs_sleep_ms`
  /// (the timer pump then cannot wait and the caller must degrade to
  /// ready-only draining).
  bool sleepMs(int ms) => _sleepMs(ms) == 0;
}
