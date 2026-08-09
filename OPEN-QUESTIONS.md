# Open questions and things to return to

Running list. Nothing here blocks progress; all of it would make the result
better or more faithful to the original.

---

## Display fidelity

**De-skew reference.** Currently group delay from the analytic phase slope at
each tap's best frequency. Smooth and monotone, which is what matters — but on a
synthetic click it leaves 15 ms of spread across taps, where impulse-peak
alignment gives 1 ms.

The impulse-peak version is implemented (`which='delay'`) and *unusable as is*:
it picks the largest positive sample of an oscillating response, so neighbouring
taps land on different cycles of their own ringing. Across 599 taps it is
non-monotone in ten places and fifty times rougher in second difference (1.36 ms
rms against 0.027 ms, worst jump 20.8 ms). The jitter is bounded by each tap's
half-period — 10 to 23 ms at the apex — which tears the low end of the picture
apart.

*To try:* envelope-detect the impulse response (Hilbert, or a rectify-and-smooth
at a fraction of the tap's bandwidth) instead of picking a raw sample, then
smooth lightly across taps. That should land near impulse-peak accuracy with
group-delay smoothness. Worth an hour.

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
