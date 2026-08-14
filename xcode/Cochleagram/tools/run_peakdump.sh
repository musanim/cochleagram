#!/bin/bash
# The first four peaks of every tap's ERB 0.5 impulse response, written where
# both of us can read them, plus the ten-tap summary on screen.
REPO=/Users/stephenmalinowski/ClaudeProjects/Cochleagram
SRC=$REPO/xcode/Cochleagram/Sources/CochleaDSP
COCH=$REPO/xcode/Cochleagram/Sources/CochleagramApp/Resources/cochlea_88200_erb050.coch
WAV=$REPO/reference/pureimpulse.wav
OUT=$REPO/figures/caldump/arm64_peaks_erb050.txt

mkdir -p "$REPO/figures/caldump"
c++ -std=c++17 -O2 -I "$SRC/include" \
    "$REPO/xcode/Cochleagram/tools/peakdump.cpp" "$SRC/cochlea.cpp" \
    -o /tmp/peakdump 2>/dev/null || { echo "build failed"; exit 1; }
/tmp/peakdump "$COCH" "$WAV"
/tmp/peakdump "$COCH" "$WAV" x "$OUT"
