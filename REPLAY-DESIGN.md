# RePlay — listening to what the picture shows

The display holds several seconds of sound as a picture. RePlay lets that
picture be heard: freeze it, mark a span with the measurement lines, and play
the audio those columns were drawn from.

"RePlay" is the name in the source only. Nothing shows it to the user, who sees
a button that says **Play Selection**.

This note is the contract between the two apps. Everything here has to be true
of both, because a feature that behaves differently in the browser than on the
Mac is a feature that cannot be used to compare them — which is the whole
reason there are two.

---

## Scope: live input only

The button exists only while the display is **paused from live input**. It is
never shown during file playback, or at the pause at the end of a file.

Playing a file already makes sound, and the file is on disk; a second way to
hear it would be two controls doing one job. So RePlay and file playback are
either/or, and never on screen together. That also disposes of every question
about how the two transports interact: there is no interaction.

---

## What is played

The **recorded input audio**, mono, at the input device's sample rate — not a
resynthesis of the cochleagram. The picture is the analysis; RePlay is the
thing that was analysed.

Output goes to the device and channel pair already chosen for file playback.
That popup previously mattered only when a file was playing; now it governs
both.

---

## The selection is the measurement lines

Both apps already anchor a hairline on mouse-down over a frozen picture and add
a second one on drag, stating the duration between them. RePlay reads that,
and adds nothing of its own:

| Measurement | What plays |
|---|---|
| none | the whole width of the display |
| anchor only, no drag | from that line to the right-hand edge |
| anchor and cursor | between the two lines |

A selection is therefore never a separate thing that can disagree with what is
drawn. Clearing the measurement (Escape) returns to the first row.

---

## Holding the audio

### A ring, filled from the display's thread

The audio thread does not touch the ring. `feedMono` pushes into a small
fixed-size single-producer/single-consumer queue — a couple of seconds is
ample — and the display link drains that queue into the ring on the same tick
that it drains the engine's columns.

This is the pattern the columns themselves already use, and it is here for the
same reason: the ring has to be resized when the geometry changes, and an
allocation on the audio thread is a dropped buffer. Sizing, growth and
indexing all happen on the main thread, where they are allowed to be
ordinary code.

### Frozen while paused

**Nothing is recorded while the display is paused.** This is not an
optimisation; two things depend on it.

The first is WYSIWYG across a seam. Live input cannot really be paused, only
ignored: the columns that arrive while the picture is frozen are thrown away,
and resuming butts together two moments that were never adjacent — which is
what the red seam line says. Freezing the ring at the same moment means the
ring skips exactly the interval the picture skips. Playing a selection that
spans a seam runs straight from the sample before the join to the sample
after, with no gap-handling code anywhere, because there is no gap. Saved
audio and drawn picture stay in step by construction rather than by
arithmetic.

The second is that the microphone is still open while paused. A ring that went
on recording would hear the playback come out of the speakers and overwrite the
very samples being played. For the same reason, resuming stops any playback
*before* it turns recording back on: stopping a graph is not instantaneous, and
the tail draining out of the speakers must not be recorded as though it were
the room.

Turning capture off does not empty the ring, so the consumer keeps draining and
discarding while it is off. Otherwise the samples pushed between the last drain
and the pause would sit there and be handed over on the first tick after the
resume — audio from before the join, delivered into the stretch that begins
after it, whose columns were thrown away.

### Sizing

The recording is trimmed to the oldest column still on screen, so it is as long
as the picture is wide and no longer. Trimming is amortised rather than done
every frame: dropping a few hundred samples off the front of a long recording
would move everything that survives, sixty times a second, so it waits until a
second's worth is dead.

A change of input sample rate starts the recording again. The picture is kept
across a device change when the tap count is unchanged, but audio recorded at
the old rate played back at the new one is pitch-shifted, so the recording is
the one thing that cannot be carried over.

No ceiling is imposed. The worst case is the coarsest Speed across a wide
window — 64 ms per column on 2560 columns is 164 seconds, which as mono float
at 48 kHz is 31 MB. That is not worth a policy.

---

## Indexing: by column, not by time

Each screen column carries the **engine column index** it was drawn from,
in an array parallel to `columnRefs` and shifted in exactly the same four
places: the resize path, the single-time-base append, the main region's
promotion, and the close-up strip's fill.

Indexing by elapsed time instead would be wrong, and quietly. The picture is
not wiped when the Speed detent changes — keeping what is already drawn is
worth more than the mixed scale costs — so the columns to the left of a scale
mark stand for a different number of milliseconds than those to the right.
There is no single ms-per-column that describes the display. There *is* always
a well-defined engine column behind every screen column.

Two things fall out of this for free:

- **The close-up needs no special case.** Its columns are engine columns one
  for one while the main picture aggregates several into each; if the mapping
  is by column, the violet line simply moves faster through the strip because
  the columns there are closer together in time. Nothing has to know about the
  boundary.
- **Scale changes need no special case**, for the same reason.

### De-skew, which moves the whole picture

A column is not made of the audio arriving as it is emitted. The cascade takes
time, and how much depends on De-skew:

- **De-skew on.** Every tap is held back to the slowest, so a column stands for
  one instant, uniformly the apex's travel time in the past — 186 ms at ERB 0.6,
  240 ms at 0.5. That is the largest single offset anywhere in the app, and
  ignoring it would play a fifth of a second later than the lines said.
- **De-skew off.** There is no one answer. The column holds each tap's own
  response to an event `gdelay[k]` ago, so it is a smear from the base's delay
  to the apex's — which is the slant De-skew exists to remove. **The base's
  delay is the number used**, a fraction of a millisecond, because the top of
  the slant is the leading edge: the first ink an event makes, and what the eye
  reads a click's position from. Everything lower on the picture is later, as
  the picture itself shows.

De-skew can be switched at any time and does **not** wipe what is drawn — it
marks a seam. So the columns on either side of that seam stand for audio at
offsets nearly two hundred milliseconds apart, and both have to keep working.
The offset is therefore a property of a stretch, exactly like the column rate,
and switching De-skew opens a new one.

One consequence is worth stating because it looks like a bug. Stretches are
ordered by column and monotone in column, but they are **not** monotone in
sample: turning De-skew on holds the picture back, so the stretch beginning at
the toggle starts from audio the previous stretch has already used. The two
genuinely overlap — that is what the seam is saying — so the map from sample
back to column walks *forward* from where the playback started and steps only
when the boundary expressed in the current stretch's own terms is passed.
Columns are contiguous across a boundary even when samples are not, which is
what makes that well defined. A selection spanning such a seam plays a little
less audio than its width suggests, for the same reason.

Turning De-skew **off** is the mirror image: the picture stops being held back,
so the audio between the seam and the new stretch's origin belongs to no column
at all. The line is clamped so that gap cannot send it backwards.

The other consequence: with De-skew on, the leftmost fifth of a second of a
freshly started recording was drawn from audio that predates the recording.
Both the sound and the line clamp to the oldest sample held, and it corrects
itself as soon as that much has been recorded.

**And the same thing at every resume, which is not fixable.** A column emitted
just after a resume depicts events from one lag earlier — during the pause,
which by design was not recorded. Those columns are mapped to the audio nearest
to them that does exist, which is the last lag-worth from before the pause. So
with De-skew on, the first fifth of a second after each seam plays sound that
belongs to the other side of it. The audio those columns depict was never kept,
so there is nothing else to point them at; the alternative would be to record
through pauses, which is the thing the whole design is built on not doing. With
De-skew off the same effect exists and is a fraction of a millisecond.

### From engine column to sample

The engine emits a column every fixed number of internal samples, so within one
run of recording the mapping is exact arithmetic:

```
sample = anchorSample + (g - anchorColumn) * samplesPerEngineColumn
```

A stretch's origin is `written - lag`: where the recording had got to when the
stretch began, less the display's lag from the section above. Folding the lag
into the origin rather than carrying it as a separate term keeps every mapping
downstream the same arithmetic it always was.

A new stretch begins when recording starts, at every resume, when the Speed
detent changes, and when De-skew changes. The resume case has to be there
because at the moment of a pause the audio already fed but not yet emitted as
columns is in the ring and will never be drawn — a fixed error, but one that
would accumulate across pauses if the mapping were never re-anchored. A stretch
per resume bounds it to one lag rather than summing them.

**The residual is not zero.** Within a stretch the alignment is exact; across
the start of one it is out by the engine's emission lag, a few milliseconds.
Stated here rather than hidden: it is below the width of one column at most
Speed settings, and removing it entirely would mean timestamping every column
through the engine, which is a much larger change than the error justifies.
(That few milliseconds is separate from, and much smaller than, the resume
effect described under De-skew above.)

---

## Behaviour

### The button

**Play Selection** → click → label becomes **Stop**, playback starts at the
beginning of the selection.

It is **stop, not pause**. Whatever ends a playback returns the label to
Play Selection, and the next one starts at the beginning of the selection
again. No resume point is remembered anywhere.

Playback ends when:

- **Stop is pressed.**
- **The selection runs out.** Reaching the end stops of its own accord.
- **The picture is clicked.** A click changes the selection, and the selection
  is the thing being played, so a click during playback is a Stop. The new
  measurement it begins is kept. Grabbing the close-up boundary counts as a
  click here: it clears the measurement as soon as it moves.
- **The display is un-paused.** Resuming starts the picture moving and starts
  the ring recording over what is being played. This is the one control that
  must interrupt playback.

### The violet line

A vertical line at the playback position, moving left to right, redrawn on the
display link.

The position is taken from the player node's *render* time, so the line leads
what is heard by the output device's own buffering — the same tens of
milliseconds any monitoring path costs. Stated because this project measures
that kind of offset elsewhere and should not be silent about one it has
introduced. Removing it would mean converting to the device's presentation
time, which is worth doing only if it turns out to be visible.

It **vanishes on stop** — it is not parked at the start of the
selection, because a stationary line on a frozen picture is indistinguishable
from a measurement line and says something different.

### Everything else stays live

Sensitivity, Range, Invert, Auto gain and Mode all behave exactly as they do
now, and none of them disturbs playback. They change how the picture is drawn;
playback is about what the picture was drawn *from*. The sound carries on while
the display is re-exposed underneath it.

Three things do stop it, and all three are cases where the sound would
otherwise stop meaning what the picture says:

- **Speed and Close-up** when the change retimes the bitmap, which wipes it.
  The columns the line was moving across no longer exist.
- **Narrowing the window**, if it takes the start of the selection off the left
  edge. What is drawn is right-aligned, so this is reachable while playing.
- **ERB**, which rebuilds the engine — and on live input that goes through the
  same path as starting the microphone, so it also resumes the display. That is
  existing transport behaviour, not something RePlay chose; it is written down
  here because the effect on a frozen picture is surprising and worth deciding
  about separately.

### When the picture and the recording lose each other

Anything that stalls the display link — a minimised window, a fully occluded
one, a heavy load — leaves both rings unread. They are different depths and
drop independently, so what survives in one no longer lines up with what
survives in the other. The picture already marks that as a seam; the recorder
notices the same event, throws away what it cannot place, and re-anchors. The
audio behind the seam is lost rather than silently misplaced.

---

## The controls

A group of two, **immediately after the ERB and Mode popups**, with a divider
on each side:

```
Pause | ERB  Mode | [Play Selection]  [====volume====] | Play File  <name> ...
```

The left-hand divider is the one already there.

**Volume** is an unlabelled slider of the same build and width as Sensitivity
and Range. No numeric readout, for the same reason those have none: it is set
by ear.

- Range **−40 to +12 dB**, default **0 dB** — unity, so that by default what
  you hear is the level the microphone heard.
- The bottom of the travel is **silent**, not −40 dB.
- Gain above unity earns its place because a microphone recording often sits
  well below full scale and nothing else in the app can lift it. Anything that
  then exceeds full scale clips at the device, audibly — which is the right
  thing for an instrument to do, rather than compressing quietly and pretending
  to headroom it has not got.
- Persisted, in the shared defaults list, and restored to 0 dB by the
  **Defaults** button.

The whole group is hidden, not disabled, when it does not apply.

---

## Defaults, restated

RePlay adds one entry to the list both apps must agree on and first launch must
match:

> De-skew off, Invert off, Auto gain off, Sensitivity 95, Range 170, Close-up
> off, Mode Amplitude, ERB 0.6, **Volume 0 dB**.

---

## What the browser will do differently

The engine, the pause semantics and the measurement lines are already the same
there, so the design carries over unchanged. Two mechanical differences:

- The ring is filled from the capture worklet's messages rather than from a
  tap, so the SPSC queue is the worklet port and no extra queue is needed.
- Playback is an `AudioBufferSourceNode` through a `GainNode`, and the output
  device is whatever the page is using — there is no device popup to honour.

Neither changes anything above.
