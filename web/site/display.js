// The picture.
//
// A port of the Mac app's CochleagramView, and deliberately the same shape:
// one tap per pixel row, no vertical interpolation anywhere, the levels kept
// in decibels so that changing the exposure re-renders what is already on
// screen instead of only affecting what arrives next.
//
// Storage follows the Mac app for the same reason it does there. Levels and
// coherence are **column-major** -- all `taps` values of a column contiguous --
// so appending is one copy and scrolling is one `copyWithin`. The bitmap has
// to be row-major because that is what ImageData is.

/// What an untouched column reads: far below any usable floor, so a buffer
/// that has been allocated but not filled renders as silence.
const SILENT_DB = -600;   // matches kTinyLevel in cochlea.cpp
const NO_COHERENCE = -1000;

/// The playback line. Violet: far enough from the orange of the measurement to
/// be told apart at a glance, and from the red seam and the green end-of-file
/// mark. The same number as `CochleagramView.playheadInk`.
const PLAYHEAD_INK = 'rgb(140, 61, 242)';

/// How tall the picture is, in CSS pixels, whatever else is on screen.
///
/// 599 taps into 600 rows is one tap per pixel and no vertical resampling,
/// which is the whole point -- harmonics sit one or two taps apart and
/// interpolation destroys exactly that. The Mac app has no such guarantee: its
/// picture is scaled to whatever the window leaves, so there the waveform strip
/// takes a sixth of the space and the picture makes do with the rest. Here it
/// cannot, so the canvas grows instead. The stylesheet's height for `#view`
/// is this plus the two insets, and is the value that shows before this file
/// has run; after that this owns it.
const PICTURE_HEIGHT = 600;

/// The waveform strip's height.
///
/// The Mac gives the strip a sixth of the space it and the picture share, which
/// is a fifth of the picture at any window size. The picture here is a fixed
/// 600 rows, so that fifth is a fixed 120 -- the same proportion, arrived at
/// from the other end.
const WAVEFORM_HEIGHT = 120;

/// Narrowest the picture may be squeezed by the spectrum, in CSS pixels. Only
/// reached on a window too small for the share to be meaningful; the drag has
/// its own, wider limits.
const MIN_PLOT_WIDTH = 120;

/// Where the spectrum's boundary may be dragged to, as a share of the width the
/// picture and the spectrum divide between them. Five per cent is a sliver
/// worth keeping draggable rather than a width worth having; a half is where
/// the Mac's window sits, and past that the picture is being read against the
/// readout instead of the other way round.
const SPECTRUM_SHARE_RANGE = [0.05, 0.5];

/// How long the spectrum's smoothing takes to close the gap to 1/e of a step.
///
/// A single column is one instant of a peak-following analysis, and sixty of
/// them a second is more movement than an eye can read -- the shape boils. This
/// is the only thing between the numbers and the drawing, and it is a display
/// convenience: the picture beside it is unsmoothed, and remains the thing to
/// measure from. Thirty milliseconds, arrived at by looking.
const SPECTRUM_DECAY = 0.030;

// ---- the waveform strip's gain ------------------------------------------
//
// The Mac app's four constants, arrived at there by looking rather than by
// reasoning. They have to stay identical to it: the two programs drawing the
// same sound at different heights would make the strip unreadable as a
// measurement. The reasoning behind the controller they belong to is in the
// class, under "the waveform strip".

/// How quickly the scale is allowed to *grow* -- which shrinks the shape.
/// Quick, because that is the direction that prevents clipping: a sound that
/// has just got louder needs the room immediately.
const WAVEFORM_SCALE_UP = 0.05;
/// And how slowly it may *shrink*, which enlarges the shape.
///
/// The slow one, and this is the direction that matters. The cochlea's low taps
/// ring for a good fraction of a second after a burst has stopped, so when the
/// sound ends the excursion falls away at once while the ink does not. The
/// ratio between them therefore dives, the gain shoots up, and whatever quiet
/// material follows -- along with the loud part still on screen -- is drawn far
/// too large. Refusing to follow that quickly is the whole of the fix, and it
/// is the opposite of what an AGC usually does.
const WAVEFORM_SCALE_DOWN = 3.0;
/// Headroom. The rule says a black picture fills the strip; in use it
/// overflowed too often, because the darkest tap anywhere in a batch reaches
/// black long before the picture as a whole looks black. At 1.28 a
/// black-rendering sound draws at about four fifths of the strip. One is the
/// floor of this number, not a target: there a black-rendering sound exactly
/// fills the strip and anything darker clips.
const WAVEFORM_HEADROOM = 1.28;
/// A floor under the divisor, so the gain cannot run away on a picture with no
/// ink in it. It is *not* the "white picture draws a flat line" case: on the
/// default window a quiet room's taps sit well up the grey scale, and a picture
/// faint enough to reach this floor is one nothing audible produces. The flat
/// line is what silence gives by having no excursion rather than by having no
/// ink.
const WAVEFORM_MIN_INK = 0.02;

/// One expression, used both for what the controller is holding and for what it
/// is aiming at -- or the comparison that picks the coefficient would be
/// against a different quantity from the one it moves.
function fullScale(excursion, ink) {
    return excursion / Math.max(ink, WAVEFORM_MIN_INK) * WAVEFORM_HEADROOM;
}

export class Display {

    constructor(canvas) {
        this.canvas = canvas;
        this.ctx = canvas.getContext('2d', { alpha: false });

        this.taps = 0;
        this.frequencies = null;
        this.width = 0;                    // columns on screen

        this.levels = new Float32Array(0);
        this.coherence = new Float32Array(0);
        this.refs = new Float32Array(0);
        /// The input's smallest and largest sample under each screen column --
        /// what the waveform strip draws. They come from the engine already
        /// delayed by the same amount de-skew holds the taps back, so a column
        /// of strip stands over the column of picture it belongs to whatever
        /// de-skew is set to, and across a change of it, with nothing here
        /// compensating. Shifted wherever `refs` is shifted.
        this.columnLo = new Float32Array(0);
        this.columnHi = new Float32Array(0);
        /// Which engine column each screen column was drawn from, or -1 where
        /// nothing has been drawn. What RePlay needs to turn a position on the
        /// picture back into a position in the recorded audio, and the only
        /// coordinate that survives the two things the picture routinely does
        /// to its own time base: it is not wiped when Speed changes, so the
        /// columns either side of a scale mark stand for different numbers of
        /// milliseconds; and with the close-up open there are two time bases on
        /// screen at once by design. There is always exactly one engine column
        /// behind every screen column. See REPLAY-DESIGN.md.
        ///
        /// Doubles, not Int32: at the close-up's finest setting the engine
        /// makes twenty thousand columns a second, and integers stay exact in a
        /// double far longer than a session can last.
        ///
        /// Shifted wherever `refs` is shifted, being anchored to content in the
        /// same way.
        this.fine = new Float64Array(0);
        /// Bumped whenever the engine-column numbering starts again, which is
        /// whenever the picture is wiped. Anything still holding a column index
        /// from before the bump is holding a number that now names other audio.
        this.contentEpoch = 0;
        /// Playback position as an engine column, or null when nothing is
        /// playing.
        this.playhead = null;
        /// Something has changed what a playback would be playing -- a click
        /// that begins a measurement, or a grab of the close-up boundary, which
        /// clears the measurement as soon as it moves. Either is a Stop.
        this.onSelectionDisturbed = null;

        // The bitmap lives on its own canvas so it can be blitted in one call
        // and scaled to the plot without the browser resampling it vertically.
        this.bitmap = document.createElement('canvas');
        this.bctx = this.bitmap.getContext('2d', { alpha: false });
        this.image = null;

        // Overwritten by the page's applySettings() before the first frame.
        // Kept in step with `defaults` there all the same: if a fault stops
        // that call, what shows through should be the same picture and not an
        // older one.
        this.exposure = {
            whiteDB: -180, blackDB: -10,   // sensitivity 95, range 170
            autoGain: false, inverted: false,
        };

        /// Places where the picture stops meaning what it meant, in columns.
        /// They ride along with the image, so a mark stays on the moment it
        /// describes and scrolls off with it.
        this.marks = [];

        // Layout, in CSS pixels. The gutter holds the frequency scale and runs
        // the full height, so a label can sit at its tap's true position even
        // when that is the very first or last row.
        this.gutter = 34;
        this.topInset = 8;
        this.bottomInset = 8;

        /// Whether the waveform strip is drawn above the picture. It adds to
        /// the canvas rather than taking from the picture; see
        /// `PICTURE_HEIGHT`.
        this.showsWaveform = false;
        /// Whether the spectrum is drawn to the right of the picture.
        this.showsSpectrum = false;
        /// The spectrum's share of the width it and the picture divide between
        /// them -- everything right of the gutter.
        ///
        /// A share rather than a number of pixels, so that resizing the window
        /// does not change the split, exactly as `waveformShare` is a ratio in
        /// the Mac app. The Mac's spectrum lives outside the window and costs
        /// nothing, so it is given half a picture's width, a quarter of that to
        /// the black point. In here it costs columns, and this is a quarter of
        /// what the Mac spends. The boundary is draggable; this is where it
        /// starts.
        this.spectrumShare = 0.24;
        /// Called when a drag of that boundary finishes, so the share can be
        /// remembered -- not on every step, as with the close-up's boundary.
        this.onSpectrumShareChanged = null;

        // Milliseconds per column -- the Speed setting. Owned by the page,
        // which is where Speed lives; the display only needs it to turn a
        // distance across the picture into a duration.
        this.columnMs = 4;
        /// Measuring is confined to a frozen picture: a line is anchored to a
        /// column, and on a moving one the column it named has scrolled
        /// somewhere else by the time the second line is placed.
        this.paused = false;

        // ---- automatic exposure ------------------------------------------
        //
        // The engine also tracks a reference, but it is a peak follower: it
        // rises to the loudest tap at once and decays back. In a quiet room
        // the loudest tap *is* the noise floor, so the reference sinks to meet
        // it and the whole window ends up below the noise -- the picture goes
        // solid black, having faithfully exposed for a signal that is not
        // there.
        //
        // This aims at a property of the picture instead: keep the average
        // pixel about 30% of the way to full ink. It cannot run away, because
        // the thing it measures is the thing it controls, and it does not care
        // whether the level it is looking at is signal or noise -- only whether
        // there is a legible amount of ink on the paper.
        this.autoRef = 0;
        /// Mean ink to aim for, 0 = blank paper, 1 = solid.
        this.autoTargetInk = 0.30;
        /// How fast the reference chases it, in dB per second at full error.
        /// Slow enough not to pump on speech, fast enough to follow a room.
        this.autoRateDb = 25;

        // ---- the two time bases ------------------------------------------
        //
        // With Close-up off there is one: every column the engine produces is
        // a column of the picture, and the whole bitmap scrolls together.
        //
        // With it on the engine runs `aggregate` times faster and the bitmap
        // is two regions with different scroll rates. The rightmost
        // `closeUpColumns` are the close-up, one engine column each. Everything
        // to their left is the ordinary picture, which advances one column for
        // every `aggregate` that fall off the close-up's left edge -- so a
        // column enters at the right, crosses the close-up at speed, and joins
        // the main picture at the far side having aged by exactly the
        // close-up's span.
        //
        // Taking every `aggregate`-th column rather than averaging is
        // deliberate: it lands on the same audio instants the main display
        // samples with Close-up off, so the ordinary picture is unchanged by
        // the feature being available.
        this.closeUpColumns = 0;
        this.aggregate = 1;
        this.fineIndex = 0;
        this.draggingBoundary = false;
        this.dragGrab = 0;
        /// Called when a drag finishes, so the width can be remembered. Not on
        /// every step: a drag is one decision, not fifty.
        this.onCloseUpWidthChanged = null;
        /// Turns a width being dragged towards into the nearest one that can
        /// actually be drawn. The display does not know the span or the Speed
        /// setting and has no business knowing them; it knows where the pointer
        /// is. So legality is asked for rather than computed here, and the line
        /// goes exactly where the answer says -- a control that springs back is
        /// a control that lied.
        this.snapCloseUpWidth = null;

        // ---- the waveform strip's gain -----------------------------------
        //
        // See `updateWaveformGain`. The darkest tap and the largest excursion
        // since the last frame, accumulated rather than assigned because a
        // batch can arrive more than once a frame and the controller wants the
        // whole frame.
        this.batchPeakDB = -Infinity;
        this.batchExcursion = 0;
        /// What the controller is holding.
        this.trackedInk = 0;
        this.trackedExcursion = 0;
        this.agcTick = 0;
        /// Whether any column arrived since the last frame. The controller runs
        /// only while the picture is moving, so a frozen display holds the gain
        /// it froze at and the shape on screen goes on meaning what it meant.
        this.columnsArrived = false;

        // ---- the spectrum's smoothing ------------------------------------
        /// What is drawn: the smoothed trace, tap 0 first.
        this.trace = [];
        /// And the unsmoothed one it is chasing, kept between frames so the
        /// audio path does not allocate. Never the same array as `trace`.
        this.traceRaw = null;
        this.traceTick = 0;

        this.resizing = false;
        this.imageDirty = false;
        this.hover = null;
        this.measurement = null;
        this.measuring = false;
        this.frequencyHeldBack = false;
        this.draggingSpectrum = false;
        this.spectrumGrab = 0;
        /// The share has moved and the picture has not been resized to match
        /// yet. Cleared by the next `render`.
        this.spectrumPending = false;
        this.attachPointer();
    }

    // MARK: reading time and frequency off the picture
    //
    // Neither axis can be read accurately by eye: the frequency scale has ten
    // labels on six hundred taps, and the time axis has none at all. So the
    // pointer answers for both -- a line across the picture with the frequency
    // at its left end, and, on a frozen picture, a pair of lines whose
    // separation is stated in milliseconds.

    attachPointer() {
        const c = this.canvas;
        c.addEventListener('pointermove', e => {
            const p = this.local(e);
            this.hover = p;
            if (this.draggingBoundary) { this.dragBoundary(p); return; }
            if (this.draggingSpectrum) { this.dragSpectrum(p); return; }
            c.style.cursor = this.onSpectrumEdge(p) ? 'ew-resize'
                : !this.inPlot(p) ? 'default'
                : this.onBoundary(p) ? 'ew-resize' : 'crosshair';
            if (this.measuring) {
                this.measurement.cursor = this.columnAt(p.x);
                this.measurement.y = p.y;
            } else {
                // Only a move that is *not* part of a drag brings the
                // frequency line back. AppKit distinguishes the two by sending
                // mouseDragged separately from mouseMoved; the browser sends
                // pointermove for both, so the distinction has to be made here
                // or the line reappears the instant the drag starts -- which
                // is the one moment it is in the way.
                this.frequencyHeldBack = false;
            }
        });
        c.addEventListener('pointerleave', () => { this.hover = null; });
        c.addEventListener('pointerdown', e => {
            const p = this.local(e);
            // Tested before the plot is, because this edge is the one column
            // *past* the picture's right-hand end and so lies just outside it.
            if (this.onSpectrumEdge(p)) {
                c.setPointerCapture(e.pointerId);
                this.draggingSpectrum = true;
                this.spectrumGrab = p.x - (this.plot.x + this.plot.w);
                return;
            }
            if (!this.inPlot(p)) return;
            // The line is the control. There is no obvious place in a toolbar
            // for "how much of the recent past", and a number in a box would be
            // a worse way to answer a question you are answering by eye anyway.
            if (this.onBoundary(p)) {
                c.setPointerCapture(e.pointerId);
                this.draggingBoundary = true;
                this.dragGrab = p.x - this.boundaryX;
                // Whatever was being measured is about to be measured against
                // a different time scale, and its lines would sit there in
                // orange looking like part of the boundary.
                //
                // Which also changes what a playback is playing, so it is a
                // Stop for the same reason a click on the picture is.
                this.onSelectionDisturbed?.();
                this.clearMeasurement();
                return;
            }
            if (!this.paused) return;
            c.setPointerCapture(e.pointerId);
            this.measurement = { anchor: this.columnAt(p.x), cursor: null, y: p.y };
            this.measuring = true;
            this.hover = p;
            // A click chooses what to play, so it cannot also be ignored while
            // something is playing. The new lines stay.
            this.onSelectionDisturbed?.();
            // The frequency line and the duration would be drawn at the same
            // height during a drag, the arrows running along the line. It comes
            // back when the pointer next *moves* rather than when the button
            // comes up: on release the pointer is still sitting on the arrows.
            this.frequencyHeldBack = true;
        });
        const end = e => {
            if (this.draggingSpectrum) {
                this.draggingSpectrum = false;
                try { c.releasePointerCapture(e.pointerId); } catch {}
                this.onSpectrumShareChanged?.(this.spectrumShare);
                return;
            }
            if (this.draggingBoundary) {
                this.draggingBoundary = false;
                try { c.releasePointerCapture(e.pointerId); } catch {}
                this.onCloseUpWidthChanged?.(this.closeUpColumns);
                return;
            }
            if (!this.measuring) return;
            this.measuring = false;
            // The lines stay. Reading a duration and then looking at what lies
            // between the two is one action, not two.
            try { c.releasePointerCapture(e.pointerId); } catch {}
        };
        c.addEventListener('pointerup', end);
        c.addEventListener('pointercancel', end);
    }

    local(e) {
        const r = this.canvas.getBoundingClientRect();
        return { x: e.clientX - r.left, y: e.clientY - r.top };
    }

    onBoundary(p) {
        const bx = this.boundaryX;
        return bx !== null && Math.abs(p.x - bx) <= 4;
    }

    dragBoundary(p) {
        if (!this.width) return;
        const asked = Math.min(Math.max(0, this.width -
                          Math.round(this.columnAt(p.x - this.dragGrab))),
                          this.maxCloseUpColumns);
        const want = this.snapCloseUpWidth ? this.snapCloseUpWidth(asked) : asked;
        if (want > 0 && want !== this.closeUpColumns) {
            this.closeUpColumns = want;
            this.clearMeasurement();
        }
    }

    inPlot(p) {
        const q = this.plot;
        return p.x >= q.x && p.x < q.x + q.w && p.y >= q.y && p.y < q.y + q.h;
    }

    /// On the line between the picture and the spectrum.
    ///
    /// Anywhere down the canvas, including beside the waveform strip: the strip
    /// shares the picture's right-hand edge, so the same line divides both, and
    /// a grab that worked over one and not the other would be arbitrary.
    onSpectrumEdge(p) {
        if (!this.showsSpectrum) return false;
        const q = this.plot;
        return Math.abs(p.x - (q.x + q.w)) <= 4;
    }

    dragSpectrum(p) {
        // The checkbox can be reached from the keyboard while the pointer is
        // captured, and with the spectrum off the boundary is the picture's
        // right edge -- against which every position reads as "as narrow as
        // possible", which is what would then be saved.
        if (!this.showsSpectrum) return;
        const avail = this.availWidth;
        // Snapped to four CSS pixels: finer than an eye places a line, and a
        // quarter of the work below.
        const want = Math.round((p.x - this.spectrumGrab - this.gutter) / 4) * 4;
        const [lo, hi] = SPECTRUM_SHARE_RANGE;
        const share = Math.min(hi, Math.max(lo, (avail - want) / avail));
        if (share === this.spectrumShare) return;
        this.spectrumShare = share;
        // Flagged, not resized. The resize happens once in the next frame.
        //
        // Every change of the share changes the column count, and a change of
        // column count reallocates both planes and the ImageData and re-renders
        // every column -- some nine megabytes and three quarters of a million
        // pixel writes at a full-height picture. A pointer reports a position
        // per event, which on a trackpad is far more often than the screen is
        // redrawn, and the intermediate ones are never seen. Doing that work
        // per event is the load that took Safari down on an iPad; the
        // re-entrancy guard in `resize` does not help, because these are
        // separate calls rather than nested ones.
        this.spectrumPending = true;
    }

    /// Widest the strip may be: the close-up is meant to be read against the
    /// ordinary picture, not instead of it.
    get maxCloseUpColumns() { return Math.max(0, this.width >> 1); }

    get nearDrawn() {
        return Math.min(this.closeUpColumns, this.maxCloseUpColumns);
    }

    /// Where the boundary is on screen, or null when there is no close-up.
    get boundaryX() {
        const near = this.nearDrawn;
        if (!near || !this.width) return null;
        return this.xForColumn(this.width - near);
    }

    /// Turn the close-up on or off, or change its shape.
    ///
    /// The two regions cannot be reconciled across a change of *timing* -- one
    /// column of the main picture would have to be unpicked into `aggregate`
    /// of the close-up, and the data to do it with was never kept -- so the
    /// picture is wiped for that. Moving the boundary is not a change of
    /// timing: both regions carry exactly what they carried before, and the
    /// mixed strip it creates scrolls off by itself in a fraction of a second.
    setCloseUp(columns, aggregate) {
        const c = Math.max(0, columns | 0);
        const a = Math.max(1, aggregate | 0);
        if (c === this.closeUpColumns && a === this.aggregate) return;
        const retime = a !== this.aggregate ||
                       (c > 0) !== (this.closeUpColumns > 0);
        this.clearMeasurement();
        this.closeUpColumns = c;
        this.aggregate = a;
        if (retime) this.clear();
    }

    /// Wipe the picture. The two regions are about to disagree about what a
    /// column means, and there is no way to reconcile them.
    clear() {
        this.levels.fill(SILENT_DB);
        this.coherence.fill(NO_COHERENCE);
        this.refs.fill(0);
        this.columnLo.fill(0);
        this.columnHi.fill(0);
        this.fine.fill(-1);
        // Here rather than in the caller, as `CochleagramView.clear` has it.
        // With the close-up open, a wipe that left this large would have the
        // next append promote columns straight out of the just-wiped strip into
        // the main picture, stamping real engine indices onto columns holding
        // nothing but silence.
        this.fineIndex = 0;
        // A wipe ends the old numbering, so a recorder that missed it would go
        // on mapping columns to audio through an origin that no longer means
        // anything.
        this.contentEpoch++;
        this.playhead = null;
        this.marks.length = 0;
        this.clearMeasurement();
        if (this.image) this.renderColumns(0, this.width);
    }

    clearMeasurement() {
        this.measurement = null;
        this.measuring = false;
    }

    get hasMeasurement() { return this.measurement !== null; }

    // MARK: RePlay -- from the picture back to the audio
    //
    // The picture is several seconds of sound. These turn a position on it back
    // into a position in the recording, so what is on screen can be heard.
    // Everything here is in *engine columns*: the one coordinate still
    // meaningful when the close-up puts two time scales on the screen at once,
    // and when a change of Speed leaves the older half of the picture at a
    // scale the newer half is not. The Mac app has the same six members, doing
    // the same arithmetic. See REPLAY-DESIGN.md.

    /// The index the next engine column to arrive will have.
    get nextEngineColumn() { return this.fineIndex; }

    /// The engine column drawn at a fractional screen column, or null where
    /// nothing has been drawn yet.
    engineColumnAt(u) {
        if (!this.width || this.fine.length !== this.width) return null;
        const x = Math.min(Math.max(Math.floor(u), 0), this.width - 1);
        const g = this.fine[x];
        return g >= 0 ? g : null;
    }

    /// How much of the stream one screen column stands for: one engine column
    /// in the close-up strip, `aggregate` of them in the main picture.
    ///
    /// It matters at the right-hand end of a selection. A main-picture column
    /// *names* the first of the engine columns it draws, so a selection
    /// stopping at that name would be short by the rest of them -- at aggregate
    /// 8, a single column would play an eighth of what it shows.
    engineSpanAt(x) {
        const near = this.nearDrawn;
        if (near > 0 && x >= this.width - near) return 1;
        return Math.max(1, this.aggregate);
    }

    /// The oldest and newest engine columns anywhere on screen, or null.
    ///
    /// Not simply the two ends of the array: after a wipe, or on a window just
    /// widened, the left of the picture is columns that were never drawn.
    get drawnColumns() {
        if (!this.width || this.fine.length !== this.width) return null;
        let lo = -1, hi = -1;
        for (let x = 0; x < this.width; x++) {
            if (this.fine[x] >= 0) { lo = this.fine[x]; break; }
        }
        for (let x = this.width - 1; x >= 0; x--) {
            if (this.fine[x] >= 0) { hi = this.fine[x]; break; }
        }
        if (lo < 0 || hi < lo) return null;
        return { lo, hi };
    }

    /// What Play Selection would play: the first engine column, and one past
    /// the last.
    ///
    /// The measurement's three states are the three playback modes, which is
    /// why RePlay has no selection of its own: no lines plays the width of the
    /// picture, one line plays from there to the right-hand edge, two play what
    /// is between them.
    ///
    /// The upper bound is exclusive and already extended past the last column
    /// by that column's own span, so a one-column selection is a column's worth
    /// of sound rather than none.
    get selectionColumns() {
        const drawn = this.drawnColumns;
        if (!drawn || !this.width) return null;
        const lastX = this.width - 1;
        const m = this.measurement;
        if (!m) return { lo: drawn.lo, end: drawn.hi + this.engineSpanAt(lastX) };

        const ax = Math.min(Math.max(Math.floor(m.anchor), 0), lastX);
        // Where a line stands over picture that was never drawn, the sound it
        // names does not exist. Undrawn columns are only ever at the left, so
        // both ends fall back to the oldest column there is and never to the
        // newest: falling back to the right-hand edge would turn a leftward
        // drag into a rightward selection.
        const a = this.engineColumnAt(m.anchor) ?? drawn.lo;
        if (m.cursor === null) {
            return { lo: a, end: drawn.hi + this.engineSpanAt(lastX) };
        }
        const bx = Math.min(Math.max(Math.floor(m.cursor), 0), lastX);
        const b = this.engineColumnAt(m.cursor) ?? drawn.lo;
        const hiX = a <= b ? bx : ax;
        return { lo: Math.min(a, b),
                 end: Math.max(a, b) + this.engineSpanAt(hiX) };
    }

    /// Where an engine column sits on screen, as a fractional screen column, or
    /// null.
    ///
    /// Interpolated inside whichever column it lands in, because in the main
    /// picture one column stands for `aggregate` engine columns and a line that
    /// only ever sat on column boundaries would advance in visible jerks at the
    /// coarser Speed settings. `fine` is non-decreasing left to right in both
    /// regions, so this is a binary search.
    screenColumnForEngine(g) {
        if (!this.width || this.fine.length !== this.width) return null;
        let first = -1;
        for (let x = 0; x < this.width; x++) {
            if (this.fine[x] >= 0) { first = x; break; }
        }
        if (first < 0 || g < this.fine[first]) return null;
        let lo = first, hi = this.width - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) >> 1;
            if (this.fine[mid] <= g) lo = mid; else hi = mid - 1;
        }
        const g0 = this.fine[lo];
        // A wipe with the close-up open refills the main region and the strip
        // from opposite ends, so for a fraction of a second there is a run of
        // never-drawn columns *between* two runs of real ones and the search
        // can land in it. Nothing sensible can be drawn against a column with
        // no engine column behind it.
        if (g0 < 0) return null;
        // How much of the stream this column stands for. Taken from the next
        // column along where there is one -- which is right across the close-up
        // boundary too, where the two regions' widths differ -- and from the
        // region's own rate at the right-hand edge, where there is no next.
        let span = this.engineSpanAt(lo);
        if (lo + 1 < this.width && this.fine[lo + 1] > g0) {
            span = this.fine[lo + 1] - g0;
        }
        const frac = (g - g0) / Math.max(1, span);
        return lo + Math.min(Math.max(frac, 0), 1);
    }

    /// Fractional column under an x, clamped to the picture.
    columnAt(x) {
        const q = this.plot;
        if (!this.width || q.w <= 0) return 0;
        const u = (x - q.x) / q.w * this.width;
        return Math.min(Math.max(u, 0), this.width);
    }

    xForColumn(u) {
        const q = this.plot;
        return this.width ? q.x + u / this.width * q.w : q.x;
    }

    /// The best frequency of the tap under a y, interpolated geometrically
    /// between the two it falls between. At sixty taps to the octave one row is
    /// 1.2%, which at 8 kHz is nearly a hundred hertz -- more than the "nearest
    /// Hz" the readout claims -- and between taps is where the pointer usually
    /// is, the rows being about a pixel tall.
    frequencyAt(y) {
        const cf = this.frequencies, q = this.plot;
        if (!cf || cf.length < 2 || q.h <= 0) return null;
        const n = Math.min(cf.length, this.taps);
        const r = (y - q.y) / q.h * this.taps - 0.5;
        const rr = Math.min(Math.max(r, 0), n - 1);
        const i = Math.min(n - 2, Math.max(0, Math.floor(rr)));
        return cf[i] * Math.pow(cf[i + 1] / cf[i], rr - i);
    }

    /// Called once the engine has said how many taps there are.
    setGeometry(taps, frequencies) {
        this.taps = taps;
        this.frequencies = frequencies;
        this.resize();
    }

    // ---- layout ---------------------------------------------------------
    //
    // Left to right: the gutter, which holds the frequency scale and runs the
    // full height; the picture; and, when it is on, the spectrum. Top to
    // bottom: an inset for the topmost label's overhang -- which is drawn in
    // the gutter, so it has the strip beside it rather than over it -- then the
    // waveform strip when it is on, then the picture, then an inset.

    /// How tall the strip is, or zero when it is off.
    get waveformHeight() { return this.showsWaveform ? WAVEFORM_HEIGHT : 0; }

    /// How tall the canvas element has to be for the picture to come out at
    /// `PICTURE_HEIGHT` with whatever else is switched on above it.
    get cssHeight() {
        return this.topInset + this.waveformHeight
             + PICTURE_HEIGHT + this.bottomInset;
    }

    /// Everything right of the gutter: what the picture and the spectrum share.
    get availWidth() {
        const dpr = window.devicePixelRatio || 1;
        return Math.max(1, this.canvas.width / dpr - this.gutter);
    }

    /// How much of that the spectrum takes, or zero when it is off.
    get spectrumWidth() {
        if (!this.showsSpectrum) return 0;
        const avail = this.availWidth;
        // The floor is for a window too narrow for the share to mean anything;
        // the drag's own limits are wider and are enforced where it happens.
        return Math.min(Math.round(avail * this.spectrumShare),
                        Math.max(0, avail - MIN_PLOT_WIDTH));
    }

    /// Where the black point sits, measured from the zero line.
    ///
    /// Half the width, so the other half is headroom: levels past the black
    /// point are deliberately not clipped by the arithmetic and need somewhere
    /// to go. The same two-to-one the Mac's window has.
    get spectrumReach() { return this.spectrumWidth / 2; }

    get plot() {
        const dpr = window.devicePixelRatio || 1;
        const h = this.canvas.height / dpr;
        return {
            x: this.gutter,
            y: this.topInset + this.waveformHeight,
            w: Math.max(1, this.availWidth - this.spectrumWidth),
            h: Math.max(1, h - this.topInset - this.bottomInset
                            - this.waveformHeight),
        };
    }

    /// Where a frequency sits on the canvas, in CSS pixels: the left edge of
    /// the picture, and the centre of the tap nearest `f`.
    ///
    /// For putting a page element over the picture. Everything else that draws
    /// on the picture does it in canvas coordinates and never needs this; a
    /// `<button>` is not something a canvas can hold, and it has to be told
    /// where to sit in the units the page lays out in. CSS pixels rather than
    /// device pixels for that reason -- the two differ by `devicePixelRatio`,
    /// which on the phones this exists for is three.
    ///
    /// Null before the geometry has arrived from the engine, which is the state
    /// the page starts in and returns to on every reopen.
    anchorFor(f) {
        if (!this.frequencies || !this.frequencies.length || !this.taps) {
            return null;
        }
        const p = this.plot;
        return { x: p.x, y: this.yForRow(this.rowFor(f), p) };
    }

    /// Where the strip goes: directly above the picture, sharing its left and
    /// right edges so a column is above the column it describes.
    get waveformRect() {
        const p = this.plot;
        return { x: p.x, y: this.topInset, w: p.w, h: this.waveformHeight };
    }

    /// Match the element's height to what is switched on. The ResizeObserver
    /// on the canvas turns this into a `resize()`, so nothing else is needed.
    applyHeight() {
        this.canvas.style.height = this.cssHeight + 'px';
    }

    /// Turn either readout on or off.
    ///
    /// Both change the geometry the picture is drawn in -- the strip by making
    /// the canvas taller, the spectrum by taking width from the plot -- so both
    /// go through here rather than being assigned from outside.
    setReadouts({ waveform, spectrum } = {}) {
        if (waveform !== undefined) this.showsWaveform = !!waveform;
        if (spectrum !== undefined) this.showsSpectrum = !!spectrum;
        this.applyHeight();
        // And then immediately, rather than waiting for the ResizeObserver the
        // line above will eventually trigger. Reading `clientHeight` in
        // `resizeInner` forces the layout the assignment just invalidated, so
        // this sees the new height; leaving it to the observer would draw one
        // frame with the strip's space taken out of the picture. The observer's
        // own call, when it arrives, finds nothing left to do.
        this.resize();
    }

    /// Match the backing store to the element, and the column count to the
    /// plot's width. Keeps the most recent part of the picture, right-aligned,
    /// exactly as the Mac app does -- what falls off is the oldest.
    resize() {
        // Re-entrant guard. This is driven by a ResizeObserver on the canvas,
        // and everything below can change the canvas -- so without this, one
        // observation can cause the next, and the loop reallocates three typed
        // arrays and an ImageData every time round. On a desktop that merely
        // wastes work; on an iPad it exhausted the tab and took Safari with it.
        if (this.resizing) return;
        this.resizing = true;
        try {
            this.resizeInner();
        } finally {
            this.resizing = false;
        }
    }

    resizeInner() {
        const dpr = window.devicePixelRatio || 1;
        const cw = Math.max(320, Math.round(this.canvas.clientWidth));
        // The floor is what the layout actually asks for, not a literal.
        // `clientHeight` reads zero while the element is laid out but not shown
        // -- inside a frame, or under a hidden ancestor -- and a literal 200
        // would then leave 64 pixels for 599 taps once the strip took its 120.
        const chh = Math.max(this.cssHeight,
                             Math.round(this.canvas.clientHeight));
        const bw = Math.round(cw * dpr), bh = Math.round(chh * dpr);
        // Only when it has actually changed. Assigning `canvas.width` resets
        // the canvas even when the value is identical -- it clears the pixels
        // and the transform -- so doing it on every observation both threw the
        // picture away and re-triggered the observer.
        if (this.canvas.width !== bw || this.canvas.height !== bh) {
            this.canvas.width = bw;
            this.canvas.height = bh;
        }
        if (!this.taps) return;

        const w = Math.max(64, Math.round(this.plot.w));
        if (w === this.width) { this.render(); return; }

        const nl = new Float32Array(w * this.taps).fill(SILENT_DB);
        const nc = new Float32Array(w * this.taps).fill(NO_COHERENCE);
        const nr = new Float32Array(w);
        // Zero for "nothing was heard here", which the strip draws as its zero
        // line -- the same thing a never-written column reads as.
        const nlo = new Float32Array(w);
        const nhi = new Float32Array(w);
        // -1 for "never drawn here", which is what the columns a widened window
        // exposes are. Distinct from 0, which is a real column: the first one
        // after a wipe.
        const nf = new Float64Array(w).fill(-1);
        if (this.width > 0) {
            const keep = Math.min(w, this.width);
            nl.set(this.levels.subarray((this.width - keep) * this.taps),
                   (w - keep) * this.taps);
            nc.set(this.coherence.subarray((this.width - keep) * this.taps),
                   (w - keep) * this.taps);
            nr.set(this.refs.subarray(this.width - keep), w - keep);
            if (this.columnLo.length === this.width) {
                nlo.set(this.columnLo.subarray(this.width - keep), w - keep);
                nhi.set(this.columnHi.subarray(this.width - keep), w - keep);
            }
            if (this.fine.length === this.width) {
                nf.set(this.fine.subarray(this.width - keep), w - keep);
            }
            // The measurement's lines are anchored to content in the same way
            // the marks are, and a resize right-aligns what it keeps. Left
            // alone they would go on stating the same duration over different
            // audio. Either end falling off takes the whole measurement with
            // it: half of a duration is not a shorter duration.
            const m = this.measurement;
            if (m) {
                const d = w - this.width;
                m.anchor += d;
                if (m.cursor !== null) m.cursor += d;
                const ends = [m.anchor, m.cursor].filter(v => v !== null);
                if (!ends.every(v => v >= 0 && v <= w)) this.clearMeasurement();
            }
        } else {
            this.clearMeasurement();
        }
        this.levels = nl;
        this.coherence = nc;
        this.refs = nr;
        this.columnLo = nlo;
        this.columnHi = nhi;
        this.fine = nf;
        this.width = w;

        this.bitmap.width = w;
        this.bitmap.height = this.taps;
        this.image = this.bctx.createImageData(w, this.taps);
        this.image.data.fill(255);            // opaque
        this.renderColumns(0, w);
        this.render();
    }

    /// Put a mark on the newest column.
    ///
    /// `seam` is the one that matters: live input cannot be paused, only
    /// ignored, so the columns arriving while the display is frozen are thrown
    /// away and resuming butts together two moments that were never adjacent.
    /// Without a mark the picture claims a continuity it does not have, which
    /// is the one lie an analysis display must not tell. Pausing a *file* loses
    /// nothing, so it is not marked.
    mark(kind) {
        if (!this.width) return;
        this.marks.push({ column: this.width - 1, kind });
    }

    /// Work out the reference each incoming column should be drawn against,
    /// and write it into `refs` in place of the engine's peak follower.
    ///
    /// Per column rather than per screen, and stored alongside the column, so
    /// that a column keeps the exposure it was drawn with. Re-exposing the
    /// whole picture every time the reference moved would make everything
    /// already on screen shimmer in step with whatever just happened, which
    /// is a display that cannot be read while it is changing.
    autoExpose(levels, refs, count) {
        const taps = this.taps;
        // Nothing to average over, and `sum / taps` would be 0/0 -- which
        // `autoRef` would then hold for ever, since every clamp of a NaN is a
        // NaN. The Mac guards the same case at the top of its `autoExpose`.
        if (!taps) return;
        const { whiteDB, blackDB } = this.exposure;
        const span = (blackDB - whiteDB) || 1;
        // These are *engine* columns, which under Close-up arrive `aggregate`
        // times faster than the main picture scrolls -- so the rate has to be
        // in the engine's time, not the display's, or the loop would chase that
        // much harder the moment the strip was opened. `columnMs` is the main
        // picture's rate, deliberately: it is what the page sets it to.
        const engineMs = this.columnMs / Math.max(1, this.aggregate);
        const step = this.autoRateDb * engineMs / 1000;
        // The loudest tap in the batch, in dB, for the waveform's gain. Taken
        // here because this is the one place that already visits every tap of
        // every arriving column, so it costs a compare and no extra pass. The
        // *level* rather than the ink: which reference applies depends on
        // whether Auto gain is on, and that is not this function's business.
        let peakDB = -Infinity;
        for (let j = 0; j < count; j++) {
            const base = j * taps;
            const lo = whiteDB + this.autoRef;
            let sum = 0;
            for (let y = 0; y < taps; y++) {
                const v = levels[base + y];
                if (v > peakDB) peakDB = v;
                let t = (v - lo) / span;
                sum += t < 0 ? 0 : t > 1 ? 1 : t;
            }
            refs[j] = this.autoRef;
            // Too much ink means the window is too low, so lift it.
            const err = sum / taps - this.autoTargetInk;
            // Wide, because the reference has to be able to carry the
            // window from wherever the visitor left Sensitivity to wherever
            // the signal actually is, and those can be 150 dB apart -- a
            // MacBook and an iPad in the same room differ by about fifty.
            this.autoRef = Math.min(250, Math.max(-250,
                                    this.autoRef + step * err));
        }
        if (peakDB > -Infinity && peakDB > this.batchPeakDB) {
            this.batchPeakDB = peakDB;
        }
    }

    /// Take a batch of finished columns.
    append(levels, coherence, refs, inLo, inHi, count) {
        if (!this.width || !count) return;
        const taps = this.taps;
        // Always, not only when Auto gain is on: the reference then arrives
        // already settled when it is switched on, instead of spending several
        // seconds finding the room from a standing start.
        this.autoExpose(levels, refs, count);

        // Belt and braces: everything below indexes them as `width` long, and
        // they are written in more places than `refs` is.
        if (this.fine.length !== this.width) {
            this.fine = new Float64Array(this.width).fill(-1);
        }
        if (this.columnLo.length !== this.width) {
            this.columnLo = new Float32Array(this.width);
        }
        if (this.columnHi.length !== this.width) {
            this.columnHi = new Float32Array(this.width);
        }

        // The batch's largest excursion, for the waveform's gain. Taken from
        // the whole batch rather than from the columns that survive on screen:
        // the controller is following the sound, and a column dropped for want
        // of room was still heard.
        for (let c = 0; c < count; c++) {
            const a = Math.abs(inLo[c]), b = Math.abs(inHi[c]);
            const e = a > b ? a : b;
            if (e > this.batchExcursion) this.batchExcursion = e;
        }
        this.columnsArrived = true;

        const near = this.nearDrawn;
        if (near > 0) {
            this.appendTwoBases(levels, coherence, refs, inLo, inHi, count, near);
            return;
        }

        // The engine index of levels[c] is `first + c`.
        const first = this.fineIndex;
        if (count >= this.width) {
            // More arrived than fit: keep the newest screenful.
            this.marks.length = 0;         // nothing older survived
            const skip = count - this.width;
            this.levels.set(levels.subarray(skip * taps));
            this.coherence.set(coherence.subarray(skip * taps));
            this.refs.set(refs.subarray(skip));
            this.columnLo.set(inLo.subarray(skip));
            this.columnHi.set(inHi.subarray(skip));
            for (let c = 0; c < this.width; c++) this.fine[c] = first + skip + c;
            this.renderColumns(0, this.width);
            // Advanced on this path too, now that it names the audio as well as
            // the close-up's delay line. It used to move only when the close-up
            // was on, which was harmless while nothing else read it; left at
            // zero here every column of an ordinary picture would carry the
            // same engine index, and RePlay would play one instant of sound
            // however wide a span was selected. Both ways into and out of the
            // two-time-base mode go through `setCloseUp`, which resets it and
            // wipes, so the two readings can never be mixed on one screen.
            this.fineIndex += count;
            return;
        }

        // Scroll left. Column-major makes this one move however tall the
        // picture is; the bitmap is row-major and has to go a row at a time.
        const n = count;
        // Marks are anchored to content, so they move with it.
        for (const m of this.marks) m.column -= n;
        this.marks = this.marks.filter(m => m.column >= 0);

        this.levels.copyWithin(0, n * taps);
        this.coherence.copyWithin(0, n * taps);
        this.refs.copyWithin(0, n);
        this.columnLo.copyWithin(0, n);
        this.columnHi.copyWithin(0, n);
        this.fine.copyWithin(0, n);
        this.levels.set(levels.subarray(0, n * taps), (this.width - n) * taps);
        this.coherence.set(coherence.subarray(0, n * taps), (this.width - n) * taps);
        this.refs.set(refs.subarray(0, n), this.width - n);
        this.columnLo.set(inLo.subarray(0, n), this.width - n);
        this.columnHi.set(inHi.subarray(0, n), this.width - n);
        for (let c = 0; c < n; c++) this.fine[this.width - n + c] = first + c;

        const d = this.image.data;
        const rowBytes = this.width * 4;
        for (let y = 0; y < taps; y++) {
            const row = y * rowBytes;
            d.copyWithin(row, row + n * 4, row + rowBytes);
        }
        this.renderColumns(this.width - n, n);
        this.fineIndex += count;
    }

    /// Move columns [lo+k, hi) left to [lo, hi-k) in a column-major plane.
    /// One move however tall the picture is.
    shiftPlane(a, lo, hi, k) {
        const t = this.taps;
        a.copyWithin(lo * t, (lo + k) * t, hi * t);
    }

    /// The same for the bitmap, which is row-major and has to go a row at a
    /// time. This is the one place that pays for ImageData's layout.
    shiftPixels(lo, hi, k) {
        const d = this.image.data, rowBytes = this.width * 4;
        for (let y = 0; y < this.taps; y++) {
            const row = y * rowBytes;
            d.copyWithin(row + lo * 4, row + (lo + k) * 4, row + hi * 4);
        }
    }

    /// Append with the close-up open.
    ///
    /// Written in terms of the engine's column index rather than positions in
    /// the bitmap, because a batch can be longer than the strip is wide. The
    /// close-up is a delay line `near` columns long over the engine's output:
    /// the column that entered at index g leaves when the stream reaches
    /// g + near, and every `aggregate`-th one becomes a column of the main
    /// picture on its way out.
    appendTwoBases(levels, coherence, refs, inLo, inHi, count, near) {
        const taps = this.taps, W = this.width;
        const K = Math.max(1, this.aggregate);
        const mainHi = W - near;
        const first = this.fineIndex;                 // index of levels[0]

        // Which columns leave the strip during this batch, and which of those
        // are due to be promoted.
        const promoted = [];
        for (let g = Math.max(0, first - near); g < first - near + count; g++) {
            if (g % K === 0) promoted.push(g);
        }
        // The main region cannot absorb more than its own width in one call,
        // and anything beyond that would be drawn and immediately scrolled
        // away.
        const take = Math.min(promoted.length, mainHi);
        const from = promoted.length - take;

        // Gathered before anything moves: some of these are still in the strip
        // and the strip is about to be shifted out from under them.
        const keepL = new Float32Array(take * taps);
        const keepC = new Float32Array(take * taps);
        const keepR = new Float32Array(take);
        // A promoted column keeps the engine index it entered the strip with,
        // which is `g` -- so a column of the main picture names the first of
        // the `aggregate` engine columns it stands for, which is where in the
        // audio it begins.
        const keepF = new Float64Array(take);
        const keepLo = new Float32Array(take);
        const keepHi = new Float32Array(take);
        for (let i = 0; i < take; i++) {
            const g = promoted[from + i];
            keepF[i] = g;
            if (g >= first) {                          // still in flight
                const c = g - first;
                keepL.set(levels.subarray(c * taps, (c + 1) * taps), i * taps);
                keepC.set(coherence.subarray(c * taps, (c + 1) * taps), i * taps);
                keepR[i] = refs[c];
            } else {                                   // in the strip
                const x = mainHi + (g - (first - near));
                if (x < mainHi || x >= W) continue;
                keepL.set(this.levels.subarray(x * taps, (x + 1) * taps), i * taps);
                keepC.set(this.coherence.subarray(x * taps, (x + 1) * taps), i * taps);
                keepR[i] = this.refs[x];
            }
        }

        // The waveform's range is *summarised* over the columns a promoted
        // column stands for, not sampled from the first of them like the level
        // and the reference beside it.
        //
        // Those can be sampled because they are peak-followers with decay:
        // every aggregate-th one is nearly the same picture. A raw min and max
        // is not. `aggregate` reaches eighty at the finest close-up, so
        // sampling would draw each main column from 0.05 ms out of every 4 -- a
        // sliver at an arbitrary phase, which below a few kHz is noise. The
        // strip would then be solid to the right of the boundary and a picket
        // fence to the left of it, at exactly the place the two are meant to be
        // compared. The columns in between are all here; this reads them.
        //
        // How many of them can actually be read yet: a column is promoted when
        // it *leaves* the strip, which is `near` columns after it entered, so at
        // that moment the engine has produced everything up to `g + near` and no
        // further. When the close-up is set finer than the strip is wide, `K`
        // can exceed that, and the tail of the span does not exist when the
        // column has to be written. Taking a window of the same size for every
        // column keeps the strip uniform; a full summary for most and a
        // truncated one for the last of each batch reads as noise and is worse
        // than a consistent under-sample. The common settings are unaffected --
        // `near` is larger than `K` whenever the close-up's span is longer than
        // one column of the main picture, which is nearly always.
        const spanCols = Math.max(1, Math.min(K, near + 1));
        for (let i = 0; i < take; i++) {
            const g = promoted[from + i];
            let lo = Infinity, hi = -Infinity, any = false;
            for (let k = 0; k < spanCols; k++) {
                const gk = g + k;
                if (gk >= first) {
                    const c = gk - first;
                    if (c >= count) break;             // not arrived yet
                    if (inLo[c] < lo) lo = inLo[c];
                    if (inHi[c] > hi) hi = inHi[c];
                    any = true;
                } else {
                    const x = mainHi + (gk - (first - near));
                    if (x < mainHi || x >= W) continue;
                    if (this.columnLo[x] < lo) lo = this.columnLo[x];
                    if (this.columnHi[x] > hi) hi = this.columnHi[x];
                    any = true;
                }
            }
            keepLo[i] = any ? lo : 0;
            keepHi[i] = any ? hi : 0;
        }

        if (take > 0) {
            this.shiftPlane(this.levels, 0, mainHi, take);
            this.shiftPlane(this.coherence, 0, mainHi, take);
            this.refs.copyWithin(0, take, mainHi);
            this.columnLo.copyWithin(0, take, mainHi);
            this.columnHi.copyWithin(0, take, mainHi);
            this.fine.copyWithin(0, take, mainHi);
            this.shiftPixels(0, mainHi, take);
            this.levels.set(keepL, (mainHi - take) * taps);
            this.coherence.set(keepC, (mainHi - take) * taps);
            this.refs.set(keepR, mainHi - take);
            this.columnLo.set(keepLo, mainHi - take);
            this.columnHi.set(keepHi, mainHi - take);
            this.fine.set(keepF, mainHi - take);
        }

        const fill = Math.min(count, near);
        const skip = count - fill;
        this.shiftPlane(this.levels, mainHi, W, fill);
        this.shiftPlane(this.coherence, mainHi, W, fill);
        this.refs.copyWithin(mainHi, mainHi + fill, W);
        this.columnLo.copyWithin(mainHi, mainHi + fill, W);
        this.columnHi.copyWithin(mainHi, mainHi + fill, W);
        this.fine.copyWithin(mainHi, mainHi + fill, W);
        this.shiftPixels(mainHi, W, fill);
        this.levels.set(levels.subarray(skip * taps, count * taps), (W - fill) * taps);
        this.coherence.set(coherence.subarray(skip * taps, count * taps), (W - fill) * taps);
        this.refs.set(refs.subarray(skip, count), W - fill);
        // One engine column each in the strip, so the range is the column's own
        // and nothing is summarised.
        this.columnLo.set(inLo.subarray(skip, count), W - fill);
        this.columnHi.set(inHi.subarray(skip, count), W - fill);
        // One engine column each in the strip, so the index is the stream's own.
        for (let c = 0; c < fill; c++) this.fine[W - fill + c] = first + skip + c;

        // Marks travel at whichever rate the region they are in moves. One
        // that crosses the boundary lands just inside the main picture -- at
        // `mainHi - 1`, not at `mainHi` -- because a mark left *on* the
        // boundary is still in the strip as far as the next batch is
        // concerned, and would be pushed back onto it every time. It would
        // then sit on the divider for ever instead of scrolling away, which is
        // exactly what it looked like.
        //
        // Landing a millisecond or two out of place is the cost. A seam that
        // vanishes would be worse.
        for (const m of this.marks) {
            if (m.column >= mainHi) {
                m.column -= fill;
                if (m.column < mainHi) m.column = mainHi - 1;
            } else {
                m.column -= take;
            }
        }
        this.marks = this.marks.filter(m => m.column >= 0);

        if (take > 0) this.renderColumns(mainHi - take, take);
        this.renderColumns(W - fill, fill);
        this.fineIndex += count;
    }

    /// Level in dB to a grey, through the current exposure.
    renderColumns(x0, count) {
        if (!this.image) return;
        const { whiteDB, blackDB, autoGain, inverted } = this.exposure;
        const d = this.image.data;
        const taps = this.taps, width = this.width;

        for (let i = 0; i < count; i++) {
            const x = x0 + i;
            const ref = autoGain ? this.refs[x] : 0;
            const lo = whiteDB + ref, hi = blackDB + ref;
            const span = Math.max(hi - lo, 1e-6);   // matches the Swift
            const base = x * taps;
            for (let y = 0; y < taps; y++) {
                let t = (this.levels[base + y] - lo) / span;
                t = t < 0 ? 0 : t > 1 ? 1 : t;
                // t = 0 is white paper, t = 1 is full ink -- inverted swaps
                // the two colours, not the levels.
                const v = inverted ? Math.round(255 * t)
                                   : Math.round(255 * (1 - t));
                const p = (y * width + x) * 4;
                d[p] = d[p + 1] = d[p + 2] = v;
            }
        }
        // Marked, not uploaded.
        //
        // This used to call putImageData here -- the whole image, every time a
        // batch of columns arrived, which is 250 times a second for one new
        // column each. At 1330 x 599 that is 3.2 MB an upload and 800 MB/s of
        // pixel traffic on the thread that also has to draw, relay audio and
        // answer the user. macOS absorbs it. iOS does not: putImageData there
        // can force the whole backing store to be read back and re-uploaded,
        // and the main thread simply stops -- which looks less like a slow app
        // than like an absent one.
        //
        // The picture is only ever *seen* once a frame, so it only needs
        // uploading once a frame.
        this.imageDirty = true;
    }

    /// Re-expose everything already on screen. What the sliders call.
    remapAll() {
        this.renderColumns(0, this.width);
        this.render();
    }

    render() {
        // A drag of the spectrum's boundary, collapsed to one resize a frame.
        if (this.spectrumPending) {
            this.spectrumPending = false;
            // Unless a resize is already running and this is the `render` from
            // inside it -- which is the ordinary way a drag ends, the release
            // resizing through `onSpectrumShareChanged` before the next frame.
            // That resize has already read the new share, so there is nothing
            // left to ask for; asking anyway would hit the re-entrancy guard
            // and return without drawing, and the release would drop a frame.
            if (!this.resizing) {
                this.resize();
                // `resize` draws at the end of both its paths, so this returns
                // rather than drawing the frame twice -- except when the engine
                // has not yet said how many taps there are, where it returns
                // before either and this frame still has to be painted.
                if (this.taps) return;
            }
        }
        const ctx = this.ctx;
        const dpr = window.devicePixelRatio || 1;
        // Once a frame, and only when the picture moved -- the same condition
        // the Mac's `tick` applies. Columns are dropped while frozen, so
        // nothing arrives, so the gain holds where it was.
        if (this.columnsArrived) {
            this.updateWaveformGain();
            this.columnsArrived = false;
        }
        // Every frame, not only when the size changed.
        //
        // iOS discards a canvas's backing store under memory pressure and
        // hands it back cleared, with the transform reset to identity -- so
        // drawing in CSS pixels on a 2x display fills exactly the top-left
        // quadrant and stays that way. Setting it here costs nothing and makes
        // that impossible; setting it only on resize made it permanent.
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        const W = this.canvas.width / dpr, H = this.canvas.height / dpr;
        const plot = this.plot;

        ctx.fillStyle = getComputedStyle(this.canvas).getPropertyValue('--chrome')
                        || '#ffffff';
        ctx.fillRect(0, 0, W, H);
        ctx.fillStyle = this.exposure.inverted ? '#000' : '#fff';
        ctx.fillRect(plot.x, plot.y, plot.w, plot.h);
        // The readouts get the picture's paper too, not the page's chrome.
        //
        // Two reasons, and the second is the one that bites. They are the
        // picture's own axes stood on their sides -- the strip shares its
        // columns, the spectrum its rows -- so they belong on the same paper.
        // And their ink follows Invert, while the chrome follows the system's
        // light or dark: black ink on dark chrome, and white ink on light, are
        // both invisible, and between them that is half of the four
        // combinations. The Mac has no such problem, its spectrum being a
        // transparent window over whatever is behind the app.
        if (this.showsWaveform) {
            const r = this.waveformRect;
            ctx.fillRect(r.x, r.y, r.w, r.h);
        }
        const specW = this.spectrumWidth;
        // Overlapping the picture's paper by a pixel rather than abutting it.
        // `plot.x + plot.w` is fractional whenever the canvas width over the
        // device ratio is, and two fills sharing a fractional edge each cover
        // part of the device column between them -- which composites to a
        // hairline of page chrome down the whole height of the join. The
        // overlap is the same colour and is painted before anything else.
        if (specW > 0) {
            ctx.fillRect(plot.x + plot.w - 1, plot.y, specW + 1, plot.h);
        }

        if (this.width && this.taps) {
            if (this.imageDirty) {
                this.bctx.putImageData(this.image, 0, 0);
                this.imageDirty = false;
            }
            // One tap, one row, no resampling: the whole point is harmonics
            // sitting one or two taps apart, and interpolation destroys
            // exactly that.
            ctx.imageSmoothingEnabled = false;
            ctx.drawImage(this.bitmap, 0, 0, this.width, this.taps,
                          plot.x, plot.y, plot.w, plot.h);
        }
        // Where the time scale changes. Not a mark -- marks travel with the
        // picture and this is a property of the window -- and drawn in the ink
        // colour rather than a mark colour for that reason: it is a fixed edge
        // of the instrument, not an event in the recording.
        const bx = this.boundaryX;
        if (bx !== null) {
            const dpr = window.devicePixelRatio || 1;
            ctx.fillStyle = this.exposure.inverted ? '#fff' : '#000';
            ctx.fillRect(Math.round(bx * dpr) / dpr, plot.y, 1 / dpr, plot.h);
        }
        this.drawWaveform();
        this.drawSpectrum(plot);
        this.drawMarks(plot);
        this.drawFrequencyScale(plot);
        this.drawReadout(plot);
    }

    // ---- the waveform strip ------------------------------------------------
    //
    // The sound the picture was made from, directly above it and sharing its
    // columns: one screen column of strip stands over the same span of time as
    // the column of picture beneath it, at whichever of the two time scales
    // that column is drawn at.
    //
    // The numbers come from the engine, which delays them by the same amount
    // de-skew holds the taps back -- so the two line up whatever de-skew is set
    // to, and across a change of it, without anything here compensating. That
    // also makes the display its own check: with de-skew on, a click's spike
    // should sit directly above the vertical edge it draws; with it off, above
    // the top of the slanted one.
    //
    // ---- how tall the waveform is drawn ------------------------------------
    //
    // Not a fixed scale, and not a fixed factor against the exposure either.
    // Both were tried in the Mac app, and the trouble with any constant is that
    // the two scales are not commensurate and cannot be made so: the picture's
    // decibels are a *tap's* held peak after filtering, the strip's are the
    // input's raw excursion, and what lies between them depends on the signal. A
    // pure tone puts nearly all of itself into one tap and reads high; speech,
    // spread across hundreds of filters, reads about 28 dB below its own peak
    // excursion. Noise would want a third number and a narrower ERB a fourth.
    //
    // So the gain is taken from the picture, which already contains the answer.
    // The rule is the one the eye wants: **a picture with solid black in it
    // draws a full-range waveform; a white picture draws a flat line**, and
    // everything between is proportional. Whatever the signal, and wherever
    // Sensitivity, Range and ERB are set, the strip fills when the picture is
    // dark -- because it is scaled by how dark the picture actually came out
    // rather than by a prediction of how dark it ought to be.
    //
    // Which makes it an automatic gain control, and it behaves like one: quick
    // to catch a loud moment, slow to let go of it, so the shape does not
    // breathe on every syllable.
    //
    // The four constants it runs on are at the top of the file, beside the
    // rest of the numbers this display is tuned by.

    /// Run the controller once for this frame.
    updateWaveformGain() {
        const now = performance.now() / 1000;
        // Clamped, and that matters more than it looks. The frame callback
        // stops while the tab is in the background and while the picture is
        // frozen, so the next call can arrive minutes later -- and exp(-dt/tau)
        // then underflows to zero, which replaces both trackers outright with
        // one frame's values. That is the opposite of holding the gain the
        // display froze at. A tenth of a second is several frames of catching up
        // and no more.
        const dt = this.agcTick > 0
                 ? Math.min(Math.max(now - this.agcTick, 0), 0.1) : 0;
        this.agcTick = now;

        // What the darkest tap of this batch is drawn at, under whichever
        // reference the picture is using.
        const { whiteDB, blackDB, autoGain } = this.exposure;
        const span = Math.max(blackDB - whiteDB, 1e-6);
        const ref = autoGain ? this.autoRef : 0;
        let ink = 0;
        if (this.batchPeakDB > -Infinity) {
            const t = (this.batchPeakDB - ref - whiteDB) / span;
            ink = t < 0 ? 0 : t > 1 ? 1 : t;
        }

        // One coefficient, decided by where the *gain* is going, and applied to
        // both quantities.
        //
        // Following them independently was the first attempt and it pumps: ink
        // attacks in fifty milliseconds while excursion is still holding a loud
        // moment for two seconds, so a broadband passage followed by a quiet
        // tone drops the scale by half in a single frame and everything still on
        // screen jumps taller. With one coefficient the ratio moves
        // monotonically towards its target and cannot overshoot, because a
        // common rise or fall leaves it unchanged.
        const target = fullScale(this.batchExcursion, ink);
        const tau = target > this.waveformFullScale
                  ? WAVEFORM_SCALE_UP : WAVEFORM_SCALE_DOWN;
        const a = Math.exp(-dt / tau);
        this.trackedInk = ink + (this.trackedInk - ink) * a;
        this.trackedExcursion = this.batchExcursion
                              + (this.trackedExcursion - this.batchExcursion) * a;

        this.batchPeakDB = -Infinity;
        this.batchExcursion = 0;
    }

    /// The input amplitude that reaches the top of the strip.
    ///
    /// The excursion belonging to the picture's darkest ink, divided by how dark
    /// that ink is. At full black the two cancel and the strip is filled; at
    /// half ink it reaches half height; as the picture whitens the divisor
    /// floors while the excursion keeps falling, which is a flat line.
    get waveformFullScale() {
        return fullScale(this.trackedExcursion, this.trackedInk);
    }

    drawWaveform() {
        if (!this.showsWaveform || !this.width) return;
        if (this.columnLo.length !== this.width) return;
        const r = this.waveformRect;
        if (r.h <= 2 || r.w <= 0) return;

        const ctx = this.ctx;
        const dpr = window.devicePixelRatio || 1;
        const mid = r.y + r.h / 2;
        const half = r.h / 2;
        const sx = r.w / this.width;
        // The picture's own ink, on the picture's own paper -- see `render`.
        ctx.fillStyle = this.exposure.inverted ? '#fff' : '#000';
        // At least one CSS pixel, which is what the Mac's `max(1, 1/scale)`
        // comes to -- its units are points and a point is a CSS pixel. A rect
        // one *device* pixel tall at a fractional offset can round away to
        // nothing, and on a 2x screen it would also draw the strip's zero line
        // at half the weight the Mac draws it.
        const hair = Math.max(1, 1 / dpr);
        const snap = v => Math.round(v * dpr) / dpr;

        // One path for the whole strip, filled once. The zero line first, so a
        // silent stretch reads as silence rather than as nothing drawn.
        ctx.beginPath();
        ctx.rect(r.x, snap(mid - hair / 2), r.w, hair);

        // Nothing has been heard, so there is nothing to scale by and the zero
        // line is the whole picture. Guarded rather than left to the arithmetic:
        // the divisor is floored, so this is an exact zero rather than a NaN,
        // and dividing by it gives infinities that would draw as a solid block.
        const full = this.waveformFullScale;
        if (!(full > 0)) { ctx.fill(); return; }

        for (let x = 0; x < this.width; x++) {
            const lo = this.columnLo[x], hi = this.columnHi[x];
            // Both exactly zero is a column that was never written -- the left
            // of a freshly wiped picture. The zero line already stands for it.
            if (lo === 0 && hi === 0) continue;
            // Clamped at both edges, which is the strip's version of the
            // picture going solid black: past either end there is nothing more
            // to show. Canvas y runs down, so the input's maximum is the
            // smaller y.
            //
            // **Both** ends, which is where this parts company with the Mac.
            // There the two clamps are one-sided -- `max(-1, lo/full)` and
            // `min(1, hi/full)` -- which bounds a column that straddles zero
            // but not one lying entirely to one side of it. That is not the
            // exotic case it sounds: the gain is deliberately slow, so on the
            // first frames of a low-frequency onset `full` is still well below
            // the excursion, and at 4 ms a column can sit inside a single
            // half-cycle of a hundred-hertz tone. Its near bound then exceeds
            // full scale, the bar reaches past the end of the strip, and there
            // is no clip to stop it -- so it is drawn over the picture. The
            // Mac wants the same two characters; see the handoff.
            //
            // With both ends clamped the order cannot invert, `lo <= hi` being
            // guaranteed by the engine, so no swap is needed here.
            const clamp = v => v < -1 ? -1 : v > 1 ? 1 : v;
            const yTop = snap(mid - clamp(hi / full) * half);
            const yBot = snap(mid - clamp(lo / full) * half);
            // At least a hairline: a column whose excursion is smaller than one
            // pixel is quiet, not absent, and dropping it would make a faint
            // passage look like a gap in the recording.
            ctx.rect(snap(r.x + x * sx), yTop,
                     Math.max(sx, hair), Math.max(yBot - yTop, hair));
        }
        ctx.fill();
    }

    // ---- the spectrum ------------------------------------------------------
    //
    // The newest column, stood on its side: level runs rightward from the
    // picture's right-hand edge, which is the zero point, against the same
    // frequency scale and the same rows. A solid region rather than a line, and
    // beside the picture rather than over it -- two inks were tried over it in
    // the Mac app and neither read.
    //
    // The Mac puts this in a transparent window outside the main one, which
    // costs it nothing. A page cannot draw outside itself, so here it takes
    // width from the picture and the boundary between them can be dragged.

    /// Normalised level per tap for the newest column, tap 0 first: 0 at the
    /// exposure's white point, 1 at its black point.
    ///
    /// Exactly the mapping `renderColumns` uses, auto-gain reference included,
    /// so a level drawn mid-grey in the rightmost column reads half scale here.
    ///
    /// Clamped below and deliberately *not* above. Below the white point there
    /// is nothing to show and the trace lies on the zero line; above the black
    /// point it keeps going, because black is a scale mark here rather than a
    /// limit. The picture has nowhere to put a level past full ink. A trace has.
    spectrumTrace() {
        const taps = this.taps;
        if (!this.width || taps < 2) return null;
        if (this.levels.length !== this.width * taps) return null;
        const { whiteDB, blackDB, autoGain } = this.exposure;
        const span = Math.max(blackDB - whiteDB, 1e-6);
        const ref = (autoGain && this.refs.length === this.width)
                  ? this.refs[this.width - 1] : 0;
        const base = (this.width - 1) * taps;
        // Kept between frames rather than allocated on each: this runs sixty
        // times a second for as long as the spectrum is switched on.
        if (!this.traceRaw || this.traceRaw.length !== taps) {
            this.traceRaw = new Float64Array(taps);
        }
        const out = this.traceRaw;
        for (let y = 0; y < taps; y++) {
            const u = (this.levels[base + y] - ref - whiteDB) / span;
            out[y] = u < 0 ? 0 : u;
        }
        return out;
    }

    /// Run the integrator, from however long this frame actually took rather
    /// than from an assumed sixty a second -- so a dropped frame decays by
    /// exactly as much as the two frames it replaced, and a long gap gives a
    /// coefficient of about zero and the trace snaps to the present.
    updateTrace(raw) {
        const now = performance.now() / 1000;
        const dt = this.traceTick > 0 ? now - this.traceTick : 0;
        this.traceTick = now;
        if (!raw || !raw.length) { this.trace = []; return; }
        // A change of tap count is a different instrument. Nothing to carry.
        //
        // A copy, not the buffer itself: `raw` is reused from frame to frame,
        // and aliasing the two would make the line below read and write one
        // array. It would still run, and the smoothing would silently do
        // nothing at all.
        if (this.trace.length !== raw.length) {
            this.trace = new Float64Array(raw);
            return;
        }
        const a = Math.exp(-dt / Math.max(SPECTRUM_DECAY, 1e-4));
        for (let i = 0; i < raw.length; i++) {
            this.trace[i] = raw[i] + (this.trace[i] - raw[i]) * a;
        }
    }

    drawSpectrum(plot) {
        if (!this.showsSpectrum) return;
        this.updateTrace(this.spectrumTrace());
        const rows = this.trace.length, reach = this.spectrumReach;
        if (rows < 2 || reach <= 0 || plot.h <= 0) return;

        const ctx = this.ctx;
        // Solid: the region between the zero line and the trace, not the trace
        // alone. The zero line is the picture's right edge, so the ink starts
        // exactly where the column it describes ends.
        const zeroX = plot.x + plot.w;
        ctx.beginPath();
        ctx.moveTo(zeroX, plot.y);
        for (let i = 0; i < rows; i++) {
            // The same row-to-y as the picture: row 0 -- the highest best
            // frequency -- at the top, and each row at the centre of its band.
            const py = plot.y + (i + 0.5) / rows * plot.h;
            const px = zeroX + this.trace[i] * reach;
            // The first and last rows sit half a row in from the ends, so the
            // shape is carried straight out to the top and bottom edges rather
            // than leaving a sliver unfilled at each extreme.
            if (i === 0) ctx.lineTo(px, plot.y);
            ctx.lineTo(px, py);
            if (i === rows - 1) ctx.lineTo(px, plot.y + plot.h);
        }
        ctx.lineTo(zeroX, plot.y + plot.h);
        ctx.closePath();
        // Levels past the black point are not clipped by the arithmetic, so the
        // headroom beyond `reach` is where they go; past that the canvas's own
        // edge clips them, which cannot be helped.
        ctx.fillStyle = this.exposure.inverted ? '#fff' : '#000';
        ctx.fill();
    }

    // MARK: drawing the readout

    drawReadout(plot) {
        const ctx = this.ctx;
        const ink = '#f76b15';                        // orange, on either paper
        // Underneath the measurement, so the duration's arrows read as drawn
        // on top of the reticle rather than tangled with it.
        //
        // A line across the picture rather than a number at the pointer: the
        // question the frequency readout answers is "what is this row", and a
        // row is a horizontal thing.
        if (this.hover && this.inPlot(this.hover) && !this.frequencyHeldBack) {
            const f = this.frequencyAt(this.hover.y);
            if (f) this.drawFrequencyCursor(plot, this.hover.y, f, ink);
        }
        const m = this.measurement;
        if (m) {
            this.hairline(plot, m.anchor, ink);
            if (m.cursor !== null) {
                this.hairline(plot, m.cursor, ink);
                this.drawDimension(plot, m.anchor, m.cursor, m.y, ink);
            }
        }
        // On top of the measurement, and a different colour: the orange lines
        // say where the sound will be taken from, this one says where in it the
        // ear has got to. Two statements about the same axis, so they must not
        // be mistakable for each other. The same violet as the Mac app.
        if (this.playhead !== null) {
            const u = this.screenColumnForEngine(this.playhead);
            if (u !== null) this.hairline(plot, u, PLAYHEAD_INK);
        }
    }

    /// The horizontal line, with its frequency at the left end. The label sits
    /// inside the picture rather than in the gutter: the gutter is the fixed
    /// scale and belongs to the instrument, and a number that came and went
    /// there would be read as one of its marks.
    drawFrequencyCursor(plot, y, f, ink) {
        const text = `${Math.round(f)} Hz`;
        const w = this.chip(text, plot.x + 2, y, plot);
        const x0 = plot.x + 2 + w + 5;
        if (x0 < plot.x + plot.w) this.rule(x0, plot.x + plot.w, y, ink);
    }

    /// The duration, drawn the way a dimension is drawn on a drawing: the
    /// number in the gap, an arm from each end of it out to the line it
    /// measures, arrowheads against the lines.
    ///
    /// When the two lines are too close together for the number to fit between
    /// them the arms go outside and point inwards and the number stands clear
    /// -- the same convention, and the case fine time resolution creates
    /// constantly, since two glottal pulses can be a few pixels apart.
    drawDimension(plot, a, b, y, ink) {
        const dt = Math.abs(this.timeMs(b) - this.timeMs(a));
        const text = timeLabel(dt);
        this.ctx.font = CHIP_FONT;
        const tw = this.ctx.measureText(text).width;
        const chipW = tw + 6;
        const xa = this.xForColumn(a), xb = this.xForColumn(b);
        const xL = Math.min(xa, xb), xR = Math.max(xa, xb);
        const stub = 10;

        if (xR - xL >= chipW + 2 * stub) {
            const mid = (xL + xR) / 2;
            this.arm(mid - chipW / 2 - 1, xL, y, ink);
            this.arm(mid + chipW / 2 + 1, xR, y, ink);
            this.chip(text, mid - tw / 2 - 3, y, plot);
        } else {
            const arm = 16;
            this.arm(xL - arm, xL, y, ink);
            this.arm(xR + arm, xR, y, ink);
            let tx = xR + arm + 5;
            if (tx + chipW > plot.x + plot.w) tx = xL - arm - 5 - chipW;
            this.chip(text, tx, y, plot);
        }
    }

    /// Milliseconds from the left edge of the picture to a fractional column.
    ///
    /// Piecewise, because with the close-up open the picture has two time
    /// scales: the main region runs at the Speed setting and the strip on the
    /// right at that divided by `aggregate`. Expressing both as a distance
    /// from one origin means a difference is a subtraction even when the two
    /// lines are on opposite sides of the boundary -- which is exactly the
    /// measurement the close-up makes people want to take.
    timeMs(u) {
        const near = this.nearDrawn;
        const far = this.width - near;
        if (!near || u <= far) return u * this.columnMs;
        return far * this.columnMs
             + (u - far) * this.columnMs / Math.max(1, this.aggregate);
    }

    /// One device pixel, snapped to the pixel grid so it cannot straddle two
    /// and be antialiased into invisibility -- the same care the marks take.
    rule(x0, x1, y, colour) {
        const dpr = window.devicePixelRatio || 1;
        const ctx = this.ctx;
        ctx.fillStyle = colour;
        ctx.fillRect(Math.min(x0, x1), Math.round(y * dpr) / dpr,
                     Math.abs(x1 - x0), 1 / dpr);
    }

    /// A vertical line the full height of the picture.
    hairline(plot, u, colour) {
        const dpr = window.devicePixelRatio || 1;
        const lw = 1 / dpr;
        let x = Math.round(this.xForColumn(u) * dpr) / dpr;
        x = Math.min(Math.max(x, plot.x), plot.x + plot.w - lw);
        this.ctx.fillStyle = colour;
        this.ctx.fillRect(x, plot.y, lw, plot.h);
    }

    /// An arm of the dimension line: a rule from x0 to x1 with a filled
    /// arrowhead at the x1 end.
    arm(x0, x1, y, colour) {
        this.rule(x0, x1, y, colour);
        const dpr = window.devicePixelRatio || 1;
        const yy = Math.round(y * dpr) / dpr + 0.5 / dpr;
        const dir = x1 >= x0 ? 1 : -1;
        const len = 7, half = 3;
        const ctx = this.ctx;
        ctx.fillStyle = colour;
        ctx.beginPath();
        ctx.moveTo(x1, yy);
        ctx.lineTo(x1 - dir * len, yy - half);
        ctx.lineTo(x1 - dir * len, yy + half);
        ctx.closePath();
        ctx.fill();
    }

    /// A label on a patch of paper, so it is legible over ink. Returns its
    /// width, so a caller can start a line clear of it.
    ///
    /// Black text, not the orange of the lines: the lines have to be found
    /// against the picture, which is what the colour is for, but the text sits
    /// on paper that has been cleared for it, and against paper the highest
    /// contrast available is the ink the picture itself is drawn in.
    chip(text, x, y, plot) {
        const ctx = this.ctx;
        ctx.font = CHIP_FONT;
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
        const tw = ctx.measureText(text).width;
        const pad = 3, h = 15;
        let rx = Math.min(Math.max(x, plot.x), plot.x + plot.w - tw - 2 * pad);
        let ry = Math.min(Math.max(y - h / 2, plot.y), plot.y + plot.h - h);
        ctx.fillStyle = this.exposure.inverted ? 'rgba(0,0,0,0.82)'
                                               : 'rgba(255,255,255,0.82)';
        roundRect(ctx, rx, ry, tw + 2 * pad, h, 3);
        ctx.fill();
        ctx.fillStyle = this.exposure.inverted ? '#fff' : '#000';
        ctx.fillText(text, rx + pad, ry + h / 2);
        return tw + 2 * pad;
    }

    drawMarks(plot) {
        if (!this.marks.length || !this.width) return;
        const ctx = this.ctx;
        const sx = plot.w / this.width;
        // One column wide, or one device pixel, whichever is larger -- a
        // hairline at an unsnapped position straddles two pixels, each gets
        // half coverage, and antialiasing turns it pale enough to miss.
        const lw = Math.max(sx, 1 / (window.devicePixelRatio || 1));
        // Drawn in order of precedence, not in the order they were recorded.
        //
        // At a replay boundary two marks land on the same column -- the old
        // recording ended and a new one began, both true -- and whichever is
        // painted second is the one you see. That was insertion order, which
        // differed between this and the Mac app for no reason anybody chose,
        // so the same moment came out green in one and red in the other.
        // MARK_RANK is the same table in both.
        const ordered = [...this.marks].sort(
            (a, b) => (MARK_RANK[a.kind] ?? 0) - (MARK_RANK[b.kind] ?? 0));
        for (const m of ordered) {
            ctx.fillStyle = MARK_COLOURS[m.kind] || '#f00';
            let x = plot.x + m.column * sx;
            x = Math.min(Math.max(x, plot.x), plot.x + plot.w - lw);
            ctx.fillRect(x, plot.y, lw, plot.h);
        }
    }

    // ---- the frequency scale ------------------------------------------

    /// Where a frequency sits on the tap axis, interpolated between the two
    /// taps that bracket it. The measured best frequencies are not exactly
    /// geometric -- the cascade pulls each peak below its pole by a little
    /// more at one end than the other -- so assuming a constant number of taps
    /// per octave is wrong by several rows at the extremes, which is precisely
    /// where the labels that matter most are.
    rowFor(f) {
        const cf = this.frequencies, n = cf.length;
        if (f >= cf[0]) {
            const span = Math.log(cf[0] / cf[1]);
            return span > 0 ? -Math.log(f / cf[0]) / span : 0;
        }
        if (f <= cf[n - 1]) {
            const span = Math.log(cf[n - 2] / cf[n - 1]);
            return span > 0 ? (n - 1) + Math.log(cf[n - 1] / f) / span : n - 1;
        }
        let i = 0;
        while (i + 1 < n && cf[i + 1] > f) i++;
        const span = Math.log(cf[i] / cf[i + 1]);
        return i + (span > 0 ? Math.log(cf[i] / f) / span : 0);
    }

    /// Canvas y is down and bitmap row 0 is the highest frequency, which is
    /// the top -- so unlike the Mac version nothing is inverted here. The half
    /// is the row's centre rather than its top edge: a tap occupies a band.
    yForRow(row, plot) {
        return plot.y + (row + 0.5) * plot.h / this.taps;
    }

    drawFrequencyScale(plot) {
        if (!this.frequencies) return;
        const ctx = this.ctx;
        ctx.font = '9px -apple-system, BlinkMacSystemFont, sans-serif';
        ctx.textAlign = 'right';
        ctx.textBaseline = 'middle';
        ctx.fillStyle = getComputedStyle(this.canvas)
                            .getPropertyValue('--label') || '#888';

        // Octaves, not decades. A cochlea is a log-frequency instrument and
        // its structure is octave-spaced, so a scale that halves each time
        // reads against the picture instead of across it.
        const octaves = [16000, 8000, 4000, 2000, 1000, 500, 250, 125, 64, 32];
        const drawn = [];
        for (const f of octaves) {
            const y = this.yForRow(this.rowFor(f), plot);
            if (!drawn.every(v => Math.abs(v - y) >= 11)) continue;
            // Nothing is clamped into view. A label nudged to fit is a label
            // in the wrong place, which on a frequency scale is worse than a
            // gap -- it would claim the display reaches further than it does.
            // Both ends measured from the picture, not from the canvas. The
            // top used to be a literal 6, which was `plot.y - 2` back when the
            // picture always started at the top inset; with the waveform strip
            // above it, that same literal would let a label be drawn over the
            // strip, tens of pixels from the tap it names.
            if (y < plot.y - 2 || y > plot.y + plot.h - 2) continue;
            ctx.fillText(label(f), plot.x - 6, y);
            drawn.push(y);
        }
    }
}

/// Which mark wins when two land on the same column. Higher is drawn later,
/// so it is the one seen. The order is by how much the mark says: `seam` only
/// claims that time jumps, which is implied by all the others.
const MARK_RANK = {
    seam: 0, scaleChange: 1, tuningChange: 2, fileEnd: 3,
};

const MARK_COLOURS = {
    seam: '#e5484d',           // time jumps here
    scaleChange: '#0a68d0',    // milliseconds per column changed
    tuningChange: '#8e4ec6',   // filter bandwidths changed
    fileEnd: '#30a46c',        // the recording ended
};

const CHIP_FONT = '500 11px ui-monospace, SFMono-Regular, Menlo, monospace';


function timeLabel(ms) {
    if (ms < 10) return ms.toFixed(2) + ' mS';
    if (ms < 100) return ms.toFixed(1) + ' mS';
    if (ms < 1000) return ms.toFixed(0) + ' mS';
    return (ms / 1000).toFixed(2) + ' S';
}

function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
}

function label(f) {
    if (f < 1000) return String(Math.round(f));
    const k = f / 1000;
    return (k >= 10 || k === Math.round(k)) ? `${Math.round(k)}k`
                                            : `${k.toFixed(1)}k`;
}
