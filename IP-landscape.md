# Cochleagram — IP Landscape

Research date: 2026-08-02. Sources are free public databases (Google Patents, Justia).
**Not legal advice.** Google's legal-status strings are explicitly labeled assumptions.
A clearance opinion for a commercial product needs a patent attorney and a paid
CPC-class search.

---

## Headline

The premise "all the relevant IP protection has expired" is **half right**.

- **The cochlea filter itself is free.** The Fast Cochlea Transform patent lapsed for
  non-payment of maintenance fees in 2018. The follow-on applications were all abandoned
  worldwide. Nobody owns the 60-filters-per-octave × 10-octave cascade.
- **Two live patents matter**, both now owned by **Samsung Electronics** (Audience →
  Knowles 2015 → Samsung Jan 2024). Neither claims a *display*, but one of them —
  on which **Stephen is a named co-inventor** — contains the tone/transient/noise
  tracker language and runs to March 2028.
- **Nobody has ever patented a cochleagram display.** Zero US patents contain the word
  "cochleagram." Lyon's 1985 Schlumberger patent described a "cochleagraph" display and
  expired in 2003, putting the basic concept in the public domain over twenty years ago.

---

## 1. Free and clear — the cochlea filter

### US 7,076,315 B1 — "Efficient computation of log-frequency-scale digital filter cascade"

**This is the Fast Cochlea Transform.** Lloyd Watts, sole inventor. Filed 2000-03-24,
granted 2006-07-11.

**Status: EXPIRED — Fee Related.** Maintenance fee reminder mailed 2018-02-19; lapse
recorded 2018-08-06 under 37 CFR 1.362. Nominal term would have ended 2020-03-24 anyway.
Never transferred to Samsung in the 2024 assignment batch — it was already dead.

Claim 1 recites the architecture directly: filter groups processing the signal "for a
particular frequency interval at a particular sampling rate," with **"same coefficients
used for processing audio signals that are a factor of a frequency interval apart,"**
and expressly **"10 octaves and each octave is processed by a filter group having 60
filters."** That matches your description exactly.

Foreign family: WO 2001/074118 (ceased), AU 2001245777 (abandoned).

<https://patents.google.com/patent/US7076315B1/en>

### US 2005/0228518 A1 and US 2005/0216259 A1 — "Filter set for frequency analysis"

Watts, priority 2002-02-13. Cascaded low-pass chains with downsampling after each chain.
**Both US applications abandoned.** EP 1474755 withdrawn, WO 2003/069499 ceased,
AU 2003216246 abandoned. Published in 2005, so they are usable prior art owned by nobody.

<https://patents.google.com/patent/US20050228518A1/en>

### US 6,792,118 B2 — "Computation of multi-sensor time delays"

Watts, priority 2001-11-14. **Expired 2022-08-12** (full term, fees paid throughout).

Relevant because claim 1 covers analyzing signals into frequency channels and
**"detecting a first feature occurring at a first time in one of the first signal
channels"** — the closest thing in the portfolio to a claim on per-channel spike
detection. It is dead. No claim mentions display.

### US 7,319,959 B1 — "Multi-source phoneme classification"

Watts, priority 2002-05-14. **Lapsed for non-payment, effective 2020-01-15.**

Claim 1 opens with "computing **600 spectral values on a logarithmic frequency scale**."
More usefully, the *specification* describes the system as "fully instrumented out for
**graphical inspection of cochlea, filterbank, cepstrum, context window, neural-network,
diphone, and word output**" — Audience's own visualization work, published, never claimed,
and now prior art against anyone who tries to claim it later.

---

## 2. Live patents — Samsung-owned

### US 8,150,065 B2 — "System and method for processing an audio signal"

Solbach & Watts, filed 2006-05-25, **active, expires 2028-10-14**. This is the one you
flagged.

All three independent claims recite the same four steps:

> filtering an input signal with a **complex-valued filter of a filter cascade**…
> filtering the first filtered signal with a **second complex-valued filter**…
> performing **phase alignment on one or more of the filtered signals using a complex
> multiplier**; and **summing the phase-aligned filtered signals to produce a
> reconstructed output signal.**

**It is a resynthesis claim, not a decomposition claim.** A tool that runs the cascade and
paints the result on screen performs the first two limitations and neither of the last two
— it never phase-aligns via complex multiplier and never sums to reconstruct an output
signal. Under the all-elements rule, omitting a limitation means no literal infringement.

The words *display, visualize, graphical, screen, image, render* appear nowhere in the
claims. "Noise" appears in no claim at all. Signal modification shows up only in dependent
claims 7, 9 and 16.

Sibling **US 8,934,641 B2** (active to 2030-01-12) is likewise a reconstruction claim.

<https://patents.google.com/patent/US8150065B2/en>

### ★ US 8,315,857 B2 — "Systems and methods for audio signal analysis and modification"

**Inventors: David Klein, Stephen Malinowski, Lloyd Watts, Bernard Mont-Reynaud.**
Priority 2005-05-27. **Active, expires 2028-03-26. Assignee: Samsung.**

This is the one that deserves an attorney's read, because it is where the
tone/transient/noise classification lives:

> **12.** …the feature extractor comprises a **spectral peak tracker**…
> **13.** …a **tone tracker** configured to determine feature segments associated with tones.
> **14.** …a **transient tracker**…
> **15.** …a **noise tracker**…

Those are all **dependent** claims hanging off system claim 10, which requires an
**"adaptive multiple-model optimizer"** with segment-grouping and source-grouping engines
producing "a source model parameter **for facilitating modification of an analyzed
signal**." Independent claim 1 similarly requires comparing observed against predicted
model parameters and configuring a source model to facilitate modification.

**Reading:** the trackers are not separately claimed. Infringement appears to require the
whole predictive multiple-model pipeline aimed at *modifying* audio. A display that
classifies taps only in order to color them, and never touches the signal, does not
obviously practice claim 1 or claim 10. No claim mentions display or GUI.

Caveats worth taking seriously: claim construction here is a real attorney call, not a
judgment call; the patent runs to March 2028; and being a named inventor confers no
ownership — Audience took assignment. Your old employment / invention-assignment and
confidentiality agreements are a separate question from patent FTO, and one where the
named-inventor status makes early counsel sensible.

Published application **US 2007/0010999 A1** (2007-01-11) describes this architecture
publicly.

<https://patents.google.com/patent/US8315857B2/en>

### Others, live, none claiming a display

US 7,508,948 (reverberation removal, to 2027-04-13) · US 8,345,890 / 8,867,759
(inter-microphone level differences) · US 7,979,275 / 8,032,364 (distortion measurement) ·
US 8,949,120 B1, US 9,119,150 B1, US 9,462,552 B1, US 9,830,899 B1 (adaptive noise
cancellation continuations — **claim sets not individually read**; flagged for counsel).

---

## 3. Display patents — the space is remarkably clear

Searches returning **zero** relevant results: `cochleagram` (no US patent or application
contains the word, anywhere), `"stabilized auditory image"`, `"auditory spectrogram"` with
a display limitation, `neurogram` + display, gammatone display, correlogram + cochlear
display, Audience/Knowles + display.

### The one live display patent worth knowing about

**US 10,108,395 B2** and **US 10,649,729 B2** — "Audio device with auditory system
display." Torrini & Limoni, priority 2016-04-14, active to 2036–2037, held by
individuals.

Claim 1 requires generating **"animated auditory system display data… wherein the
animated auditory system display data animates action of at least one element of an ear,"**
that element including a cochlea, and — critically — **"generating a simulated waveform
for each frequency component, based on the amplitude data and a simulated frequency that
is different from the component frequency."**

Two structural differences from a cochleagram, each apparently sufficient on its own:

1. It mandates a **substitute waveform at a frequency different from the real one** — a
   slowed-down animation the eye can follow. A cochleagram plots real envelope magnitude.
2. It animates a **picture of an ear or a cochlear spiral**. **Time is not an axis.** A
   scrolling time-vs-place raster is a different visual object.

**Design-around: don't draw a cochlear spiral, and don't synthesize slowed substitute
frequencies for animation.** Neither is something you'd want to do anyway.

### Richard Lyon's Google patent — not a threat

**US 8,463,719 B2** "Audio classification for information retrieval using sparse features."
Its spec describes computing a cochleagram then an SAI, but claim 1 is a retrieval claim
ending in **"ranking the audio files in response to a query including one or more words."**
No display limitation. A visualizer that never ranks files against a text query cannot
read on it.

### ★ The expired patent that helps you most

**US 4,536,844 A — "Method and apparatus for simulating aural response information."**
**Richard F. Lyon**, assigned to Schlumberger, granted 1985. **Expired 2003-04-26.**

Claim 1: filterbank → half-wave detection → cross-channel AGC compression → "providing
said electronic output signals to an **output utilization means**." The specification
expressly describes that output device as a **"cochleagraph,"** "operative to map the
time-dependent amplitude response of the simulated ear as a function of frequency," across
64 channels.

**A time-versus-cochlear-place display driven by an auditory filterbank was described in a
published US patent in the mid-1980s and has been public domain since 2003.** That is both
freedom to practice and strong invalidating prior art against anyone who later tries to
claim the basic idea.

<https://patents.google.com/patent/US4536844A/en>

---

## 4. Public-domain and open-source foundations

| Item | Date | Where |
|---|---|---|
| US 4,536,844 — Lyon, filterbank + AGC + "cochleagraph" | expired 2003 | [patents.google.com](https://patents.google.com/patent/US4536844A/en) |
| Lyon & Mead, "An Analog Electronic Cochlea," IEEE Trans. ASSP 36(7) | 1988 | [CaltechAUTHORS](https://authors.library.caltech.edu/records/d3vfn-fnn45) |
| Watts, "Cochlear Mechanics: Analysis and Analog VLSI," Caltech PhD thesis | 1993 | [CaltechTHESIS](https://thesis.library.caltech.edu/2802/) |
| Slaney, "Auditory Toolbox" (Apple TR #45; Interval TR 1998-010 v2) | 1993 / 1998 | [Purdue](https://engineering.purdue.edu/~malcolm/interval/1998-010/) |
| Lyon, *Human and Machine Hearing*, Cambridge UP — free full text | 2017 | [machinehearing.org](https://machinehearing.org) |
| **Google CARFAC**, Apache-2.0 | 2013, **v2 2024** | [github.com/google/carfac](https://github.com/google/carfac) |
| "The CARFAC v2 Cochlear Model in Matlab, NumPy, and JAX" | 2024-04 | [arXiv:2404.17490](https://arxiv.org/abs/2404.17490) |

**CARFAC is the significant one.** Cascade of Asymmetric Resonators with Fast-Acting
Compression — Lyon's modern cascade cochlea model, Apache-2.0, with Matlab, C++, NumPy and
JAX implementations, plus code for stabilized auditory images and pitchograms. Google even
publishes a **live in-browser cochlea-model visualization demo**:
<https://google.github.io/carfac/pitchogram_demo/index.html>

Two things follow. First, Apache-2.0 §3 carries an **express patent license grant** from
contributors covering claims necessarily infringed by the contribution — meaningfully
stronger cover than a bare MIT/BSD license. Second, a sophisticated patent-holding company
is openly practicing real-time cochlea-model visualization and asserting nothing, which is
both reassuring and further public prior art with a public date.

---

## 5. Spike detection and cross-tap phase comparison

The ideas — detect peaks per channel, compare phase or instantaneous frequency between
adjacent taps, use cross-channel phase coherence to separate tones from transients from
noise — are documented in public literature and expired patents going back to the 1980s.

**Expired patents:** US 6,792,118 (per-channel feature detection, expired 2022) ·
US 5,615,302 "Filter bank determination of discrete tone frequencies" (1997 — two adjacent
Gaussian bandpass filters as a ratio detector for instantaneous frequency; long expired) ·
US 6,477,214 "Phase-based frequency estimation using filter banks" (2002 — estimates
frequency from phase differences across filterbank channels; filed ~1999 so almost
certainly expired, **maintenance record unverified**).

**Academic, all pre-2000:** Licklider's duplex/autocorrelation theory (1951) · Flanagan &
Golden phase vocoder (1966), for instantaneous frequency as phase derivative · Lyon,
"A computational model of binaural localization and separation," ICASSP 1983 (correlogram,
cross-channel coincidence) · Slaney & Lyon, "A perceptual pitch detector," ICASSP 1990 ·
Slaney's Auditory Toolbox shipping correlogram and inter-spike-interval code (1993/1998) ·
Lyon, *Human and Machine Hearing* (2017), chapters 18–21.

The only live claim that gets near this is US 8,315,857 above, which appears to require the
full analysis → source-model → **modification** pipeline that a display does not perform.

---

## Summary

| Question | Finding | Confidence |
|---|---|---|
| Does US 8,150,065 cover a filterbank display? | **No.** Independents require phase alignment via complex multiplier *and* summing to a reconstructed output. Zero display language. | High — claims read verbatim |
| Is the Fast Cochlea Transform free? | **Yes.** US 7,076,315 lapsed 2018-08-06; the 2002-priority applications abandoned worldwide. | High |
| Any patent claiming cochleagram visualization? | **None found.** Zero US patents contain the word. The only live display family (Torrini/Limoni) requires an animated ear and substitute frequencies. | Medium-high — keyword search, not a CPC-class FTO search |
| Is the concept public-domain prior art? | **Yes, since the 1980s.** Lyon's expired US 4,536,844 describes a "cochleagraph"; CARFAC is Apache-2.0 with a live public demo. | High |
| Biggest residual risk | **US 8,315,857**, Samsung, live to 2028-03-26, spectral-peak/tone/transient/noise trackers, Stephen a named inventor. | Medium — claim construction is an attorney call |

### Open items for counsel

1. Doctrine-of-equivalents exposure on US 8,150,065 (analysis above is literal only).
2. Claim construction of US 8,315,857 claims 10 and 12–15 — is "facilitating modification
   of an analyzed signal" a true limitation of the system claim?
3. Four unread 2006-priority continuations: US 8,949,120, 9,119,150, 9,462,552, 9,830,899.
4. Maintenance-fee status of US 6,477,214.
5. Non-US family members (Samsung holds JP 5081903, KR 101294634, FI 20080623).
6. **Obligations under the old Audience employment / invention-assignment and
   confidentiality agreements** — separate from patent FTO, and the reason to talk to a
   lawyer sooner rather than later.
7. Professional confirmation of the section 3 negative results via a paid search over CPC
   classes G10L 25/18, G10L 21/10, G09B 21/009, H04R 25/00.
