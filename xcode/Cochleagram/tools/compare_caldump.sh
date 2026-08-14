#!/bin/bash
# Compare this machine's calibration against the reference curves in
# figures/caldump/, tap by tap. Prints only the taps that differ.
REPO=/Users/stephenmalinowski/ClaudeProjects/Cochleagram
SRC=$REPO/xcode/Cochleagram/Sources/CochleaDSP
RES=$REPO/xcode/Cochleagram/Sources/CochleagramApp/Resources
REF=$REPO/figures/caldump

c++ -std=c++17 -O2 -I "$SRC/include" \
    "$REPO/xcode/Cochleagram/tools/caldump.cpp" "$SRC/cochlea.cpp" \
    -o /tmp/caldump || exit 1

for e in 050 060 070 100; do
    /tmp/caldump "$RES/cochlea_88200_erb$e.coch" | tail -n +5 > /tmp/mine_$e.txt
    n=$(awk 'NR==FNR{a[$1]=$3;next} $1 in a && (a[$1]-$3 > 0.0001 || $3-a[$1] > 0.0001)' \
        "$REF/x86_erb$e.txt" /tmp/mine_$e.txt | wc -l)
    echo "=== erb$e: $n taps differ ==="
    awk 'NR==FNR{a[$1]=$3;next}
         $1 in a && (a[$1]-$3 > 0.0001 || $3-a[$1] > 0.0001) {
             printf "  tap %4d %9.1f Hz   x86 %10.4f   here %10.4f   diff %+9.4f ms\n",
                    $1, $2, a[$1], $3, $3-a[$1] }' \
        "$REF/x86_erb$e.txt" /tmp/mine_$e.txt | head -25
done
