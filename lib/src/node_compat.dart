/// Opt-in Node/Web compatibility layer for the runtime.
///
/// Two tiers, per issue #3:
///
/// **Tier 1 — real implementations:** `global` (globalThis alias),
/// `console.*` (pluggable sink), `path` (posix subset),
/// `assert` (node-like subset), `process` (env/platform/arch/version/
/// exitCode/cwd/exit), `TextEncoder`/`TextDecoder` (utf-8),
/// `atob`/`btoa`, `performance.now()`, `crypto.randomUUID()` /
/// `crypto.getRandomValues()`, `structuredClone` (JSON fidelity), and a
/// `require()` builtin-module registry the embedding can extend
/// ([installNodeCompatModule] — e.g. dmtools can map `fs` onto its file
/// tools).
///
/// **Tier 2 — known-unsupported, self-documenting stubs:** touching
/// `Buffer`, `fetch`, `AbortController`, `setTimeout`, `setInterval`,
/// `setImmediate`, or `process.nextTick` throws a message naming the
/// alternative — an intentional error beats a bare `ReferenceError` for
/// script authors (human or AI).
///
/// Everything is opt-in: an unmodified `QuickjsRuntime` keeps its
/// clean-room ES2020 surface until [installNodeCompat] runs.
///
/// Host hooks (all optional, JSON conventions like `registerHostFunction`):
/// env snapshot, cwd, clock, secure random, utf-8/base64 codecs, and the
/// console sink. Without a hook the JS side falls back to a pure-JS or
/// default behavior where one exists.
///
/// `require` handling: if the engine already defines `require` (a
/// consumer's CommonJS loader — dmtools does), the compat layer captures
/// it as the fallback and re-exposes a wrapped `require` that resolves
/// builtin compat modules first. With no existing `require`, the wrapped
/// one is simply installed.
library;

import 'dart:convert';

import 'quickjs_runtime.dart';

/// Consumer hooks and values for [installNodeCompat].
class NodeCompatConfig {
  /// Creates a config. Every field is optional; defaults keep the layer
  /// self-contained (empty env, `/` cwd, wall clock, non-secure random,
  /// stdout console).
  const NodeCompatConfig({
    this.env = const {},
    this.platform = 'linux',
    this.arch = 'x64',
    this.nodeVersion = 'v22.0.0-compat',
    this.cwd,
    this.clock,
    this.randomBytes,
    this.randomUuid,
    this.utf8Encode,
    this.utf8Decode,
    this.base64Encode,
    this.base64Decode,
    this.consoleSink,
    this.exitHook,
  });

  /// `process.env` snapshot.
  final Map<String, String> env;

  /// `process.platform`.
  final String platform;

  /// `process.arch`.
  final String arch;

  /// `process.version`.
  final String nodeVersion;

  /// `process.cwd()`; defaults to a constant `/`.
  final String? Function()? cwd;

  /// `performance.now()` in fractional ms; defaults to wall clock.
  final double Function()? clock;

  /// `crypto.getRandomValues(array)` filler; defaults to a plain PRNG.
  final List<int> Function(int count)? randomBytes;

  /// `crypto.randomUUID()`; defaults to a pseudo-random v4 shape.
  final String? Function()? randomUuid;

  /// UTF-8 encode: string → bytes; defaults to latin-1 approximation.
  final List<int> Function(String text)? utf8Encode;

  /// UTF-8 decode: bytes → string; defaults to latin-1 approximation.
  final String Function(List<int> bytes)? utf8Decode;

  /// `btoa`; defaults to an in-Dart base64 of latin-1 bytes.
  final String Function(String text)? base64Encode;

  /// `atob`; defaults to an in-Dart base64 decode to latin-1.
  final String Function(String text)? base64Decode;

  /// `console` sink: `(level, message)`; defaults to `print`.
  final void Function(String level, String message)? consoleSink;

  /// `process.exit(code)` notification (the JS side still throws a
  /// `ProcessExit` error so sync scripts stop).
  final void Function(int code)? exitHook;
}

/// Installs the compat layer onto [runtime]. Idempotent per runtime
/// (reinstalling replaces the previous surface).
void installNodeCompat(QuickjsRuntime runtime, [NodeCompatConfig? config]) {
  final cfg = config ?? const NodeCompatConfig();
  runtime.setGlobal('__ncConfig', {
    'env': cfg.env,
    'platform': cfg.platform,
    'arch': cfg.arch,
    'nodeVersion': cfg.nodeVersion,
  });
  runtime.registerHostFunction(
      '__ncCwd', (_) => jsonEncode(cfg.cwd?.call() ?? '/'));
  runtime.registerHostFunction('__ncNow', (_) {
    final ms =
        cfg.clock?.call() ?? DateTime.now().millisecondsSinceEpoch.toDouble();
    return jsonEncode(ms);
  });
  runtime.registerHostFunction('__ncConsoleWrite', (argsJson) {
    try {
      final args = jsonDecode(argsJson) as List;
      cfg.consoleSink?.call('${args[0]}', '${args[1]}');
    } catch (_) {
      // console must never break the script — swallow sink errors.
    }
    return null;
  });
  runtime.registerHostFunction('__ncRandomValues', (argsJson) {
    final count = jsonDecode(argsJson) as int;
    final bytes = cfg.randomBytes?.call(count) ?? _pseudoRandom(count);
    return jsonEncode(bytes.map((b) => b & 0xff).toList());
  });
  runtime.registerHostFunction('__ncRandomUuid', (_) {
    return jsonEncode(cfg.randomUuid?.call() ?? _pseudoUuid());
  });
  runtime.registerHostFunction('__ncUtf8Encode', (argsJson) {
    final text = jsonDecode(argsJson) as String;
    final bytes = cfg.utf8Encode?.call(text) ?? _latin1Bytes(text);
    return jsonEncode(bytes.map((b) => b & 0xff).toList());
  });
  runtime.registerHostFunction('__ncUtf8Decode', (argsJson) {
    final bytes = (jsonDecode(argsJson) as List).cast<int>();
    return jsonEncode(cfg.utf8Decode?.call(bytes) ?? _latin1String(bytes));
  });
  runtime.registerHostFunction('__ncBase64Encode', (argsJson) {
    final text = jsonDecode(argsJson) as String;
    return jsonEncode(cfg.base64Encode?.call(text) ?? _b64Encode(text));
  });
  runtime.registerHostFunction('__ncBase64Decode', (argsJson) {
    final text = jsonDecode(argsJson) as String;
    return jsonEncode(cfg.base64Decode?.call(text) ?? _b64Decode(text));
  });
  runtime.registerHostFunction('__ncExit', (argsJson) {
    cfg.exitHook?.call(jsonDecode(argsJson) as int);
    return null;
  });
  runtime.eval(nodeCompatPrelude, filename: '<node_compat>');
}

/// Registers (or replaces) one consumer-provided builtin module visible
/// to the compat `require` (e.g. `'fs'` mapped onto file tools).
///
/// The factory receives the module name (plain Dart string) and returns
/// the JSON module exports; `null` means "no module".
void installNodeCompatModule(
  QuickjsRuntime runtime,
  String name,
  String? Function(String name) factory,
) {
  final safe = _safeName(name);
  runtime.registerHostFunction('__ncModule_$safe', (nameJson) {
    return factory(jsonDecode(nameJson) as String);
  });
  runtime.eval(
    'globalThis.__ncRegistry[${jsonEncode(name)}] = function (moduleName) { '
    'return __ncModule_$safe(moduleName); };',
    filename: '<node_compat_module>',
  );
}

String _safeName(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');

// ── Default (non-secure / approximating) fallbacks ──

int _pseudoState = 0x2545F491;

List<int> _pseudoRandom(int count) => List<int>.generate(
      count,
      (_) =>
          (_pseudoState = (_pseudoState * 1103515245 + 12345) & 0x7FFFFFFF) &
          0xFF,
      growable: false,
    );

String _pseudoUuid() {
  final bytes = _pseudoRandom(16);
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final s = bytes.map(hex).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
      '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

List<int> _latin1Bytes(String text) =>
    text.codeUnits.map((c) => c & 0xff).toList(growable: false);

String _latin1String(List<int> bytes) =>
    String.fromCharCodes(bytes.map((b) => b & 0xff));

// Minimal base64 (RFC 4648) for the no-hook default path.
const String _b64alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

String _b64Encode(String text) {
  final bytes = _latin1Bytes(text);
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : null;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : null;
    out.write(_b64alphabet[b0 >> 2]);
    out.write(_b64alphabet[((b0 & 0x03) << 4) | ((b1 ?? 0) >> 4)]);
    out.write(
      b1 == null ? '=' : _b64alphabet[((b1 & 0x0F) << 2) | ((b2 ?? 0) >> 6)],
    );
    out.write(b2 == null ? '=' : _b64alphabet[b2 & 0x3F]);
  }
  return out.toString();
}

String _b64Decode(String text) {
  final clean = text.replaceAll('=', '').replaceAll(RegExp(r'\s'), '');
  final out = <int>[];
  for (var i = 0; i < clean.length; i += 4) {
    final n = [0, 1, 2, 3]
        .map((k) =>
            i + k < clean.length ? _b64alphabet.indexOf(clean[i + k]) : 0)
        .toList();
    out.add((n[0] << 2) | (n[1] >> 4));
    if (i + 2 < clean.length) out.add(((n[1] & 0x0F) << 4) | (n[2] >> 2));
    if (i + 3 < clean.length) out.add(((n[2] & 0x03) << 6) | n[3]);
  }
  return _latin1String(out);
}

/// The compat surface, as one JS bootstrap evaluated by
/// [installNodeCompat].
///
/// Tier-2 stubs are **call-time** errors and `typeof`-safe: `typeof Buffer`
/// answers `'function'` (so feature-guard idioms keep working) while an
/// actual call throws the documented alternative.
const String nodeCompatPrelude = r'''
(function () {
    var cfg = globalThis.__ncConfig ||
        { env: {}, platform: 'linux', arch: 'x64', nodeVersion: 'v22.0.0-compat' };

    function safeStringify(v) {
        try { return JSON.stringify(v); } catch (e) { return String(v); }
    }
    function unsupported(name, alternative) {
        var fn = function () {
            throw new Error(name + ' is not available in quickjs_runtime: ' +
                alternative);
        };
        return fn;
    }

    // ── console ──
    var consoleObj = {};
    ['log', 'info', 'warn', 'error', 'debug', 'trace'].forEach(function (level) {
        consoleObj[level] = function () {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
                var a = arguments[i];
                parts.push(typeof a === 'string' ? a : safeStringify(a));
            }
            __ncConsoleWrite(level, parts.join(' '));
        };
    });
    globalThis.console = consoleObj;

    // ── global ──
    globalThis.global = globalThis;

    // ── process ──
    var envObj = {};
    Object.keys(cfg.env || {}).forEach(function (k) {
        envObj[k] = String(cfg.env[k]);
    });
    function cwdSafe() {
        try { return __ncCwd(); } catch (e) { return '/'; }
    }
    globalThis.process = {
        env: envObj,
        platform: cfg.platform,
        arch: cfg.arch,
        version: cfg.nodeVersion,
        exitCode: 0,
        argv: ['quickjs'],
        cwd: cwdSafe,
        exit: function (code) {
            try { __ncExit(code || 0); } catch (e) { /* host hook only */ }
            throw new Error('ProcessExit: ' + (code || 0));
        },
        nextTick: unsupported('process.nextTick',
            'no scheduling beyond promises — run the work directly')
    };

    // ── performance ──
    globalThis.performance = {
        timeOrigin: 0,
        now: function () { return __ncNow(); }
    };

    // ── base64 ──
    globalThis.btoa = function (text) {
        return __ncBase64Encode(String(text));
    };
    globalThis.atob = function (text) {
        return __ncBase64Decode(String(text));
    };

    // ── TextEncoder / TextDecoder (utf-8 via host hooks) ──
    function TextEncoder() {}
    TextEncoder.prototype.encoding = 'utf-8';
    TextEncoder.prototype.encode = function (text) {
        var bytes = __ncUtf8Encode(text === undefined ? '' : String(text));
        return Uint8Array.from(bytes);
    };
    TextEncoder.prototype.encodeInto = unsupported('TextEncoder.encodeInto',
        'use encode() instead');
    globalThis.TextEncoder = TextEncoder;

    function TextDecoder() {}
    TextDecoder.prototype.encoding = 'utf-8';
    TextDecoder.prototype.decode = function (bytes) {
        var arr = [];
        if (bytes) {
            for (var i = 0; i < bytes.length; i++) arr.push(bytes[i] & 0xff);
        }
        return __ncUtf8Decode(arr);
    };
    globalThis.TextDecoder = TextDecoder;

    // ── crypto (subset) ──
    globalThis.crypto = {
        getRandomValues: function (array) {
            var bytes = __ncRandomValues(array ? array.length : 0);
            for (var i = 0; i < array.length; i++) {
                array[i] = bytes[i % bytes.length];
            }
            return array;
        },
        randomUUID: function () { return __ncRandomUuid(); }
    };

    // ── structuredClone (JSON fidelity, documented) ──
    globalThis.structuredClone = function (value) {
        return JSON.parse(JSON.stringify(value));
    };

    // ── path (posix subset) ──
    function isAbsolute(p) {
        return typeof p === 'string' && p.charAt(0) === '/';
    }
    function normalize(p) {
        var abs = isAbsolute(p);
        var parts = String(p).split('/');
        var out = [];
        for (var i = 0; i < parts.length; i++) {
            var part = parts[i];
            if (part === '' || part === '.') continue;
            if (part === '..') {
                if (out.length && out[out.length - 1] !== '..') out.pop();
                else if (!abs) out.push('..');
                continue;
            }
            out.push(part);
        }
        var joined = out.join('/');
        return (abs ? '/' : '') + (joined || (abs ? '' : '.'));
    }
    function join() {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) {
            if (typeof arguments[i] === 'string' && arguments[i] !== '') {
                parts.push(arguments[i]);
            }
        }
        return normalize(parts.join('/'));
    }
    function resolve() {
        var parts = [];
        for (var i = arguments.length - 1; i >= 0; i--) {
            var a = arguments[i];
            if (typeof a === 'string' && a !== '') {
                parts.unshift(a);
                if (isAbsolute(a)) break;
            }
        }
        if (!parts.length || !isAbsolute(parts[0])) parts.unshift(cwdSafe());
        return normalize(parts.join('/'));
    }
    function basename(p, ext) {
        var b = String(p).split('/').pop() || '';
        if (ext && b.slice(-ext.length) === ext && b !== ext) {
            b = b.slice(0, b.length - ext.length);
        }
        return b;
    }
    function dirname(p) {
        var s = String(p);
        var idx = s.lastIndexOf('/');
        if (idx < 0) return '.';
        if (idx === 0) return '/';
        return s.slice(0, idx) || '/';
    }
    function extname(p) {
        var b = basename(p);
        var idx = b.lastIndexOf('.');
        return idx <= 0 ? '' : b.slice(idx);
    }
    function relative(from, to) {
        from = resolve(from);
        to = resolve(to);
        if (from === to) return '';
        var f = from.split('/').filter(Boolean);
        var t = to.split('/').filter(Boolean);
        var i = 0;
        while (i < f.length && i < t.length && f[i] === t[i]) i++;
        var out = [];
        for (var u = 0; u < f.length - i; u++) out.push('..');
        for (var d = i; d < t.length; d++) out.push(t[d]);
        return out.join('/') || '.';
    }
    var path = {
        sep: '/',
        delimiter: ':',
        posix: null,
        win32: unsupported('path.win32', 'posix only in this runtime'),
        isAbsolute: isAbsolute,
        normalize: normalize,
        join: join,
        resolve: resolve,
        basename: basename,
        dirname: dirname,
        extname: extname,
        relative: relative
    };
    path.posix = path;
    globalThis.path = path;

    // ── assert (node-like subset) ──
    function fail(message) {
        var err = new Error(message);
        err.name = 'AssertionError';
        return err;
    }
    function assert(value, message) {
        if (!value) {
            throw fail(message ||
                'The expression evaluated to a falsy value.');
        }
    }
    assert.ok = assert;
    assert.equal = function (a, b, m) {
        if (a != b) {
            throw fail(m || 'Expected ' + safeStringify(a) +
                ' == ' + safeStringify(b));
        }
    };
    assert.notEqual = function (a, b, m) {
        if (a == b) {
            throw fail(m || 'Expected ' + safeStringify(a) +
                ' != ' + safeStringify(b));
        }
    };
    assert.deepEqual = function (a, b, m) {
        if (safeStringify(a) !== safeStringify(b)) {
            throw fail(m || 'Expected ' + safeStringify(a) +
                ' to deeply equal ' + safeStringify(b));
        }
    };
    assert.notDeepEqual = function (a, b, m) {
        if (safeStringify(a) === safeStringify(b)) {
            throw fail(m || 'Expected different deep values');
        }
    };
    assert.throws = function (fn, expected, m) {
        try {
            fn();
        } catch (e) {
            if (expected instanceof RegExp) {
                if (!expected.test(e.message)) {
                    throw fail(m || 'Expected error message to match ' +
                        expected + ', got: ' + e.message);
                }
            }
            return e;
        }
        throw fail(m || 'Expected the function to throw');
    };
    assert.doesNotThrow = function (fn, m) {
        try {
            fn();
        } catch (e) {
            throw fail(m || 'Expected the function not to throw, got: ' +
                e.message);
        }
    };
    assert.match = function (str, re, m) {
        if (!re.test(String(str))) {
            throw fail(m || 'Expected ' + safeStringify(String(str)) +
                ' to match ' + String(re));
        }
    };
    assert.fail = function (m) { throw fail(m || 'assert.fail()'); };
    assert.strict = assert;
    globalThis.assert = assert;

    // ── util (subset) ──
    function format() {
        var args = Array.prototype.slice.call(arguments);
        var out = String(args.shift() || '').replace(/%[sdjf%]/g, function (spec) {
            if (spec === '%%') return '%';
            if (!args.length) return spec;
            var v = args.shift();
            if (spec === '%s') return String(v);
            if (spec === '%d') return String(parseInt(v, 10));
            return safeStringify(v);
        });
        if (args.length) {
            out += ' ' + args.map(function (v) { return safeStringify(v); }).join(' ');
        }
        return out;
    }
    globalThis.util = {
        inspect: function (v) { return safeStringify(v); },
        format: format,
        types: {
            isPromise: function (v) { return v instanceof Promise; }
        }
    };

    // ── require: builtin compat modules + consumer registry + fallback ──
    var registry = {};
    globalThis.__ncRegistry = registry;
    var builtins = {
        path: function () { return path; },
        assert: function () { return assert; },
        util: function () { return globalThis.util; }
    };
    var baseRequire = typeof require === 'function' ? require : null;
    function compatRequire(name) {
        if (Object.prototype.hasOwnProperty.call(registry, name)) {
            return registry[name](name);
        }
        if (Object.prototype.hasOwnProperty.call(builtins, name)) {
            return builtins[name](name);
        }
        if (baseRequire) return baseRequire(name);
        throw new Error("Cannot find module '" + name +
            "' (compat builtins: path, assert, util" +
            (Object.keys(registry).length
                ? '; consumer-registered: ' + Object.keys(registry).join(', ')
                : '') + ')');
    }
    globalThis.require = compatRequire;

    // ── Tier 2: call-time stubs (typeof-safe) ──
    globalThis.Buffer = unsupported('Buffer',
        'use TextEncoder / TextDecoder for bytes, atob / btoa for base64');
    globalThis.fetch = unsupported('fetch',
        'this runtime is sync-call-style — use the host-provided sync tools ' +
        'or runAsync(fn, args) for parallel engines');
    globalThis.AbortController = unsupported('AbortController',
        'no async operations in this runtime — nothing to abort');
    globalThis.setTimeout = unsupported('setTimeout',
        'no event loop in v1 — run the work directly, or use runAsync ' +
        'for parallel engines');
    globalThis.clearTimeout = function () {};
    globalThis.setInterval = unsupported('setInterval',
        'no event loop in v1 — run the work directly');
    globalThis.clearInterval = function () {};
    globalThis.setImmediate = unsupported('setImmediate',
        'no event loop in v1 — run the work directly');
})();
''';
