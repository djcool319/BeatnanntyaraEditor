#!/bin/bash
# renderer/vendor/rubberband-wasm.js を作り直す (ふだんは不要。Rubber Band を新しくしたいときだけ)
#   必要なもの: wasi-sdk (https://github.com/WebAssembly/wasi-sdk/releases の wasi-sdk-25 で確認)、python3
#   使い方: WASI_SDK=/path/to/wasi-sdk-25.0-x86_64-linux bash tools/build-rubberband.sh
# Rubber Band は GPL v2 以上 (https://breakfastquay.com/rubberband/)。v4.0.0 の single/RubberBandSingle.cpp をそのまま使う
set -euo pipefail
cd "$(dirname "$0")/.."
: "${WASI_SDK:?WASI_SDK に wasi-sdk のフォルダを入れてください}"
TMP=$(mktemp -d)
git clone -q --depth 1 --branch v4.0.0 https://github.com/breakfastquay/rubberband.git "$TMP/rb"
cat > "$TMP/glue.c" <<'C'
#include <stdlib.h>
__attribute__((export_name("bx_malloc"))) void *bx_malloc(unsigned long n) { return malloc(n); }
__attribute__((export_name("bx_free"))) void bx_free(void *p) { free(p); }
C
EXP=""
for f in rubberband_new rubberband_delete rubberband_reset rubberband_set_time_ratio rubberband_set_pitch_scale \
         rubberband_set_expected_input_duration rubberband_get_samples_required rubberband_set_max_process_size \
         rubberband_study rubberband_process rubberband_available rubberband_retrieve rubberband_get_start_delay \
         rubberband_get_preferred_start_pad; do EXP="$EXP -Wl,--export=$f"; done
"$WASI_SDK/bin/clang++" --target=wasm32-wasip1 --sysroot="$WASI_SDK/share/wasi-sysroot" -O3 -fno-exceptions \
  -DNO_EXCEPTIONS -DNO_THREADING -DNO_TIMING -DUSE_BUILTIN_FFT -DUSE_BQRESAMPLER \
  -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -mexec-model=reactor \
  -I "$TMP/rb" -I "$TMP/rb/rubberband" "$TMP/rb/single/RubberBandSingle.cpp" -x c "$TMP/glue.c" $EXP \
  -lwasi-emulated-mman -lwasi-emulated-signal -lwasi-emulated-process-clocks -Wl,--strip-all -o "$TMP/rubberband.wasm"
python3 - "$TMP/rubberband.wasm" renderer/vendor/rubberband-wasm.js <<'PY'
import base64, sys
b = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'w').write("// Rubber Band (GPL v2 以上) を WebAssembly にしたもの。作り方は tools/build-rubberband.sh\n// stretch.js の Worker で使う (index.html で読んで、audio.js が Worker に渡す)\nself.BX_RUBBERBAND_WASM = '" + base64.b64encode(b).decode() + "';\n")
PY
rm -rf "$TMP"
echo "renderer/vendor/rubberband-wasm.js を作り直しました"
