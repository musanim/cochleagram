#!/bin/bash
# Bake every tuning's de-skew curve into its coefficient file.
#
# The engine measures its own de-skew curve at build time, which costs about
# 200 ms of every engine build -- paid at launch, on every ERB change, and on
# every device change -- and gives each machine a slightly different answer.
# This runs that measurement once, here, and writes the result into the files,
# so every build afterwards loads the same numbers and skips the measurement.
#
# RUN THIS ON THE MACHINE WHOSE ARITHMETIC SHOULD BE CANONICAL.  That is
# Stephen's arm64 Mac.  A Linux or x86 build measures a curve that differs from
# the Mac's on a handful of taps at the sharpest tunings, and baking it would
# ship those differences to every platform at once -- the browser included,
# since web/build.sh copies these same files into web/site/.  The build
# fingerprint is recorded in each saved curve so it is always possible to see
# what measured what.
#
# 44100 Hz, because the curve depends on the input rate: 44100 takes the exact
# half-band path and 48000 falls back to fractional interpolation.  Anchored on
# each curve's own maximum, the two rates agree to 0.15 ms at ERB 0.8 and
# blunter, differ by 0.85 ms on five taps near 1.7 kHz at 0.7, and by 2.88 ms
# on one tap at 447 Hz at 0.6 -- isolated peak-index flips, not a different
# curve, and removing them is part of the point.
#
# ERB 0.5 is not touched, and is not in the loop below.  Its curve was baked by
# hand from `peakdump --peak 2` and checked on the picture; the engine's
# automatic precursor rule is a kludge by its own admission and is not an
# improvement on a curve Stephen has looked at.  If 0.5 is ever re-exported it
# comes back as version 1 and this script will NOT repair it -- see
# tools/bakedelays.py for the peak-list recipe, which is the only route that
# lets a human overrule the engine's choice of peak.
#
# To re-bake the rest after changing the filterbank: re-run
# prototype/export_coeffs.py, which writes fresh version-1 files, then run this
# again.  A file that is already version 2 is skipped, because loading it would
# echo the curve it already carries instead of measuring one.
#
#     tools/bakeall.sh              # measure and write
#     tools/bakeall.sh --dry-run    # measure and report, write no .coch files
#     tools/bakeall.sh --check      # re-measure the baked files and report
#                                   # how far this machine now disagrees with
#                                   # what was baked -- writes nothing, and is
#                                   # the thing to run after changing compiler
#
# All three write the measured curves to $OUT, which is gitignored working
# material, not a coefficient file.
#
# BAKE_RES and BAKE_OUT override where it reads the coefficient files and
# writes the curves, so the script itself can be exercised against a copy
# rather than against the files that ship.

set -euo pipefail

[ $# -le 1 ] || { echo "bakeall.sh: too many arguments" >&2; exit 2; }
MODE=bake
if [ $# -eq 1 ]; then
    # `$#`, not the value: `bakeall.sh ""` -- which is what an unset variable
    # expands to -- must not be taken for no argument at all and bake for real.
    case "$1" in
        --dry-run)  MODE=dry ;;
        --check)    MODE=check ;;
        *)          echo "usage: bakeall.sh [--dry-run | --check]" >&2
                    exit 2 ;;
    esac
fi

# Located from the script rather than hardcoded, unlike its neighbours here:
# this one writes to files that ship, so it has to be exercisable against a
# copy of the tree.
TOOLDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TOOLDIR/../../.." && pwd)
SRC=$REPO/xcode/Cochleagram/Sources/CochleaDSP
RES=${BAKE_RES:-$REPO/xcode/Cochleagram/Sources/CochleagramApp/Resources}
OUT=${BAKE_OUT:-$REPO/figures/caldump}
RATE=44100

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bakeall.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
BIN=$WORK/measuredelays

mkdir -p "$OUT"
# -O2 and the default -ffp-contract, which is what SwiftPM's release build
# gives cochlea.cpp: Package.swift sets no cxxSettings, so the app gets clang's
# C++ defaults at -O2 and so does this. That match is load-bearing -- the whole
# reason the curve needs baking is that contraction decides it -- and `--check`
# is how to find out whether it still holds after a toolchain change.
c++ -std=c++17 -O2 -I "$SRC/include" \
    "$TOOLDIR/measuredelays.cpp" "$SRC/cochlea.cpp" -o "$BIN" \
    || { echo "build failed" >&2; exit 1; }

echo "measuring at $RATE Hz  (mode: $MODE)"
"$BIN" --build | sed 's/^# /  /'
echo

# Three outcomes, counted separately, because the interesting distinction is
# not "did anything happen" but "were the files there at all". Everything
# already baked is the normal result of a second run and is a success; nothing
# found is almost always $RES pointing somewhere unintended.
did=0
seen=0
for e in 060 070 080 090 100 110 120 130; do
    coch=$RES/cochlea_88200_erb$e.coch
    [ -f "$coch" ] || { echo "erb$e: no such file, skipped"; continue; }
    seen=$((seen + 1))

    # Version is a little-endian int32 at offset 4, after the 'COCH' magic.
    v=$(python3 -c "import struct,sys; b=open(sys.argv[1],'rb').read(8); \
sys.exit('short file') if len(b)<8 else print(struct.unpack('<i', b[4:])[0])" \
        "$coch") || { echo "erb$e: could not read the version" >&2; exit 1; }

    if [ "$MODE" = check ]; then
        if [ "$v" -lt 2 ]; then
            echo "erb$e: version $v, nothing baked to check against"
            continue
        fi
        curve=$OUT/check_erb$e.txt
        "$BIN" "$coch" "$RATE" --force > "$curve"
        # --dry-run so it reports the shape difference and writes nothing.
        python3 "$TOOLDIR/bakedelays.py" --curve "$curve" "$coch" --dry-run
        did=$((did + 1))
        continue
    fi

    if [ "$v" -ge 2 ]; then
        echo "erb$e: already version $v, skipped"
        continue
    fi

    # Measure first, into a file that stays behind as the record of what was
    # written -- diffable against another machine, and the only way to see the
    # curve once it is inside a binary. A dry run writes to its own name: it
    # produced no bake, so it must not overwrite the record of one.
    if [ "$MODE" = dry ]; then
        curve=$OUT/dryrun_erb$e.txt
        "$BIN" "$coch" "$RATE" > "$curve"
        python3 "$TOOLDIR/bakedelays.py" --curve "$curve" "$coch" --dry-run
    else
        curve=$OUT/baked_erb$e.txt
        "$BIN" "$coch" "$RATE" > "$curve"
        python3 "$TOOLDIR/bakedelays.py" --curve "$curve" "$coch"
    fi
    did=$((did + 1))
done

if [ "$seen" -eq 0 ]; then
    # Silence and success is the wrong answer to "there were no files": the
    # likeliest cause is that $RES points somewhere unintended.
    echo >&2
    echo "bakeall.sh: no coefficient files found in" >&2
    echo "  $RES" >&2
    echo "If that is not where they are, set BAKE_RES." >&2
    exit 1
fi
if [ "$did" -eq 0 ]; then
    case $MODE in
        check) echo; echo "nothing baked to check -- run bakeall.sh first" ;;
        *)     echo; echo "nothing to do: all $seen already baked" ;;
    esac
fi

echo
echo "versions now:"
python3 - "$RES" <<'EOF'
import glob, os, struct, sys
bad = 0
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.coch"))):
    name = os.path.basename(p)
    with open(p, "rb") as f:
        head = f.read(8)
    # Not a traceback: this runs after every bake has succeeded, and a stray
    # short file in the directory must not be the last thing on screen.
    if len(head) < 8 or head[:4] != b"COCH":
        print(f"  {name}  not a coefficient file")
        bad += 1
        continue
    version = struct.unpack("<i", head[4:])[0]
    print(f"  {name}  version {version}")
    bad += version < 2
if bad:
    print(f"\n  {bad} not baked -- release.sh will refuse these.")
EOF
