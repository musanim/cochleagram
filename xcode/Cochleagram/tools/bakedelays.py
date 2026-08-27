#!/usr/bin/env python3
"""Write a measured de-skew curve into a coefficient file.

Left to itself the engine measures the curve every time it builds an engine: it
runs an impulse through the cascade and takes each tap's first peak.  There are
two things wrong with that, and baking fixes both.

It costs about 200 ms of the 440 an engine build takes -- paid at launch, on
every ERB change and on every device change -- for an answer that never varies
on a given machine.

And it does vary *between* machines.  Below about ERB 0.6 the first peak sits
two hundred decibels under the tap's own maximum, where whether a sample
crosses a threshold is decided in the last bits of the arithmetic, and two
builds of the same source -- clang on arm64, gcc on x86 -- choose different
peaks for a band of taps around 30 Hz and draw a click 87 ms out of line with
each other.  A quantity that depends on the compiler is not a property of the
filterbank.

So the curve is measured once, on a nominated machine, and written into the
file; every build afterwards loads the same numbers and skips the measurement.
All nine tunings are baked.  `tools/bakeall.sh` is the procedure.

There are two ways in, and they differ in who chooses the peak.

**`--curve`, from `tools/measuredelays.cpp`.**  The ordinary route, and what
`tools/bakeall.sh` uses.  measuredelays lets the engine calibrate itself and
prints the curve it arrived at, so the peak selection is the engine's own --
threshold, precursor rule and all -- and nothing here has to reproduce it.

    tools/measuredelays  coeffs.coch  44100  > curve.txt
    tools/bakedelays.py  --curve  curve.txt  coeffs.coch

**Peak lists, from `tools/peakdump.cpp`.**  The older route, kept because it is
the only one that lets a human overrule the engine.  peakdump lists the first
few peaks of every tap and `--peak` says which to take: the first is right
where the cascade has no precursor, and the second is right where it has one.
ERB 0.5's curve was baked this way and stays that way -- the engine's automatic
precursor rule is a kludge by its own admission, and a hand-checked curve that
Stephen has looked at is not worth replacing with it.

    tools/peakdump  coeffs.coch  reference/pureimpulse.wav  x  peaks.txt
    tools/bakedelays.py  peaks.txt  coeffs.coch  --peak 2

For *alignment*, only the shape matters: de-skew holds each tap back by
`dmax - delay`, so a constant added to every tap cancels and the picture is
unchanged.  That is why times measured from a file's impulse -- which carry
whatever offset the file and the resampler put in front of them -- can be
written straight in.

The absolute value is not free, though, and the docstring here used to say it
was.  `dmax` is the display latency: the app reads it back through
`cochlea_delays` as `maxDelayMS`, and it is what converts a column on screen
into a moment of audio.  A curve from `--curve` is the engine's own
measurement and carries no added offset, so this does not arise; a curve from
a peak listing carries whatever offset the impulse file had, and ERB 0.5's
`dmax` moved by 2.2 ms -- 241.9 to 239.7 -- when it was baked that way.

The file gains a version number of 2, which is how the engine knows the curve
is already measured and not to overwrite it.
"""

import argparse
import math
import os
import stat
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


def read_peaks(path, want, old):
    """Take one peak per tap from a peakdump listing.

    Fields are tap, then alternating time/level pairs from field 3 on.
    """
    curve, missing = [], []
    for line in open(path):
        if line.startswith("#"):
            continue
        f = line.split()
        t = int(f[0])
        if not 0 <= t < len(old):
            # Checked here rather than by the caller's tap-set test, which
            # runs too late: `old[t]` below would already have raised.
            sys.exit(f"{path}: tap {t} is outside 0..{len(old) - 1}")
        times = [float(f[i]) for i in range(3, len(f) - 1, 2)]
        if len(times) >= want:
            curve.append((t, times[want - 1] / 1000.0))
        else:
            # Not enough peaks inside the window. Keep the tap's own measured
            # value rather than inventing one; a gap in the curve would draw
            # as a step.
            curve.append((t, times[-1] / 1000.0 if times else old[t]))
            missing.append(t)
    return curve, missing


def read_curve(path):
    """Take the whole curve from a measuredelays listing.

    Field 0 is the tap and field 2 the delay in milliseconds; field 1 is the
    best frequency, which is there for the reader.  Nothing is selected here
    and nothing can be missing -- the engine has already decided, per tap,
    which peak its curve is made of.
    """
    curve = []
    for n, line in enumerate(open(path), 1):
        if line.startswith("#") or not line.strip():
            continue
        f = line.split()
        # Nothing is skipped quietly.  A dropped line reappears later as a
        # tap-count mismatch, which names the wrong cause and sends whoever
        # reads it looking at the coefficient file.
        try:
            if len(f) < 3:
                raise ValueError("expected three fields")
            curve.append((int(f[0]), float(f[2]) / 1000.0))
        except ValueError as exc:
            sys.exit(f"{path}:{n}: {exc}: {line.rstrip()}")
    return curve, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="a measuredelays curve (with --curve), or "
                                   "peakdump output run with a fourth argument")
    ap.add_argument("coeffs", help="the .coch file to write into")
    ap.add_argument("--curve", action="store_true",
                    help="source is a measuredelays listing, not peaks")
    ap.add_argument("--peak", type=int, default=2,
                    help="peak listings only: which peak to take, 1-based "
                         "(default 2)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    blob = bytearray(open(args.coeffs, "rb").read())
    version, fs, n_ch, n_lead, tpo = read_header(blob)
    n_taps = n_ch - n_lead
    off = gdelay_offset(n_ch, n_taps)
    old = struct.unpack_from(f"<{n_taps}d", blob, off)

    if args.curve:
        curve, missing = read_curve(args.source)
    else:
        curve, missing = read_peaks(args.source, args.peak, old)

    if len(curve) != n_taps:
        sys.exit(f"{args.source} has {len(curve)} taps, file wants {n_taps}")
    if {t for t, _ in curve} != set(range(n_taps)):
        sys.exit(f"{args.source} does not name taps 0..{n_taps - 1} exactly once")

    new = [d for _, d in sorted(curve)]
    if not all(math.isfinite(d) and d >= 0.0 for d in new):
        sys.exit(f"{args.source}: delays must be finite and non-negative")
    lo, hi = min(new), max(new)
    back = sum(1 for i in range(1, n_taps) if new[i] < new[i - 1] - 1e-9)
    # What de-skew actually applies is `dmax - delay`, so a constant added to
    # every tap cancels and only the shape can change the picture.  Anchor
    # both curves on their own maximum before comparing, or a whole-curve
    # offset reads as an alarming change that draws identically.
    #
    # Only meaningful against another *measured* curve, which is to say a
    # version-2 file.  A version-1 file still holds the analytic group delay
    # from export_coeffs.py -- what the poles say, not what an impulse does --
    # and the engine overwrites it at load.  The two disagree by tens of
    # milliseconds by design, so reporting that as a change would be reporting
    # the difference this whole mechanism exists to record.
    shape = [abs((hi - new[i]) - (max(old) - old[i])) * 1000.0
             for i in range(n_taps)]
    worst = max(range(n_taps), key=lambda i: shape[i])
    print(f"{args.coeffs}")
    print(f"  {n_taps} taps, "
          + ("measured curve" if args.curve else f"peak {args.peak}"))
    print(f"  delays {lo * 1000:.3f} to {hi * 1000:.3f} ms"
          f"   (was {min(old) * 1000:.3f} to {max(old) * 1000:.3f})")
    print(f"  backward steps: {back}")
    if version >= 2:
        print(f"  shape change vs the curve already baked in: worst "
              f"{shape[worst]:.3f} ms at tap {worst}, "
              f"{sum(1 for s in shape if s > 0.5)} taps over 0.5 ms")
        if not args.dry_run:
            print(f"  note: {args.coeffs} is already version {version} -- "
                  f"this replaces a curve that was baked before")
    else:
        print(f"  (the file held the analytic curve, which the engine "
              f"overwrote at load; not comparable)")
    if missing:
        print(f"  taps with fewer than {args.peak} peaks, left as measured: "
              f"{len(missing)}")

    # After the report, not before it: a curve this rejects is a curve someone
    # now has to diagnose, and the range and span above are the first two
    # things they will want.
    #
    # A degenerate curve is still a well-formed one -- it writes, it loads, and
    # it draws a picture with no de-skew in it and nothing to say so.  Every
    # route in passes through here, so here is the cheapest place to notice.
    # A real curve spans the apex's delay, 134 ms at the bluntest tuning, so
    # anything flatter than a millisecond is not a measurement.
    if hi - lo < 0.001:
        sys.exit(f"{args.source}: the curve spans {(hi - lo) * 1000:.6f} ms, "
                 f"which is not a measurement -- was the input rate right?")

    if args.dry_run:
        print("  dry run, nothing written")
        return

    struct.pack_into(f"<{n_taps}d", blob, off, *new)
    struct.pack_into("<i", blob, 4, 2)          # version 2: already measured

    # Written beside the target and renamed over it, because the target is a
    # resource that ships and truncating it in place puts a window -- however
    # short -- where an interrupt leaves a coefficient file that is neither the
    # old one nor the new one.  bakeall.sh does this to eight files in a row.
    # os.replace is atomic within a filesystem, and the temporary is in the
    # same directory to keep it there.
    #
    # Renaming over a file ignores its permissions, so `chmod 444` on a
    # coefficient file would no longer stop this the way writing in place did.
    # Ask first, and carry the original's mode across, or every baked file
    # comes back at whatever the umask says.
    if not os.access(args.coeffs, os.W_OK):
        sys.exit(f"{args.coeffs}: not writable")
    mode = os.stat(args.coeffs).st_mode
    tmp = args.coeffs + f".bake{os.getpid()}.tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(blob)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, stat.S_IMODE(mode))
        os.replace(tmp, args.coeffs)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    print("  written, version set to 2")


if __name__ == "__main__":
    main()
