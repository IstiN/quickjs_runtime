// Build hook for quickjs_runtime: compiles the vendored QuickJS 2024-01-13
// C sources and quickjs_bridge.c into a bundled CodeAsset so Flutter apps
// (iOS, Android, macOS, Linux, Windows) and `dart run` / `dart test` work
// out of the box without running `tool/build_quickjs.sh` manually.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const String _assetName = 'src/quickjs_ffi.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final isWindows = os == OS.windows;
    final builder = CBuilder.library(
      name: 'quickjs_bridge',
      assetName: _assetName,
      sources: const [
        'native/quickjs_bridge.c',
        'native/quickjs/quickjs.c',
        'native/quickjs/libregexp.c',
        'native/quickjs/libunicode.c',
        'native/quickjs/cutils.c',
        'native/quickjs/libbf.c',
      ],
      includes: const ['native/quickjs'],
      defines: const {
        '_GNU_SOURCE': null,
        'CONFIG_VERSION': '"2024-01-13"',
      },
      flags: isWindows
          ? const []
          : const [
              '-Wno-implicit-const-int-float-conversion',
              '-Wno-unused-parameter',
              '-Wno-sign-compare',
            ],
      libraries: isWindows
          ? const []
          : [
              'm',
              'pthread',
              if (os == OS.linux || os == OS.android) 'dl',
            ],
      optimizationLevel: OptimizationLevel.o2,
    );
    await builder.run(input: input, output: output);
  });
}
