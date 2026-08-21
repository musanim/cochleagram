#!/bin/bash
#
# Build the cochlea engine as a WebAssembly module.
#
# The same cochlea.cpp the Mac app uses, compiled through its C interface --
# so there is one engine, not two, and the browser cannot drift away from the
# thing the Python prototype checks.
#
#   brew install emscripten
#   ./build.sh
#
# Writes site/cochlea.js and site/cochlea.wasm.
set -euo pipefail
cd "$(dirname "$0")"

SRC=../xcode/Cochleagram
command -v em++ >/dev/null || { echo "em++ not found -- brew install emscripten"; exit 1; }

# No -msimd128. Measured: 35.4% of a core against 35.3% scalar, which is
# noise. A cascade is serial in both axes -- within a sample each tap feeds the
# next, within a tap each sample feeds the next -- so there is nothing for
# 128-bit lanes to do, and requiring SIMD would only narrow which browsers can
# run it.
#
# WASM_BIGINT because cochlea_dropped_columns returns a uint64_t. Without it
# Emscripten splits the return in two and JavaScript sees only the low half,
# which for a health check that is supposed to read zero is the worst possible
# failure: it would read zero while columns were being lost.
em++ -std=c++17 -O3 \
    -I "$SRC/Sources/CochleaDSP/include" \
    "$SRC/Sources/CochleaDSP/cochlea.cpp" \
    -o site/cochlea.js \
    -sMODULARIZE=1 -sEXPORT_ES6=1 \
    -sENVIRONMENT=web,worker \
    -sALLOW_MEMORY_GROWTH=1 \
    -sWASM_BIGINT=1 \
    -sFORCE_FILESYSTEM=1 \
    -sEXPORTED_RUNTIME_METHODS='["FS","HEAPF32","HEAPF64","HEAPU8"]' \
    -sEXPORTED_FUNCTIONS='["_malloc","_free",
        "_cochlea_create","_cochlea_destroy",
        "_cochlea_tap_count","_cochlea_internal_rate",
        "_cochlea_frequencies","_cochlea_delays",
        "_cochlea_set_column_ms","_cochlea_set_auto_gain_halflife",
        "_cochlea_current_ref_db","_cochlea_set_deskew",
        "_cochlea_process","_cochlea_pull_columns",
        "_cochlea_dropped_columns","_cochlea_peak_level"]'

# Not exported: the engine's input capture ring, which the Mac app uses to keep
# the audio behind the picture. The browser already has those samples on the
# main thread -- the capture worklet posts them there on the way to this engine
# -- so it keeps its own copy and never asks. Exporting the four functions
# would put a second recording in the WASM heap that nothing ever reads.

# The coefficients the page fetches. Copied rather than tracked twice: they
# already live in the app's Resources, and a second set in the repository is a
# second set to forget to regenerate.
cp "$SRC/Sources/CochleagramApp/Resources/"*.coch site/

ls -la site/cochlea.js site/cochlea.wasm | sed 's/^/  /'
echo "  $(ls site/*.coch | wc -l | tr -d ' ') coefficient files"
