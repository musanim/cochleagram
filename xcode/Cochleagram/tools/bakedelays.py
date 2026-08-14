#!/usr/bin/env python3
"""Write a measured de-skew curve into a coefficient file.

The engine normally measures the curve when it builds an engine: it runs an
impulse through the cascade and takes each tap's first peak.  That works down
to about ERB 0.6.  Below it the first peak sits two hundred decibels under the
tap's own maximum, where whether a sample crosses a threshold is decided in the
last bits of the arithmetic -- and two builds of the same source, clang on
arm64 and gcc on x86, then choose different peaks for a band of taps around
30 Hz and draw a click 87 ms out of line with each other.

A quantity that depends on the compiler is not a property of the filterbank.
So for the tunings where that happens, the curve is measured once and written
into the file, and every build loads the same numbers.

The curve comes from `tools/peakdump.cpp`, run with an output path, which lists
the first few peaks of every tap.  Which peak to take is the argument: the
first is right where the cascade has no precursor, and the second is right
where it has one.

    tools/peakdump  coeffs.coch  reference/pureimpulse.wav  x  peaks.txt
    tools/bakedelays.py  peaks.txt  coeffs.coch  --peak 2

Only the shape matters, not the absolute value: de-skew holds each tap back by
`dmax - delay`, so a constant added to every tap cancels.  That is why times
measured from a file's impulse can be written straight in.

The file gains a version number of 2, which is how the engine knows the curve
is already measured and not to overwrite it.
"""

import argparse
import struct
import sys

HEADER = struct.Struct("<4sidiii")     # magic, version, fs, n_ch, n_lead, tpo


def read_header(blob):
    magic, version, fs, n_ch, n_lead, tpo = HEADER.unpack_from(blob, 0)
    if magic != b"COCH":
        sys.exit("not a coefficient file")
    return version, fs, n_ch, n_lead, tpo


def gdelay_offset(n_ch, n_taps):
    """Where the group-delay vector starts.

    The file is six vectors of n_ch (a0, c0, h, r, g, norm), then bf, gdelay
    and idelay of n_taps.  All doubles, all little-endian.
    """
    return HEADER.size + 8 * (6 * n_ch + n_taps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("peaks", help="output of peakdump with a fourth argument")
    ap.add_argument("coeffs", help="the .coch file to write into")
    ap.add_argument("--peak", type=int, default=2,
                    help="which peak to take, 1-based (default 2)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    blob = bytearray(open(args.coeffs, "rb").read())
    version, fs, n_ch, n_lead, tpo = read_header(blob)
    n_taps = n_ch - n_lead
    off = gdelay_offset(n_ch, n_taps)
    old = struct.unpack_from(f"<{n_taps}d", blob, off)

    curve, missing = [], []
    for line in open(args.peaks):
        if line.startswith("#"):
            continue
        f = line.split()
        t = int(f[0])
        times = [float(f[i]) for i in range(3, len(f) - 1, 2)]
        if len(times) >= args.peak:
            curve.append((t, times[args.peak - 1] / 1000.0))
        else:
            # Not enough peaks inside the window. Keep the tap's own measured
            # value rather than inventing one; a gap in the curve would draw
            # as a step.
            curve.append((t, times[-1] / 1000.0 if times else old[t]))
            missing.append(t)

    if len(curve) != n_taps:
        sys.exit(f"{args.peaks} has {len(curve)} taps, file wants {n_taps}")

    new = [d for _, d in sorted(curve)]
    lo, hi = min(new), max(new)
    back = sum(1 for i in range(1, n_taps) if new[i] < new[i - 1] - 1e-9)
    print(f"{args.coeffs}")
    print(f"  {n_taps} taps, peak {args.peak}")
    print(f"  delays {lo * 1000:.3f} to {hi * 1000:.3f} ms"
          f"   (was {min(old) * 1000:.3f} to {max(old) * 1000:.3f})")
    print(f"  backward steps: {back}")
    if missing:
        print(f"  taps with fewer than {args.peak} peaks, left as measured: "
              f"{len(missing)}")
    if args.dry_run:
        print("  dry run, nothing written")
        return

    struct.pack_into(f"<{n_taps}d", blob, off, *new)
    struct.pack_into("<i", blob, 4, 2)          # version 2: already measured
    open(args.coeffs, "wb").write(blob)
    print("  written, version set to 2")


if __name__ == "__main__":
    main()
