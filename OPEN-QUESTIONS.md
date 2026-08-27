# Open questions and things to return to

Running list. Nothing here blocks progress; all of it would make the result
better or more faithful to the original.

---

## Display fidelity

**De-skew reference.** *Mostly settled, 2026aug09.* The engine no longer uses
the analytic group delay from the coefficient file. At startup it feeds an
impulse through the finished cascade -- same coefficients, same rate, middle ear
included -- and records, per tap, the time of the **first** peak of the
sample-and-hold level, not the largest. That is the feature the eye follows: a
tap's response builds over a cycle or two, so aligning maxima aligns something a
whole cycle late at the apex.

**The threshold is absolute, and matched to what the display draws.**
*Settled 2026aug14, Stephen's diagnosis.* It was a fraction of each tap's own
maximum -- a different level for every tap -- and where that level fell between
a tap's first and second peak the search took the second. At ERB 0.6 that put
everything above 305 Hz one cycle late, above 648 Hz two, above 1898 Hz three,
visible as rectangular steps in the leading edge of a click. ERB 1.0 escaped by
luck. No fraction can work: the level to clear varies by tens of decibels
across frequency and tuning, and at ERB 0.6 a genuine first peak sits 185 dB
below its own tap's maximum.

`kLeadAbsolute` is 1e-9, **-180 dBFS**, which is the white point of the default
exposure. That match is the point of the value. The calibration and the display
have to look for the feature at the same level: where a cascade computes a
precursor, calibrating at -300 dB while drawing at -180 is worth 94 ms of
apparent error on its own, and the edge is vertical only at the exposure the
calibration was made for.

**Calibration runs through the same front end as the audio.** *2026aug14,
Stephen's observation.* `calibrateDelays` fed `runCascade` a unit sample
directly, while real audio arrives through the half-band upsampler. A unit
sample at the internal rate carries energy to 44 kHz -- an octave above
anything audio can contain -- and that extra octave leaks down the cascade
almost instantly, appearing as a tiny "response" ahead of the real one. It was
never in the picture. Calibration goes through `feedInput` now.

Found by asking why the response changed *earlier* than the curve the
calibration claimed to be measuring. The two were responses to different
inputs, compared as though they were the same. Worth remembering as a class of
error: a measurement harness that does not go through the path it measures.

**Every tuning's curve is baked into its coefficient file.** *2026aug26.* All
nine files are version 2, so no machine measures its own de-skew curve any
more: `calibrateDelays` does not run in the app at all. That removes about
200 ms from an engine build -- 440 ms down to 235 -- which is paid at launch,
on every ERB change, and on every device change.

`tools/bakeall.sh` is the procedure, and must be run on the machine whose
arithmetic is canonical: Stephen's arm64 Mac, at 44100 Hz. It runs
`tools/measuredelays`, which loads a version-1 file so the engine calibrates
itself and prints the curve it arrived at, and then `tools/bakedelays.py
--curve`, which writes that curve into the file and stamps version 2. The
measurement is the engine's own; nothing reimplements it, which was the reason
not to do this in `export_coeffs.py` as originally proposed -- at the sharpest
tunings the answer is settled in the last bits of the arithmetic, so a Python
implementation would be a third answer rather than the canonical one. Each
curve is left in `figures/caldump/baked_erb*.txt` as it is written, carrying
the build fingerprint of what measured it -- on the baking machine only, since
`figures/` is gitignored. The curve that ships is the copy inside the binary.

**The bake names a sample rate**, because the curve depends on one: the impulse
arrives through `feedInput`, and 44100 takes the exact half-band path while
48000 falls back to fractional interpolation. Anchored on each curve's own
maximum, so a constant cancels, the two rates agreed to 0.15 ms at ERB 0.8 and
blunter; at 0.7 five taps near 1.7 kHz differed by 0.85 ms; at 0.6 the bulk of
the curve differed by a uniform 0.37 ms and one tap at 447 Hz by 2.88 ms.

Two different things, and baking treats them differently. The uniform part is a
constant, and a constant is invisible in the picture -- not because de-skew
cancels it, since `dmax` *is* the display latency and a constant moves it, but
because 0.37 ms is smaller than half a column and `recomputeShifts` rounds the
shifts to whole columns. The isolated taps are peak-index flips, and those are
not made sub-column by baking: the 447 Hz tap is nearly six columns, and
freezing 44100's answer pins it there for a machine running at 48 kHz too. That
is the trade, stated plainly. It is worth taking because a flip is precisely
where the measurement is unstable -- neither answer is the better one, and one
answer everywhere is what the display needs.

Checked, on the copy the procedure was exercised against: the curve the engine
loads is identical tap for tap to the curve that was written, and the coherence
baseline `dt_base` is bit-identical before and after on all eight tunings. That
last one is not obvious -- `dt_base` is derived from the file's delays at load,
so baking changes what it is derived *from* -- but `calibrateCoherence`
overwrites it wholesale and falls back to the derived values only for taps with
fewer than eight observations, and there are none.

ERB 0.5 is untouched and keeps the curve described below. `bakeall.sh` does not
have it in its loop and will not repair it if it is ever re-exported; that one
goes back through the peak-list recipe, which is the only route that lets a
human overrule the engine's choice of peak. To see what the current machine
would measure for it instead, without writing anything: `tools/measuredelays
<file> 44100 --force`.

**The bake assumes the baking binary computes what the app's does.** Both come
from clang at `-O2` with the default `-ffp-contract` -- `Package.swift` sets no
`cxxSettings`, so the app gets the same defaults `bakeall.sh` compiles with --
and that match is the whole premise, since contraction is what decides the
answer. It is an assumption and not a guarantee. `tools/bakeall.sh --check`
re-measures every baked file and reports how far this machine now disagrees
with what was baked; it is what to run after changing toolchain, and it should
report zero.

**ERB 0.5's curve is baked into the coefficient file.** *2026aug14.* Its first
peak sits 200 dB below its tap's own maximum, which is close enough to double
precision's floor that *which* peak is found is settled in the last bits of the
arithmetic. Two builds of the same source disagree: clang on arm64 computes a
precursor at -154 to -377 dB that gcc on x86 does not compute at all, and the
two draw a click 87 ms out of line with each other. Measured with
`tools/caldump.cpp`:

| | agreement between arm64 and x86 |
|---|---|
| ERB 0.8 and blunter | identical to the last digit |
| ERB 0.7 | 12 taps differ, one internal sample each |
| ERB 0.6 | 168 taps, one sample each; dmax 0.20 ms apart |
| ERB 0.5 | drifts to 30 ms; dmax 215.07 against 245.75 |

One internal sample is 0.0113 ms, 2% of a column, so everything from 0.6 up is
verified vertical on both machines -- 1.0 ms of edge spread at 0.6, one column
at 0.7 and above.

For 0.5 the curve is now measured once and written into the file, which carries
**version 2** to say so; the engine loads it and does not recalibrate. See
`tools/bakedelays.py`. The curve currently in the file is the second peak from
an arm64 build, which is the Mac app's arithmetic.

Consequences, all known and accepted:

* It is right on the machine that measured it. An x86 build of the same source
  will draw 0.5 wrongly. This now applies to every tuning rather than to 0.5
  alone -- the browser included, since `web/build.sh` copies these same files
  into `web/site/`. That is the intended trade: one curve everywhere, chosen
  rather than emergent. It is only a real cost where the machines disagree,
  which measurement put at one internal sample -- 0.0113 ms, 2% of a column --
  from ERB 0.6 up, and at 0.5, which is why 0.5 was baked first.
* It is calibrated for exposures where the precursor is below the white point:
  about 6 ms of spread at -140 dB, 14 at -100, 37 at the Defaults' -180, and
  worse at maximum sensitivity, where the display draws the precursor itself
  and no de-skew curve can align a feature that exists in only part of the
  picture.
* Three attempts to repair the curve from monotone continuity instead all
  failed, each a no-op on the machine it was written on and a regression on the
  other. The errors are not discontinuities -- both curves are smooth and
  monotone, they are just not the same curve -- so continuity has nothing to
  grip on.

What remains:

* **A one-pixel staircase along the leading edge.** Inherent, not a bug: the
  de-skew history is a per-column ring, so shifts are a whole number of columns
  and each tap's sub-column remainder survives. Bounded by one column at any
  Speed. Removing it means interpolating between columns on the de-skew read,
  which would blur the one thing this display refuses to blur.

`tools/caldump.cpp` prints the delay curve and a build fingerprint;
`tools/edgeprofile.cpp` says where the leading edge lands, per tap, with no
app involved; `tools/peakdump.cpp` shows the peaks each tap was choosing
between. `tools/compare_caldump.sh` and `tools/sweep_threshold.sh` compare two
machines in one command. Reference curves from x86 are in `figures/caldump/`.

**Harmonic crispness.** Stephen's reference image separates resolved harmonics
slightly more cleanly than the rebuild does. Candidates: tuning sharper than one
ERB, or a different level curve. Easy to sweep once there is a higher-resolution
reference frame than a video still.

**Persistence.** Now pure sample-and-hold, per Stephen's memory of the original.
There is an optional `release_ms` for the trails a held value leaves after the
sound stops; off by default.

**Vertical extent of the original.** The reference PNG's content is 435 px tall.
At one tap per pixel and 60 taps/octave that is 7.25 octaves, not 10 — but it
came from a presentation video, so it is almost certainly just scaled. Would be
settled instantly by a screenshot from the real application.

---

## Mode colouring

Parked while the greyscale display is settled. Where it stands:

- **Tone** detection works well — a run of neighbouring taps locked to one
  periodic driver. Reads 0.99 on a pure tone against 0.01–0.06 on noise and
  clicks.
- **Transient vs noise cannot be done from intervals alone.** Measured: a tap fed
  narrowband noise rings near its own CF with nearly the same interval
  statistics as a tap ringing after a click. The current discriminator is the
  *signed* envelope slope averaged across neighbouring taps — transients are
  common events, noise is not.
- **Open:** did the original distinguish noise as its own category, or was it
  more nearly tonal-versus-not? If noise really was separated, the original was
  using a cue not yet reconstructed.
- The analysis window is measured in ERBs rather than octaves, which fixed
  resolved harmonics being misread as noise. Probably right, but untested
  against the original's behaviour.

---

## Engine

**Multirate structure.** The flat cascade costs ~17% of a core. The multirate
structure of the expired FCT patent — each octave at half the rate of the one
above — would cut that to under 2%, and stops the cost depending on how many
octaves there are. Not needed yet; the obvious move if this ever has to run
alongside a DAW's own load, or on battery.

**Fractional sample rates.** 44.1 → 88.2 and 48 → 96 are exact 2× through the
half-band filter. Anything else falls back to linear interpolation, which is
fine for an analysis display but sloppy. A proper polyphase resampler is an
afternoon.

**Swift build.** The app has not been compiled on a Mac. The C++ engine is
verified; the Swift layer is not. See `xcode/README.md` for the likely snags.

---

## Legal

**Before any commercial approach**, an hour with a patent attorney on:

1. **US 8,315,857** (Samsung, live to 2028-03-26) — spectral peak / tone /
   transient / noise trackers, Stephen a named inventor. The claims appear to
   require the full analysis→source-model→*modification* pipeline that a display
   does not perform, but claim construction is not a judgment call to make
   without counsel.
2. The old Audience **employment and invention-assignment agreements** — a
   separate question from patent freedom-to-operate, and the reason to ask
   sooner rather than later.

Full write-up in `IP-landscape.md`. The short version is that the filter itself
is free (US 7,076,315 lapsed in 2018) and nobody has ever patented a cochleagram
display.
