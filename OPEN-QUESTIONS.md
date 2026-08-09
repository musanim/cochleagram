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

The earlier attempt failed because it picked the largest peak, and because the
"ignore numerical dirt" threshold was set at a tenth of each tap's maximum --
high enough to skip to the second peak above 113 Hz and the third above 334.
It is now 1e-5, which selects nothing and only guards.

What remains:

* **A one-pixel staircase along the leading edge.** Inherent, not a bug: the
  de-skew history is a per-column ring, so shifts are a whole number of columns
  and each tap's sub-column remainder survives. Bounded by one column at any
  Speed. Removing it means interpolating between columns on the de-skew read,
  which would blur the one thing this display refuses to blur.
* **Sharp tunings are still not monotone.** The calibrated delay steps
  *backwards* by 4.5 ms at 305 Hz at ERB 0.6 and 10.5 ms at 137 Hz at ERB 0.5 --
  a few taps latching a different peak from their neighbours. ERB 1.0 and above
  are clean. A median over five taps would fix it and cannot hurt the tunings
  that are already smooth. Untried.
* A related clamp bug is fixed: `kMaxDeskewColumns` was 256, which covers a
  second at 4 ms columns and 12 ms at 0.05 ms ones. At fine Speeds every tap
  above a crossover frequency got the *same* hold-back instead of one growing
  with frequency, so the picture kept its skew and merely moved. Now 4096.

`xcode/Cochleagram/tools/skew.cpp` and `tools/leadedge.cpp` measure all of this
without a Mac.

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
