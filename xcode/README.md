# Real-time cochleagram (macOS)

600-tap cochlea cascade, 20 Hz to 20 kHz, one tap per pixel row, scrolling live.

## Build and run

**Open `Cochleagram/Cochleagram.xcodeproj` in Xcode and press Run.** That is the
working setup: a real app target, so the bundle, `Info.plist` and entitlements
are all in place, microphone permission behaves, and `Log.say` output lands in
Xcode's console where it can be copied.

The C++ core is compiled straight into the app target and reached through a
bridging header rather than a module, which keeps the whole thing to one target
with no package resolution.

**Adding a source file.** The project file is generated rather than managed by
Xcode, so a new file is invisible to the build until it is registered. Either
drag it into the project in Xcode as usual, or:

```
./add_source.py Sources/CochleagramApp/Whatever.swift
```

The SwiftPM package still works (`./make_app.sh`) and is what the command-line
`selftest` builds against. Sources compile under both: `#if SWIFT_PACKAGE`
picks the module import and the resource-bundle lookup.

### Command line

```
cd Cochleagram
./make_app.sh
open Cochleagram.app
```

`make_app.sh` generates the coefficient files if they are missing, builds with
SwiftPM, then wraps the executable in an app bundle. The bundle is not
cosmetic: macOS will not grant microphone access to a bare executable, because
the permission prompt needs `NSMicrophoneUsageDescription` from an `Info.plist`.

### If it asks for microphone permission every time

macOS grants microphone access to a **code signature**, not to a path. An ad-hoc
signature (`codesign --sign -`) has no stable identity — its cdhash changes with
every build — so TCC sees a brand new application on each rebuild and asks
again. Nothing you do in System Settings will make that stick.

The fix is a real certificate, and a free one is enough: Xcode → Settings →
Accounts → add your Apple ID → Manage Certificates → **+** → Apple Development.
`make_app.sh` finds it automatically on the next run and reports which identity
it used. Then delete the stale Cochleagram entries under Privacy & Security →
Microphone and grant once; it will hold from then on.

To force a particular identity: `CODESIGN_ID="Apple Development: you@example.com" ./make_app.sh`

To work on it in Xcode, open the `Cochleagram` folder (Xcode reads
`Package.swift` directly). Running from Xcode gives you a bare executable, so
live input will not work — use **Open File…** there, or run the bundle for mic
input.

## Layout

```
Cochleagram/
  Package.swift
  make_app.sh                     build + bundle
  Info.plist                      mic usage description
  Sources/
    CochleaDSP/                   the engine. plain C++, no Apple frameworks
      include/cochlea.h           C ABI
      cochlea.cpp
    CochleagramApp/               the macOS app
      main.swift
      AppDelegate.swift           window, controls
      Settings.swift              the controls, remembered between launches
      InputUnit.swift             AUHAL capture: live input
      AudioSource.swift           routes live input or file to the cascade
      Cochlea.swift               Swift face of the C API
      CochleagramView.swift       scrolling bitmap
      RangeSlider.swift           two-knob slider; unused since Sensitivity
                                  and Range replaced white/black
      Resources/cochlea_88200_erb{050..130}.coch
  tools/selftest.cpp              run the engine off-line, write a PGM
```

The engine deliberately has **no dependency on AppKit, AVFoundation or
CoreAudio**, and a C ABI rather than a C++ one. It compiles and runs on Linux;
it will drop into an AU or VST build, a command-line tool, or somebody else's
application without modification. That was the point.

## Controls

Two rows, grouped by how often you touch them. The upper row is what you set
for a session; the lower row is what you move while watching a picture.

**Upper:** ERB · De-skew │ Play File · *filename* … ↻
**Lower:** Invert · De-skew │ Speed · Close-up │ Sensitivity · Auto gain │ Range

| | |
|---|---|
| ERB | filter bandwidth, 0.5 to 1.3 × one ERB |
| De-skew | compensate travelling-wave delay (costs ~186 ms of latency) |
| **Play File** | pause, then choose an audio file and play it |
| **↻** | replay the last file; appears only once one has played through, at the right-hand end of the row |
| Invert | white-on-black instead of ink-on-paper |
| Sensitivity | how faint a sound the display can show; right is darker |
| Auto gain | move Sensitivity automatically, aiming at ~30% mean ink |
| Range | how many decibels lie between white and black |
| Speed | fifteen detents, 0.5 to 64 ms per column |
| **Space** | play / pause |
| **`[`** / **`]`** | one Speed detent slower / faster |

One row ran to about 1100 points once everything was in it, which set a floor
on how narrow the window could be for no reason but arrangement. Two rows put
the minimum content width at **640**, and vertical space was never scarce.

**Speed** is a row of radio buttons rather than a slider, because the useful
settings are a few ratios apart and a slider both makes you hunt for them and
lands you between them. Fifteen detents divide 0.5 to 64 ms — a range of 128×,
seven octaves — into fourteen steps of **half an octave**, a ratio of √2:

```
64  45.3  32  22.6  16  11.3  8  5.66  4  2.83  2  1.41  1  0.71  0.5 ms
```

Half an octave is the useful size because it puts every power of two on the
grid — 0.5, 1, 2, 4, 8, 16, 32, 64 — with one detent between each pair. So the
old 4 ms default is still exactly reachable, and two presses of a bracket key
is exactly a doubling.

They run widest-first, so the scroll gets faster to the right, which is what
the label promises, and the bracket keys move the selection the way they point.
**Changing the speed does not wipe the picture** — new columns simply start
arriving at the new rate, so the image holds two scales at once. A **blue
vertical line** marks where the change happened, because widths either side of
it are not comparable; like the red seam it is anchored to the audio and
scrolls away with it.

All settings, and the window's size and position, are remembered between
launches. The pause state is not — it belongs to a particular sound, not to the
way you like the display set up.

**Settings** (⌘,, from the Cochleagram menu) holds what you set once and then
leave alone: the input device and its format, the status line, and **Reset
Settings**. The toolbar is for what you adjust while looking at a picture, and
it has to fit in a narrow window. That leaves the app menu with three items —
Settings, Hide, Quit.

One consequence worth knowing: messages that used to be permanently visible now
only appear when Settings is open. "Microphone access denied" is the one that
matters, and it also raises an alert, so it is not lost — but transient
feedback like "4.00 ms/column" is only there if you are looking.

**There is no "Live Input" button.** The app starts listening to the system
default at launch, and the device menu is the single control for live capture —
choosing a device starts it, and choosing the device you were on before is how
you come back from a file. There used to be a button as well, and the two
disagreed: it ignored the menu and reopened the system default, so the menu
went on displaying a device that was not the one being captured. One control
cannot contradict itself.

**Play File pauses before it opens the panel.** A modal file panel runs its own
event loop, so the display stops for as long as it is up whatever we do —
which looked like a stall. Pausing on purpose first leaves the red seam a pause
always leaves, so the gap is accounted for rather than unexplained. Dismissing
the panel without choosing anything puts the pause state back the way it was —
the pause was the button's doing, not yours, and should not outlive a decision
not to open anything. The seam stays either way: time really did jump while the
panel was up, whether or not a file came of it.

Pausing does different things to the two sources, deliberately. A **file** is
genuinely paused — the player stops, nothing is produced, nothing is lost.
**Live input** cannot be paused, so the display freezes and incoming columns are
discarded; when you resume you are looking at now, not at a backlog.

When a file reaches its end the display stops and holds the last screenful, and
a **green vertical line** marks where the recording ran out. Anything the
player renders after that is silence, and it is discarded rather than queued —
otherwise it would scroll the end of the file away behind a wall of blank
columns. Space then has nothing to resume, so it returns to live input on
whichever device the menu is showing, **without erasing the picture**: the
file's cochleagram stays where it is and the microphone scrolls in from the
right, exactly as it does after a normal pause.

**Sensitivity and Range** set the level-to-grey window between them:
Sensitivity is where its middle sits, Range how wide it is. Neither has a
numeric readout — they are set to taste, by looking at the picture.

Sensitivity is the *negated* midpoint, so that further right is more sensitive,
more ink, a darker picture. **Auto gain** drives it, aiming to keep the average
pixel about 30% of the way to full ink; while it is on, the control reports
what the controller is doing rather than accepting instructions, and switching
it off hands the knob back exactly where the controller had got to, so the
picture does not jump. Range is yours either way — it is the one exposure
control Auto gain does not touch.

This is the third shape of the setting. Gain and Level came first, and set
*where* black was and *how far below it* white fell, so moving one end moved
the other. White and black replaced them and did read directly — but two ends
of one scale collide: they cannot cross, they need a minimum separation, and
the guard enforcing it has nowhere to push once one end is against a limit. In
the browser version that guard failed silently and produced a one-decibel
window: a picture with no grey in it at all. A midpoint and a width cannot
interact, and unlike Gain and Level the span here is a control rather than a
consequence of two others.

**Sensitivity, Range, Invert and Auto gain re-expose the whole picture**, not just
the columns still to come. The engine emits levels in dB and the view keeps
them — about 3.6 MB for a screenful — so the grey bitmap is only a cache of how
those levels currently look. Moving a control recomputes it: a subtract, a
scale and a clamp per pixel, no logarithm, a millisecond or two for the whole
screen. That is what makes adjusting the exposure feel continuous, and it works
with the display frozen at the end of a file, when there are no new columns at
all. The engine never produces pixels; mapping level to grey needs a reference
and a floor that only the display knows.

Four colours of vertical line, all anchored to the audio and scrolling away
with it, and drawn over the picture rather than into it — so re-exposing never
disturbs them:

| | |
|---|---|
| red | a **seam** — time jumps here, because live input was paused or columns were dropped |
| blue | the **speed** changed here, so widths either side are not comparable |
| violet | the **tuning** changed here, so frequency resolution differs either side |
| green | a **file ended** here |

One line per column, first claim wins: a file ending and the microphone coming
back land on the same column, and green is the more specific statement.

That second case leaves a **seam**: two moments that were never adjacent, drawn
side by side. A red line marks it, so the picture never claims a continuity it
does not have. Seams are anchored to the audio rather than to the screen, so one
scrolls away with the join it belongs to. Pausing a file produces no line,
because nothing was lost.

Keys are handled by a local event monitor rather than the responder chain,
because the toolbar buttons would otherwise swallow the space bar.

## Design

**Calibration is a build step, not a runtime one.** Working out the per-stage
damping and pole frequencies takes twenty iterations of measuring the analytic
cascade response — a few seconds, and no business happening at app launch.
`prototype/export_coeffs.py` bakes the result into a 44 KB binary that the
engine reads. The C++ contains no design logic at all, only the filter.

**Internal rate is 88.2 kHz.** The top taps need to sit far enough below Nyquist
to behave at 20 kHz, so host audio is interpolated 2× by a 16-tap half-band FIR
(44.1 → 88.2 and 48 → 96 are both exact 2×; other rates fall back to linear
interpolation, fine for an analysis display).

**Live capture does not use AVAudioEngine.** It was measured delivering **0.29×
real time** — three callbacks a second of 4410 frames each, seventy percent of
the audio never arriving. That made the time axis wrong by a factor of three,
the scrolling lurch three times a second, and the latency wander between half a
second and a second. The cause is structural: AVAudioEngine drives its graph
from the *output* device, so captured audio must cross the boundary between two
independently clocked devices before a tap can see it, and the engine picks the
buffer size. Neither is reachable through its API.

`InputUnit.swift` is a HAL input unit instead — one device, that device's own
clock, no output side, and a buffer size we ask for (256 frames, 5.8 ms at
44.1 kHz). File playback still uses AVAudioEngine, which is the right tool for
it: the file has to be audible, and latency does not matter when the sound and
the picture come from the same player.

**Redraw follows the screen.** A 60 Hz timer is locked to nothing and beats
against the refresh, so the scroll advances by an uneven number of columns per
frame — judder no matter how evenly the audio arrives. On macOS 14 and later a
display link drives it instead; earlier systems keep the timer.

**Tuning is chosen, not computed.** The **ERB** menu sets filter bandwidth as
a multiple of one ERB — Glasberg & Moore's equivalent rectangular bandwidth,
which is what human auditory filters measure. Placing the poles to hit a given
bandwidth takes a twenty-iteration fit, so each value is a separately baked
coefficient file and the menu simply loads one; changing it restarts the source,
because handing a new engine to a running audio thread is not safe.

1.0 is the faithful setting and it has a hard consequence: on a 132 Hz voice it
can produce ripple between harmonics only up to about the **sixth**, because
above that the excitation pattern is genuinely flat — no contrast curve can
recover what is not there. 0.7 reaches the tenth. Sharper than one ERB is more
legible and less true, and which you want depends on what the picture is for.

Two costs to know about. Sharper filters ring longer, so de-skew latency rises
from 183 ms at 1.0 to **242 ms at 0.5**. And the apex still drifts at the broad
end: the lowest tap lands at 20.1 Hz for 1.0 but 18.0 at 1.1 and 14.2 at 1.3 —
the same accumulated-cascade weakness that shows up in the tap spacing there.

**The solver under-relaxes in proportion to the target.** Bandwidth gets more
sensitive to damping as Q rises, so a step size tuned at one ERB overshoots
below it: 0.5 used to ring along the channel axis, with taps between 2 and
16 kHz landing anywhere from 0.79 to 3.7 times their target, and *more*
iterations making it worse. Scaling the step by `erb_scale` leaves 1.0 bit for
bit unchanged and cuts the error at 0.5 by a factor of 3.6. The loop also keeps
its **best iterate** rather than its last, scored on bandwidth and frequency
placement together, so `iters` can no longer make the answer worse:

| scale | 0.5 | 0.6 | 0.7 | 0.8 | 0.9 | 1.0 | 1.1 | 1.2 | 1.3 |
|---|---|---|---|---|---|---|---|---|---|
| before | 0.302 | 0.215 | 0.106 | 0.049 | 0.031 | 0.026 | 0.021 | 0.023 | 0.055 |
| after | 0.085 | 0.054 | 0.042 | 0.029 | 0.026 | 0.026 | 0.021 | 0.023 | 0.064 |

(rms bandwidth error in octaves.) Scoring both objectives matters: bandwidth
alone once picked a 1.3 design whose lowest tap sat at 78 Hz instead of 20 —
two octaves of display traded for a slightly better width fit.

**Cost.** 629 stages at 88.2 kHz is 55 M stage-updates/s. Measured throughput of
this loop is around 320 M/s on one core, so the cascade costs roughly **17% of a
single core** — see `prototype/bench.py`.

**Threading.** `cochlea_process()` is real-time safe: no allocation, no locks, no
syscalls. Finished display columns go into a lock-free single-producer /
single-consumer ring; the view drains it at 60 Hz. `cochlea_dropped_columns()`
should stay at zero.

**De-skew is display-only** and applied at the last possible moment. The
travelling-wave delay — 0.5 ms at the base, 186 ms at the apex — is real
information about which taps fired first, and flattening it before analysis
would destroy exactly the cross-tap timing a mode classifier needs. In real time
the correction can only *hold the fast taps back*, never advance the slow ones,
so switching it on costs about 186 ms of display latency. That is the honest
price and it is why there is a checkbox.

## Verification

The engine is portable C++, so it can be checked without a Mac:

```
cd Cochleagram
c++ -std=c++17 -O2 -I Sources/CochleaDSP/include \
    tools/selftest.cpp Sources/CochleaDSP/cochlea.cpp -o selftest
./selftest Sources/CochleagramApp/Resources/cochlea_88200_erb100.coch \
    input.f32 44100 out.pgm 4.0 -35 1
```

`input.f32` is raw little-endian mono float32. Against the Python prototype on
the same audio, the C++ core matches at **0.96 correlation and 2% mean pixel
difference**, the residual being the different resampler. `figures/py_vs_cpp.png`
is that comparison.

## Status

The C++ engine is compiled, run, and verified against the Python reference.
The Swift layer went through one round of build fixes; a second may be needed.

### Fixed in round one

- **`OpaquePointer`, not `UnsafeMutablePointer`.** `CochleaEngine` is declared
  in the header and never defined, so Swift imports every `CochleaEngine *` as
  `OpaquePointer`. The handle passes straight through; converting it is not
  merely unnecessary but uncompilable (`generic parameter 'Pointee' could not be
  inferred`). This was every call site in `Cochlea.swift`.
- `import UniformTypeIdentifiers`, needed for `NSOpenPanel.allowedContentTypes`.
- `Timer.scheduledTimer` followed by `RunLoop.add` registers the timer twice;
  build it with `Timer(timeInterval:)` instead.
- `removeTap` on a node that has no tap throws, so the tapped node is now
  remembered rather than both being cleared blindly.
- The view is **not** flipped. In a y-up context `CGContext.draw` puts a
  CGImage's first row at the top of the rect, and row 0 is tap 0, the highest
  frequency. Flipping the view would mirror the display; the frequency grid
  inverts its own coordinate to match.

Good news from that round: `import CochleaDSP` worked, so Swift is happy
importing the C header out of a target containing C++ sources — the snag that
looked most likely in advance did not materialise.

### Still possible

- `Bundle.module` resource lookup, if the resource lands somewhere other than
  where `make_app.sh` copies it.
- `AVAudioEngine.mainMixerNode` taps during file playback can be fussy about
  format; tapping the player node directly is the usual workaround.
