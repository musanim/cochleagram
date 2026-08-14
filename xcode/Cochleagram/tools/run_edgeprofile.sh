#!/bin/bash
# Where the leading edge of a click lands, straight from the engine.
REPO=/Users/stephenmalinowski/ClaudeProjects/Cochleagram
SRC=$REPO/xcode/Cochleagram/Sources/CochleaDSP
c++ -std=c++17 -O2 -I "$SRC/include" \
    "$REPO/xcode/Cochleagram/tools/edgeprofile.cpp" "$SRC/cochlea.cpp" \
    -o /tmp/edgeprofile || exit 1
for e in 050 060; do
    /tmp/edgeprofile \
        "$REPO/xcode/Cochleagram/Sources/CochleagramApp/Resources/cochlea_88200_erb$e.coch" \
        "$REPO/reference/pureimpulse.wav"
    echo
done
