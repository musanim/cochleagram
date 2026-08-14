#!/bin/bash
# Calibration threshold sweep. Prints one row per threshold; the `sum` changes
# if any single tap's delay changes, so identical sums mean identical curves.
REPO=/Users/stephenmalinowski/ClaudeProjects/Cochleagram
SRC=$REPO/xcode/Cochleagram/Sources/CochleaDSP
RES=$REPO/xcode/Cochleagram/Sources/CochleagramApp/Resources
TOOLS=$REPO/xcode/Cochleagram/tools

printf "%-7s %15s %15s %15s %15s\n" thresh erb050 erb060 erb070 erb100
for a in 1e-6 1e-7 1e-8 1e-9 1e-10 1e-12 1e-15; do
    c++ -std=c++17 -O2 -DCOCHLEA_LEAD_ABSOLUTE=$a -I "$SRC/include" \
        "$TOOLS/caldump.cpp" "$SRC/cochlea.cpp" -o /tmp/cdx 2>/dev/null || {
        echo "build failed at $a"; continue; }
    printf "%-7s" "$a"
    for e in 050 060 070 100; do
        /tmp/cdx "$RES/cochlea_88200_erb$e.coch" \
            | sed -n '4p' | sed -n 's/.*sum *\([0-9.]*\).*/\1/p' \
            | awk '{printf "%16.3f", $1}'
    done
    echo
done
