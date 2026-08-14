import 'dart:convert';

import 'package:quickjs_runtime/quickjs_runtime.dart';
import 'package:test/test.dart';

void main() {
  late QuickjsRuntime rt;

  setUp(() {
    rt = QuickjsRuntime();
  });

  tearDown(() {
    rt.close();
  });

  test('eval returns JSON result', () {
    expect(rt.eval('1 + 2'), '3');
    expect(rt.eval('"hello".toUpperCase()'), '"HELLO"');
  });

  test('eval undefined returns null', () {
    expect(rt.eval('undefined'), isNull);
  });

  test('eval error reports message', () {
    final errMsg = <String?>[];
    expect(rt.eval('throw new Error("boom")', errMsg: errMsg), isNull);
    expect(errMsg.first, contains('boom'));
  });

  test('setGlobal exposes a Dart value to JS', () {
    rt.setGlobal('answer', {'value': 42});
    expect(rt.eval('answer.value * 2'), '84');
  });

  test('registerHostFunction invokes Dart synchronously', () {
    rt.registerHostFunction('add', (argsJson) {
      final args = jsonDecode(argsJson) as List;
      return jsonEncode(args[0] + args[1]);
    });
    expect(rt.eval('add(2, 3)'), '5');
  });

  test('executePendingJobs drains promise reactions', () {
    rt.eval('globalThis.out = null; Promise.resolve(7).then((v) => out = v)');
    rt.executePendingJobs();
    expect(rt.eval('out'), '7');
  });
}
