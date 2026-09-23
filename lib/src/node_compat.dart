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

import 'node_compat_buffer.dart';
import 'node_compat_url.dart';
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
    this.argv,
    this.scriptPath,
    this.pid,
    this.hostname,
    this.tmpdir,
    this.homedir,
    this.cpusCount,
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

  /// UTF-8 encode: string → bytes; defaults to real UTF-8 (dart:convert).
  final List<int> Function(String text)? utf8Encode;

  /// UTF-8 decode: bytes → string; defaults to real UTF-8 (dart:convert).
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

  /// `process.argv`; defaults to `['<runtime>', '<main>']` (or
  /// `['<runtime>', scriptPath]` when [scriptPath] is set).
  final List<String>? argv;

  /// Path of the evaluated script; exposes `__filename` / `__dirname`
  /// globals and feeds the `process.argv` default. Changeable later via
  /// [NodeCompatHandle.setScriptPath].
  final String? scriptPath;

  /// `process.pid`; defaults to `1`.
  final int Function()? pid;

  /// `os.hostname()`; defaults to `'localhost'`.
  final String Function()? hostname;

  /// `os.tmpdir()`; defaults to `/tmp` (or `%TEMP%`-shaped on `win32`).
  final String Function()? tmpdir;

  /// `os.homedir()`; defaults to `$HOME` from [env], else `/root`.
  final String Function()? homedir;

  /// `os.cpus().length`; defaults to `1`.
  final int Function()? cpusCount;
}

/// Returned by [installNodeCompat] so the embedding can adjust per-script
/// state after install (and tear the surface down with [dispose]).
class NodeCompatHandle {
  NodeCompatHandle._(this._runtime);

  final QuickjsRuntime _runtime;

  /// Updates `__filename` / `__dirname` and `process.argv[1]` to [path].
  void setScriptPath(String path) {
    _runtime.eval(
      'globalThis.__ncSetScriptPath(${jsonEncode(path)});',
      filename: '<node_compat_script_path>',
    );
  }
}

/// Installs the compat layer onto [runtime]. Idempotent per runtime
/// (reinstalling replaces the previous surface).
NodeCompatHandle installNodeCompat(
  QuickjsRuntime runtime, [
  NodeCompatConfig? config,
]) {
  final cfg = config ?? const NodeCompatConfig();
  void host(String name, String? Function(String argsJson) fn) {
    // registerHostFunction keeps its own alive list; we mirror it so
    // NodeCompatHandle.dispose can release them deterministically.
    runtime.registerHostFunction(name, fn);
  }

  runtime.setGlobal('__ncConfig', {
    'env': cfg.env,
    'platform': cfg.platform,
    'arch': cfg.arch,
    'nodeVersion': cfg.nodeVersion,
    'argv': cfg.argv,
    'scriptPath': cfg.scriptPath,
    'pid': cfg.pid?.call() ?? 1,
    'cpusCount': cfg.cpusCount?.call() ?? 1,
    'hostname': cfg.hostname?.call() ?? 'localhost',
    'tmpdir': cfg.tmpdir?.call(),
    'homedir': cfg.homedir?.call(),
  });
  host(
      '__ncCwd', (_) => jsonEncode(cfg.cwd?.call() ?? '/'));
  host('__ncNow', (_) {
    final ms =
        cfg.clock?.call() ?? DateTime.now().millisecondsSinceEpoch.toDouble();
    return jsonEncode(ms);
  });
  host('__ncConsoleWrite', (argsJson) {
    try {
      final args = jsonDecode(argsJson) as List;
      cfg.consoleSink?.call('${args[0]}', '${args[1]}');
    } catch (_) {
      // console must never break the script — swallow sink errors.
    }
    return null;
  });
  host('__ncRandomValues', (argsJson) {
    final count = jsonDecode(argsJson) as int;
    final bytes = cfg.randomBytes?.call(count) ?? _pseudoRandom(count);
    return jsonEncode(bytes.map((b) => b & 0xff).toList());
  });
  host('__ncRandomUuid', (_) {
    return jsonEncode(cfg.randomUuid?.call() ?? _pseudoUuid());
  });
  host('__ncUtf8Encode', (argsJson) {
    final text = jsonDecode(argsJson) as String;
    final bytes = cfg.utf8Encode?.call(text) ?? _utf8Bytes(text);
    return jsonEncode(bytes.map((b) => b & 0xff).toList());
  });
  host('__ncUtf8Decode', (argsJson) {
    final bytes = (jsonDecode(argsJson) as List).cast<int>();
    return jsonEncode(cfg.utf8Decode?.call(bytes) ?? _utf8String(bytes));
  });
  host('__ncBase64Encode', (argsJson) {
    final text = jsonDecode(argsJson) as String;
    return jsonEncode(cfg.base64Encode?.call(text) ?? _b64Encode(text));
  });
  host('__ncBase64Decode', (argsJson) {
    final text = jsonDecode(argsJson) as String;
    return jsonEncode(cfg.base64Decode?.call(text) ?? _b64Decode(text));
  });
  host('__ncExit', (argsJson) {
    cfg.exitHook?.call(jsonDecode(argsJson) as int);
    return null;
  });
  runtime.eval(nodeCompatPrelude, filename: '<node_compat>');
  runtime.eval(nodeCompatBufferPrelude, filename: '<node_compat_buffer>');
  runtime.eval(nodeCompatUrlPrelude, filename: '<node_compat_url>');
  return NodeCompatHandle._(runtime);
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

// True UTF-8 (dart:convert) — the latin-1 approximation is gone: default
// codecs must match Node byte-for-byte, hooks are for override only.
List<int> _utf8Bytes(String text) => utf8.encode(text);

String _utf8String(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true);

// Minimal base64 (RFC 4648) for the no-hook default path.
const String _b64alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

String _b64Encode(String text) {
  final bytes = _utf8Bytes(text);
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
  return _utf8String(out);
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
    function inspectValue(v, depth) {
        if (v === null) return 'null';
        if (v === undefined) return 'undefined';
        var t = typeof v;
        if (t === 'string') return depth ? "'" + v + "'" : v;
        if (t === 'number' || t === 'boolean' || t === 'bigint') return String(v);
        if (t === 'function') return '[Function: ' + (v.name || 'anonymous') + ']';
        if (Array.isArray(v)) {
            if ((depth || 0) > 2) return '[Array]';
            return '[ ' + v.map(function (x) { return inspectValue(x, (depth || 0) + 1); }).join(', ') + ' ]';
        }
        if (v instanceof Error) return v.name + ': ' + v.message;
        if (v instanceof Uint8Array) {
            return 'Uint8Array(' + v.length + ') ' + safeStringify(Array.prototype.slice.call(v, 0, 32));
        }
        if (t === 'object') {
            if ((depth || 0) > 2) return '[Object]';
            var keys = Object.keys(v);
            var body = keys.slice(0, 32).map(function (k) {
                return k + ': ' + inspectValue(v[k], (depth || 0) + 1);
            });
            if (keys.length > 32) body.push('...');
            return '{ ' + body.join(', ') + ' }';
        }
        return String(v);
    }

    function unsupported(name, alternative) {
        var fn = function () {
            throw new Error(name + ' is not available in quickjs_runtime: ' +
                alternative);
        };
        return fn;
    }

    // ── console ──
    function fmtArg(a) {
        if (typeof a === 'string') return a;
        return inspectValue(a);
    }
    function consoleWrite(level, args) {
        var parts = [];
        for (var i = 0; i < args.length; i++) parts.push(fmtArg(args[i]));
        __ncConsoleWrite(level, __ncIndent + parts.join(' '));
    }
    var timers = {};
    var counters = {};
    var groupDepth = 0;
    Object.defineProperty(globalThis, '__ncIndent', {
        get: function () { return '  '.repeat(groupDepth); },
        configurable: true
    });
    var consoleObj = {};
    ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        consoleObj[level] = function () { consoleWrite(level, arguments); };
    });
    consoleObj.trace = function () {
        var args = ['Trace'];
        for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
        consoleWrite('error', args);
    };
    consoleObj.dir = function (obj) {
        __ncConsoleWrite('log', __ncIndent + inspectValue(obj));
    };
    consoleObj.time = function (label) {
        timers[label === undefined ? 'default' : String(label)] = __ncNow();
    };
    consoleObj.timeLog = function (label) {
        var key = label === undefined ? 'default' : String(label);
        var start = timers[key];
        if (start === undefined) {
            consoleWrite('warn', ['Timer \'' + key + '\' does not exist']);
            return;
        }
        var rest = [];
        for (var i = 1; i < arguments.length; i++) rest.push(arguments[i]);
        consoleWrite('log', [key + ': ' + (__ncNow() - start) + 'ms'].concat(rest));
    };
    consoleObj.timeEnd = function (label) {
        var key = label === undefined ? 'default' : String(label);
        var start = timers[key];
        if (start === undefined) {
            consoleWrite('warn', ['Timer \'' + key + '\' does not exist']);
            return;
        }
        delete timers[key];
        consoleWrite('log', [key + ': ' + (__ncNow() - start) + 'ms']);
    };
    consoleObj.count = function (label) {
        var key = label === undefined ? 'default' : String(label);
        counters[key] = (counters[key] || 0) + 1;
        consoleWrite('log', [key + ': ' + counters[key]]);
    };
    consoleObj.countReset = function (label) {
        var key = label === undefined ? 'default' : String(label);
        delete counters[key];
    };
    consoleObj.group = function () {
        if (arguments.length) consoleWrite('log', arguments);
        groupDepth++;
    };
    consoleObj.groupCollapsed = consoleObj.group;
    consoleObj.groupEnd = function () {
        if (groupDepth > 0) groupDepth--;
    };
    consoleObj.table = function (data) {
        __ncConsoleWrite('log', __ncIndent + renderTable(data));
    };
    function padCell(v, width) {
        var s = String(v);
        var out = s;
        for (var i = s.length; i < width; i++) out += ' ';
        return out;
    }
    function renderTable(data) {
        var rows;
        var isArr = Array.isArray(data);
        if (isArr) {
            rows = data.map(function (v, i) { return [String(i), v]; });
        } else if (data && typeof data === 'object') {
            rows = Object.keys(data).map(function (k) { return [k, data[k]]; });
        } else {
            return safeStringify(data);
        }
        var cols = [];
        var headerSet = {};
        rows.forEach(function (r) {
            var v = r[1];
            if (v && typeof v === 'object' && !(v instanceof Date)) {
                Object.keys(v).forEach(function (k) {
                    if (!headerSet[k]) { headerSet[k] = true; cols.push(k); }
                });
            }
        });
        var header = isArr ? ['(iteration index)'] : ['(index)'];
        header = header.concat(cols.length ? cols : ['Values']);
        var lines = [];
        var widths = header.map(function (h) { return String(h).length; });
        var table = rows.map(function (r) {
            var v = r[1];
            if (v && typeof v === 'object') {
                return [r[0]].concat(cols.map(function (c) {
                    return c in v ? safeStringify(v[c]) : '';
                }));
            }
            return [r[0]].concat(cols.length ? [] : [safeStringify(v)]);
        });
        [header].concat(table).forEach(function (row) {
            row.forEach(function (cell, i) {
                if (String(cell).length > widths[i]) widths[i] = String(cell).length;
            });
        });
        function renderRow(row) {
            return '\u2502 ' + row.map(function (c, i) {
                return padCell(String(c), widths[i]);
            }).join(' \u2502 ') + ' \u2502';
        }
        var sep = '\u250c' + widths.map(function (w) {
            var d = '';
            for (var i = 0; i < w + 2; i++) d += '\u2500';
            return d;
        }).join('\u252c') + '\u2510';
        var sepMid = '\u251c' + widths.map(function (w) {
            var d = '';
            for (var i = 0; i < w + 2; i++) d += '\u2500';
            return d;
        }).join('\u253c') + '\u2524';
        var sepEnd = '\u2514' + widths.map(function (w) {
            var d = '';
            for (var i = 0; i < w + 2; i++) d += '\u2500';
            return d;
        }).join('\u2534') + '\u2518';
        lines.push(sep, renderRow(header), sepMid);
        table.forEach(function (row, idx) {
            lines.push(renderRow(row));
            if (idx < table.length - 1) lines.push(sepMid);
        });
        lines.push(sepEnd);
        return lines.join('\n');
    }
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
    var exitListeners = [];
    var argvList = (cfg.argv && cfg.argv.length) ? cfg.argv.slice()
        : ['<runtime>', cfg.scriptPath || '<main>'];
    var clockZero = null;
    function monoMs() {
        var now = __ncNow();
        if (clockZero === null) clockZero = now;
        return now - clockZero;
    }
    globalThis.process = {
        env: envObj,
        platform: cfg.platform,
        arch: cfg.arch,
        version: cfg.nodeVersion,
        exitCode: 0,
        pid: cfg.pid || 1,
        execPath: argvList[0] || '<runtime>',
        argv: argvList,
        cwd: cwdSafe,
        hrtime: function hrtime(previous) {
            var ms = monoMs();
            var secs = Math.floor(ms / 1000);
            var nanos = Math.round((ms - secs * 1000) * 1e6);
            if (Array.isArray(previous)) {
                var dSecs = secs - previous[0];
                var dNanos = nanos - previous[1];
                if (dNanos < 0) { dSecs -= 1; dNanos += 1e9; }
                return [dSecs, dNanos];
            }
            return [secs, nanos];
        },
        uptime: function () { return monoMs() / 1000; },
        memoryUsage: function () {
            return { rss: 0, heapTotal: 0, heapUsed: 0, external: 0,
                arrayBuffers: 0 };
        },
        on: function (event, listener) {
            if (event === 'exit') exitListeners.push(listener);
            return globalThis.process;
        },
        addListener: function (event, listener) {
            return globalThis.process.on(event, listener);
        },
        stdout: {
            isTTY: false,
            write: function (s) {
                __ncConsoleWrite('log', __ncIndent + String(s));
                return true;
            }
        },
        stderr: {
            isTTY: false,
            write: function (s) {
                __ncConsoleWrite('error', __ncIndent + String(s));
                return true;
            }
        },
        stdin: { readable: false, on: function () { return this; } },
        cwd: cwdSafe,
        exit: function (code) {
            try { __ncExit(code || 0); } catch (e) { /* host hook only */ }
            for (var i = 0; i < exitListeners.length; i++) {
                try { exitListeners[i](code || 0); } catch (e2) { /* stay sync */ }
            }
            throw new Error('ProcessExit: ' + (code || 0));
        },
        nextTick: unsupported('process.nextTick',
            'no scheduling beyond promises — run the work directly')
    };
    process.hrtime.bigint = function () {
        var ms = monoMs();
        return BigInt(Math.round(ms * 1e6));
    };
    globalThis.__ncSetScriptPath = function (p) {
        argvList[1] = p;
        var idx = String(p).lastIndexOf('/');
        globalThis.__filename = p;
        globalThis.__dirname = idx < 0 ? '.' : (idx === 0 ? '/' : String(p).slice(0, idx));
    };
    if (cfg.scriptPath) {
        globalThis.__ncSetScriptPath(cfg.scriptPath);
    } else {
        globalThis.__filename = '[eval]';
        globalThis.__dirname = cwdSafe();
    }

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
        inspect: function (v) { return inspectValue(v, 0); },
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
        util: function () { return globalThis.util; },
        os: function () { return osModule; },
        url: function () { return globalThis.__ncRegistry.url(); },
        buffer: function () { return globalThis.__ncRegistry.buffer(); }
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
            "' (compat builtins: path, assert, util, os, url, buffer" +
            (Object.keys(registry).length
                ? '; consumer-registered: ' + Object.keys(registry).join(', ')
                : '') + ')');
    }
    globalThis.require = compatRequire;

    // ── Intl (typeof-safe, call-time stubs — no ICU in QuickJS) ──
    function intlStub(name) {
        return function () {
            throw new Error(
                'Intl.' + name + ' is not available in quickjs_runtime: ' +
                'no ICU in QuickJS — format in the host or with plain JS');
        };
    }
    globalThis.Intl = {
        NumberFormat: intlStub('NumberFormat'),
        DateTimeFormat: intlStub('DateTimeFormat'),
        Collator: intlStub('Collator'),
        PluralRules: intlStub('PluralRules'),
        RelativeTimeFormat: intlStub('RelativeTimeFormat'),
        ListFormat: intlStub('ListFormat'),
        Segmenter: intlStub('Segmenter'),
        DisplayNames: intlStub('DisplayNames'),
        SupportedLocales: function () { return []; },
        getCanonicalLocales: function (locales) {
            if (locales === undefined || locales === null) return [];
            return Array.isArray(locales) ? locales.slice()
                : [String(locales)];
        }
    };

    // ── os builtin module (require('os'); no global, like Node) ──
    var osModule = {
        EOL: cfg.platform === 'win32' ? '\r\n' : '\n',
        arch: function () { return cfg.arch; },
        platform: function () { return cfg.platform; },
        type: function () {
            if (cfg.platform === 'win32') return 'Windows_NT';
            if (cfg.platform === 'darwin') return 'Darwin';
            return 'Linux';
        },
        release: function () { return ''; },
        hostname: function () { return cfg.hostname || 'localhost'; },
        tmpdir: function () {
            if (cfg.tmpdir) return cfg.tmpdir;
            if (cfg.platform === 'win32') {
                return envObj.TEMP || envObj.TMP || 'C:\\Windows\\Temp';
            }
            return '/tmp';
        },
        homedir: function () {
            if (cfg.homedir) return cfg.homedir;
            return envObj.HOME || (cfg.platform === 'win32'
                ? 'C:\\Users\\user' : '/root');
        },
        cpus: function () {
            var n = cfg.cpusCount || 1;
            var out = [];
            for (var i = 0; i < n; i++) {
                out.push({ model: 'QuickJS', speed: 0, times: {
                    user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } });
            }
            return out;
        },
        uptime: function () { return Math.floor(monoMs() / 1000); },
        loadavg: function () { return [0, 0, 0]; },
        totalmem: function () { return 0; },
        freemem: function () { return 0; },
        networkInterfaces: function () { return {}; },
        userInfo: function () {
            return { username: 'user', uid: -1, gid: -1, shell: null,
                homedir: osModule.homedir() };
        }
    };

    // ── Tier 2: call-time stubs (typeof-safe) ──
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
