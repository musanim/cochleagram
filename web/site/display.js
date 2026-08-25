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

        this.resizing = false;
        this.imageDirty = false;
        this.hover = null;
        this.measurement = null;
        this.measuring = false;
        this.frequencyHeldBack = false;
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
            c.style.cursor = !this.inPlot(p) ? 'default'
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

    get plot() {
        const dpr = window.devicePixelRatio || 1;
        const w = this.canvas.width / dpr, h = this.canvas.height / dpr;
        return {
            x: this.gutter,
            y: this.topInset,
            w: Math.max(1, w - this.gutter),
            h: Math.max(1, h - this.topInset - this.bottomInset),
        };
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
        const chh = Math.max(200, Math.round(this.canvas.clientHeight));
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
        const { whiteDB, blackDB } = this.exposure;
        const span = (blackDB - whiteDB) || 1;
        const step = this.autoRateDb * this.columnMs / 1000;
        for (let j = 0; j < count; j++) {
            const base = j * taps;
            const lo = whiteDB + this.autoRef;
            let sum = 0;
            for (let y = 0; y < taps; y++) {
                let t = (levels[base + y] - lo) / span;
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
    }

    /// Take a batch of finished columns.
    append(levels, coherence, refs, count) {
        if (!this.width || !count) return;
        const taps = this.taps;
        // Always, not only when Auto gain is on: the reference then arrives
        // already settled when it is switched on, instead of spending several
        // seconds finding the room from a standing start.
        this.autoExpose(levels, refs, count);

        // Belt and braces: everything below indexes it as `width` long, and it
        // is written in more places than `refs` is.
        if (this.fine.length !== this.width) {
            this.fine = new Float64Array(this.width).fill(-1);
        }

        const near = this.nearDrawn;
        if (near > 0) { this.appendTwoBases(levels, coherence, refs, count, near); return; }

        // The engine index of levels[c] is `first + c`.
        const first = this.fineIndex;
        if (count >= this.width) {
            // More arrived than fit: keep the newest screenful.
            this.marks.length = 0;         // nothing older survived
            const skip = count - this.width;
            this.levels.set(levels.subarray(skip * taps));
            this.coherence.set(coherence.subarray(skip * taps));
            this.refs.set(refs.subarray(skip));
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
        this.fine.copyWithin(0, n);
        this.levels.set(levels.subarray(0, n * taps), (this.width - n) * taps);
        this.coherence.set(coherence.subarray(0, n * taps), (this.width - n) * taps);
        this.refs.set(refs.subarray(0, n), this.width - n);
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
    appendTwoBases(levels, coherence, refs, count, near) {
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

        if (take > 0) {
            this.shiftPlane(this.levels, 0, mainHi, take);
            this.shiftPlane(this.coherence, 0, mainHi, take);
            this.refs.copyWithin(0, take, mainHi);
            this.fine.copyWithin(0, take, mainHi);
            this.shiftPixels(0, mainHi, take);
            this.levels.set(keepL, (mainHi - take) * taps);
            this.coherence.set(keepC, (mainHi - take) * taps);
            this.refs.set(keepR, mainHi - take);
            this.fine.set(keepF, mainHi - take);
        }

        const fill = Math.min(count, near);
        const skip = count - fill;
        this.shiftPlane(this.levels, mainHi, W, fill);
        this.shiftPlane(this.coherence, mainHi, W, fill);
        this.refs.copyWithin(mainHi, mainHi + fill, W);
        this.fine.copyWithin(mainHi, mainHi + fill, W);
        this.shiftPixels(mainHi, W, fill);
        this.levels.set(levels.subarray(skip * taps, count * taps), (W - fill) * taps);
        this.coherence.set(coherence.subarray(skip * taps, count * taps), (W - fill) * taps);
        this.refs.set(refs.subarray(skip, count), W - fill);
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
        const ctx = this.ctx;
        const dpr = window.devicePixelRatio || 1;
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
        this.drawMarks(plot);
        this.drawFrequencyScale(plot);
        this.drawReadout(plot);
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
            if (y < 6 || y > plot.y + plot.h - 2) continue;
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
