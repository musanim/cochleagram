# Cochleagram prototype

A working reference implementation: cascade cochlea filterbank, spike
extraction, interval analysis, mode classification, rendering.

```
pip install numpy scipy matplotlib numba
python3 make_figures.py            # writes ../figures/*.png
python3 probe.py                   # feature statistics against known ground truth
python3 diagnose.py                # filterbank tuning measurements
```

First run takes ~40 s (numba compilation plus filterbank calibration); the
calibration is cached in `.cache/`.

## Files

| | |
|---|---|
| `cochlea.py` | Filter cascade, automatic damping calibration, spike extraction |
| `analysis.py` | Interval rasterising, cross-tap agreement, mode classification |
| `render.py` | Cochleagram and FFT spectrogram panels |
| `signals.py` | Test signals chosen to expose the differences from an FFT |
| `make_figures.py` | Builds the comparison figures |
| `probe.py` | Measures classifier features on signals with known ground truth |
| `diagnose.py` | Measures realised bandwidth, gain and group delay per channel |

## How it works

**Cascade.** Audio enters at the basal (high-CF) end and ripples down a chain of
two-pole/two-zero asymmetric resonators, one per tap, 60 taps per octave. Each
stage has unity DC gain, so low frequencies pass through untouched while each
stage progressively removes content above its own characteristic frequency. The
output at stage *k* is bandpass at CF_k with a steep high-side skirt and a
shallow low-side tail — the asymmetric shape real cochlear tuning has, and the
reason a low-frequency tone still drives every tap above it.

**Automatic calibration.** Tuning in a cascade is cumulative: bandwidth at a
place depends on every stage basal to it. Put 60 stages in an octave instead of
the ~15 a conventional design uses and each must contribute proportionally less,
or the cascade runs away — at the textbook damping of ζ = 0.1, 60 taps/octave
produces peak gains around 10¹⁹ and 400 ms of group delay at the apex.

`cochlea.calibrate` measures every channel's realised bandwidth from the
cascade's own impulse response and iteratively adjusts per-channel damping until
each channel is one ERB wide at its best frequency. It converges to within 2% in
about a dozen iterations, four seconds. This replaces hand-tuning and means the
filterbank matches human tuning by construction at whatever tap density you ask
for.

It also relabels each channel by its *measured* best frequency: at the apex the
accumulated cascade pulls the response peak well below the pole frequency, so
the pole frequency is not the frequency the channel reports.

**Spikes.** Hair-cell output is reduced to positive local maxima of each tap's
waveform — a time and an amplitude. That is the entire representation passed
downstream. No instantaneous phase, matching the original real-time system.

**Interval analysis.** For each tap, the interval to the preceding spike. Two
quantities are derived by comparing a tap with its neighbours:

- **Tone agreement** — do neighbouring taps report the *same absolute interval*?
  They do when one periodic driver dominates a whole region. Because the cascade
  has a shallow low-side skirt, a tone at *f* drives every tap above *f*, so this
  signature is spatially extensive and very strong.
- **Transient agreement** — does each tap report *its own* CF? That is what
  independent ringing after a common excitation looks like.

Both are computed as the weighted fraction of neighbouring taps that agree with
the centre tap, rather than as a variance: a variance is wrecked by one outlier
tap locked to a neighbouring harmonic, whereas a disagreeing tap simply doesn't
vote.

The comparison window is measured in **ERBs, not octaves**, so it is narrow at
the top of the cochlea and wide at the bottom. This matters — a fixed
octave-wide window straddles two resolved harmonics of a low note, sees taps
locked to different partials, and calls a plainly tonal region noise. One ERB is
exactly the width at which the ear stops resolving neighbouring partials, so it
is the right scale on which to ask whether nearby taps agree.

**Mode classification.** Tone comes from tone agreement gated by interval
regularity. Distinguishing transient from noise needs a separate cue: measured on
the test signals, a tap fed narrowband noise rings near its own CF with almost
exactly the interval statistics of a tap ringing after a click (see `probe.py`
output). What separates them is that a transient is a *common event* — all taps
in a region rise together, sweeping apically with the travelling wave — whereas
in noise each tap's envelope wanders independently. Averaging the **signed**
envelope slope across taps therefore keeps transients and cancels noise. The mark
is then held for each tap's own ring-down time, ~1/ERB, which is 2 ms at 4 kHz
and 35 ms at 50 Hz — and is exactly the comet-shaped smear a click makes.

## Open questions

- The mode colouring is a reconstruction, not a reproduction. The original
  discriminator is known to have been interval-based, but the exact rule is not
  recorded. Needs a look from someone who used the original display.
- Travelling-wave group delay is not compensated. Real, but it means a click's
  signature curves rather than standing vertical. Whether to de-skew is a design
  decision.
- Currently top-limited to fs/8. Full 20 Hz–20 kHz coverage wants either a
  higher sample rate or the multirate structure of the original (US 7,076,315),
  which runs each octave at half the rate of the one above and shares
  coefficients between octaves. That is also where the real-time speed comes
  from.
