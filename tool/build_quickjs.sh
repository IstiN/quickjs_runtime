#!/usr/bin/env bash
# Builds the QuickJS FFI backend's shared library: native/quickjs/libquickjs_bridge.so
#
# Vendored QuickJS 2024-01-13 + the C bridge (native/quickjs_bridge.c) that the
# Dart FFI layer (lib/src/runtime/quickjs/) talks to. Run from anywhere; the
# output is placed next to the QuickJS sources, where quickjs_ffi.dart looks it
# up. Override CC to use a different compiler.
set -euo pipefail

cd "$(dirname "$0")/../native/quickjs"

CC="${CC:-gcc}"

"$CC" -shared -fPIC -O2 -D_GNU_SOURCE \
  -DCONFIG_VERSION='"2024-01-13"' -I. \
  -o libquickjs_bridge.so ../quickjs_bridge.c \
  quickjs.c libregexp.c libunicode.c cutils.c quickjs-libc.c libbf.c \
  -lm -ldl -lpthread

echo "built native/quickjs/libquickjs_bridge.so"
