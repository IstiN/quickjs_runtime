/// A high-level QuickJS JavaScript runtime with synchronous host callbacks.
///
/// Wraps the low-level [QuickjsFfi] bindings and manages the lifecycle of the
/// QuickJS runtime/context plus any registered [NativeCallable]s. Host
/// functions registered via [registerHostFunction] are invoked synchronously
/// from JS on the same isolate that owns this runtime.
///
/// This file is VM-only (dart:ffi); never import it from a web-reachable
/// path.
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'quickjs_ffi.dart';

/// A QuickJS JavaScript runtime with synchronous host callbacks.
class QuickjsRuntime {
  final QuickjsFfi _ffi;
  Pointer<Void> _runtime;
  Pointer<Void> _context;
  final _callables = <NativeCallable>[];

  /// Creates a new runtime with a fresh context and an empty host callback
  /// registry.
  QuickjsRuntime()
    : _ffi = QuickjsFfi(),
      _runtime = nullptr,
      _context = nullptr {
    _ffi.resetCallbacks();
    _runtime = _ffi.createRuntime();
    _context = _ffi.createContext(_runtime);
  }

  /// Evaluates JS [code] and returns the JSON result string.
  ///
  /// Returns `null` on error (and [errMsg] receives the exception text) or
  /// when the result is JS `undefined`.
  String? eval(
    String code, {
    String filename = '<eval>',
    List<String?>? errMsg,
  }) {
    return _ffi.eval(_context, code, filename, errMsg);
  }

  /// Registers a host function callable from JS.
  ///
  /// [callback] receives a JSON args string and returns a JSON result string
  /// (or `null` for JS `undefined`). It executes synchronously on the same
  /// isolate that owns this runtime. The underlying [NativeCallable] is kept
  /// alive for the lifetime of this runtime.
  void registerHostFunction(
    String name,
    String? Function(String argsJson) callback,
  ) {
    final callable =
        NativeCallable<Pointer<Utf8> Function(Pointer<Utf8>)>.isolateLocal((
          Pointer<Utf8> argsPtr,
        ) {
          try {
            final argsJson = argsPtr.toDartString();
            final result = callback(argsJson);
            if (result == null) return nullptr;
            return result.toNativeUtf8();
          } catch (_) {
            // Pointer-returning NativeCallables cannot declare an
            // exceptionalReturn; a stray exception would otherwise terminate
            // the isolate. Surface it to JS as `undefined`.
            return nullptr;
          }
        });
    _callables.add(callable); // keep alive so it isn't GC'd
    _ffi.registerHostFn(_context, name, callable.nativeFunction);
  }

  /// Sets a global variable named [name] from a Dart value (JSON-encoded).
  void setGlobal(String name, Object? value) {
    _ffi.setGlobalJson(_context, name, jsonEncode(value));
  }

  /// Drains pending jobs (promise reactions) queued on this context.
  ///
  /// Mirrors `executePendingJob()` in the flutter_js backend: call it after
  /// every eval that may settle promises so `.then` continuations run.
  int executePendingJobs() => _ffi.executePendingJobs(_context);

  /// Releases all resources: the registered callbacks, then the QuickJS
  /// context and runtime. Safe to call once; a no-op thereafter.
  void close() {
    for (final c in _callables) {
      c.close();
    }
    _callables.clear();
    if (_context.address != 0 || _runtime.address != 0) {
      _ffi.destroy(_runtime, _context);
      _context = nullptr;
      _runtime = nullptr;
    }
  }
}
