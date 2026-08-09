#!/bin/bash
#
# How fast is the cascade, native and in WebAssembly?
#
# The one thing that decides whether a browser version is worth building. The
# engine is portable C++ already -- xcode/README.md builds and runs it with no
# Mac -- so this compiles the same file three ways and feeds all three the same
# broadband noise, which is the worst case: every tap fires on every cycle.
#
# Needs Emscripten for the two WASM runs:  brew install emscripten
# Native alone still works without it.
#
#   ./run.sh [seconds]        default 20
set -uo pipefail
cd "$(dirname "$0")"

SRC=../../xcode/Cochleagram
INC="$SRC/Sources/CochleaDSP/include"
ENG="$SRC/Sources/CochleaDSP/cochlea.cpp"
COEFF="$SRC/Sources/CochleagramApp/Resources/cochlea_88200_erb100.coch"
SECS="${1:-20}"
RATE=48000                    # what Web Audio will hand us

[ -f "$COEFF" ] || { echo "no coefficients at $COEFF"; exit 1; }
mkdir -p build

echo "=== native ==="
c++ -std=c++17 -O3 -I "$INC" bench.cpp "$ENG" -o build/bench-native || exit 1
./build/bench-native "$COEFF" $RATE "$SECS"

# em++, not emcc. `emcc` will happily compile a .cpp -- and then link it
# without libc++, so every `new`, every std::vector and every
# chrono::steady_clock::now comes out undefined at the wasm-ld stage. The
# driver is the whole difference; the flags are the same.
if ! command -v em++ >/dev/null; then
    echo
    echo "em++ not found -- skipping the WebAssembly runs."
    echo "brew install emscripten"
    exit 0
fi

# NODERAWFS lets the WASM build open the coefficient file straight off the
# disk, so the benchmark is the same program rather than a variant of it.
for opt in "scalar:" "SIMD:-msimd128"; do
    name="${opt%%:*}"; flag="${opt#*:}"
    echo
    echo "=== WebAssembly, $name ==="
    em++ -std=c++17 -O3 $flag -sNODERAWFS=1 -sALLOW_MEMORY_GROWTH=1 \
         -I "$INC" bench.cpp "$ENG" -o "build/bench-$name.js" || continue
    node "build/bench-$name.js" "$COEFF" $RATE "$SECS"
done

echo
echo "The number that matters is the last column: percent of one core. Under"
echo "about 50% the display keeps up on a desktop with room for the drawing;"
echo "above about 100% it cannot run at all, whatever the architecture."
