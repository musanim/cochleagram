import AppKit

/// What an untouched column reads. Far below any usable floor, so a bitmap
/// that has been allocated but not yet filled renders as silence.
private let kSilentDB: Float = -600   // matches kTinyLevel in cochlea.cpp

/// The same idea for coherence. Real values are a few hundredths of a cycle,
/// so anything at or below this is "never written" rather than a measurement;
/// without it a wiped screen renders solid red, that being what the far
/// negative end of the colour ramp is.
private let kNoCoherence: Float = -1000

/// Scrolling cochleagram: one tap per pixel row, no interpolation anywhere.
///
/// Resampling the image vertically destroys the very thing worth looking at --
/// individual harmonics sitting one or two taps apart -- so the backing bitmap
/// is exactly `tapCount` rows tall and is drawn with interpolation off.
final class CochleagramView: NSView {

    /// Set through `adopt(_:join:)`, so that every replacement has to say
    /// what kind of join it is.
    private(set) var cochlea: Cochlea?
    var showGrid = true { didSet { needsDisplay = true } }

    /// Frozen display. New columns are discarded rather than queued when
    /// `discardWhilePaused` is set, which is what live input wants -- the world
    /// carries on whether we are looking or not. File playback pauses the
    /// player instead, so nothing is produced and nothing is lost.
    var isPaused = false {
        didSet {
            Log.say("PAUSE \(isPaused) (discardWhilePaused=\(discardWhilePaused)) "
                    + "bitmap \(width)x\(height) view \(Int(bounds.width))")
            // A measurement is anchored to a column of a frozen picture. Once
            // the picture starts moving again the two lines are over whatever
            // has scrolled into their place, which is not what was measured.
            if !isPaused { clearMeasurement() }
            needsDisplay = true
        }
    }
    var discardWhilePaused = true

    /// Why a vertical line is on the picture.
    ///
    /// Hoisted out of `Mark` so a caller can name a join without the mark list
    /// itself being visible.
    enum MarkKind {
        /// Time jumps here. Live input cannot be paused, only ignored: the
        /// columns arriving while the display is frozen are thrown away, so
        /// resuming butts together two moments that were never adjacent.
        /// Without a mark the picture claims a continuity it does not have,
        /// which is the one lie an analysis display must not tell. Pausing a
        /// *file* loses nothing, so it is not marked.
        case seam
        /// The horizontal scale changes here. Everything left of it was drawn
        /// at a different number of milliseconds per column, so widths either
        /// side are not comparable.
        case scaleChange
        /// The tuning changes here: the filters either side have different
        /// bandwidths, so frequency resolution differs across the line.
        /// Changing tuning also restarts the source -- a file goes back to
        /// its beginning -- so time is not continuous here either. This mark
        /// names the reason; it does not promise continuity.
        case tuningChange
        /// A file played to its end here. Not a gap in time either -- it is
        /// the boundary of the recording, and worth telling apart from
        /// whatever arrives next.
        case fileEnd

        /// Which mark wins when two land on the same column. Higher is drawn
        /// later, so it is the one seen. The order is by how much the mark
        /// says: `seam` only claims that time jumps, which is implied by all
        /// the others.
        var rank: Int {
            switch self {
            case .seam:         return 0
            case .scaleChange:  return 1
            case .tuningChange: return 2
            case .fileEnd:      return 3
            }
        }

    }

    /// Places where the picture stops meaning what it meant, in bitmap
    /// columns. All of them ride along with the image, so a mark stays on the
    /// moment it describes and scrolls off with it.
    private struct Mark {
        var column: Int
        let kind: MarkKind
        var color: NSColor {
            switch kind {
            case .seam:         return .systemRed
            case .scaleChange:  return .systemBlue
            case .tuningChange: return .systemPurple
            case .fileEnd:      return .systemGreen
            }
        }
    }
    private var marks: [Mark] = []

    /// Diagnostics for the on-screen readout. A resize right-aligns existing
    /// content, so every resize shifts the picture sideways -- if one happens
    /// at a moment the user did not resize the window, that is the bug.
    private var resizeCount = 0
    private var lastResize = "-"
    private var lastTake = 0
    private var maxTake = 0
    var showDiagnostics = false { didSet { needsDisplay = true } }

    /// The picture, in decibels relative to full scale -- one float per tap
    /// per column, plus the auto-gain reference that applied to each column.
    ///
    /// This is what the display *is*; `pixels` is a cache of how it currently
    /// looks. Keeping the levels is what lets Gain, Level, Invert and Auto
    /// gain re-expose everything already on screen instead of only affecting
    /// columns that have yet to arrive -- which matters most when the display
    /// is frozen at the end of a file and there are no new columns at all.
    ///
    /// A screenful is about 3.6 MB. Storing dB rather than linear level is
    /// the point: re-mapping is then a subtract, a scale and a clamp per
    /// pixel, with no logarithm, so a whole screen costs a millisecond or two
    /// and dragging a slider feels continuous.
    /// Stored **column-major**: all `height` taps of column x are contiguous
    /// at `x * height`. The bitmap has to be row-major because that is what
    /// `CGImage` reads, but nothing else does.
    ///
    /// It was row-major to match, and that made appending a column write 599
    /// addresses 4.4 kB apart -- a cache miss per tap -- and scrolling do 599
    /// separate `memmove`s. Neither mattered at 250 columns a second. Close-up
    /// runs the engine five times faster and it stopped being invisible: the
    /// main thread managed one frame in the first second. Column-major makes
    /// appending a column one contiguous copy and scrolling one `memmove`.
    // MARK: - automatic exposure
    //
    // The engine tracks a reference too, but it is a peak follower: it rises
    // to the loudest tap at once and decays back. In a quiet room the loudest
    // tap *is* the noise floor, so the reference sinks to meet it and the whole
    // window ends up below the noise -- the picture goes solid black, having
    // faithfully exposed for a signal that is not there.
    //
    // This aims at a property of the picture instead: keep the average pixel
    // about 30% of the way to full ink. It cannot run away, because the thing
    // it measures is the thing it controls, and it does not care whether the
    // level it is looking at is signal or noise -- only whether there is a
    // legible amount of ink on the paper.
    /// The colour behind the picture: gutter, margins, status strip.
    ///
    /// Not `windowBackgroundColor`, which is very nearly white in the light
    /// appearance and so left the frame and the paper indistinguishable -- the
    /// plot appeared to run to the edge of the window. These are the browser
    /// version's `--chrome`, and the two now match; a screenshot of one can be
    /// put beside a screenshot of the other without the difference in framing
    /// reading as a difference in the picture.
    private static let chrome = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0x1c/255.0, green: 0x1c/255.0, blue: 0x1f/255.0, alpha: 1)
            : NSColor(red: 0xf2/255.0, green: 0xf2/255.0, blue: 0xf5/255.0, alpha: 1)
    }

    private var autoRef: Float = 0

    /// What Auto gain has arrived at, in dB. The toolbar's Sensitivity control
    /// reports this while Auto gain is on, so that the setting in force is
    /// visible rather than merely in effect. Read-only: the controller owns it.
    var autoReferenceDB: Double { Double(autoRef) }

    /// Start the reference again from nothing.
    ///
    /// For the moment Auto gain is switched off: the caller folds the
    /// reference into Sensitivity, which makes the correct reference zero, and
    /// leaving the old value here would apply it twice the next time Auto gain
    /// came back on.
    func resetAutoReference() { autoRef = 0 }

    /// Mean ink to aim for. 0 is blank paper, 1 is solid.
    private let autoTargetInk: Float = 0.30
    /// How fast the reference chases it, in dB per second at full error. Slow
    /// enough not to pump on speech, fast enough to follow a room.
    private let autoRateDB: Float = 25

    private var levels = [Float]()
    /// The other half of the picture: coherence, in cycles, same shape as
    /// `levels`. Kept whichever mode is showing, for the same reason the
    /// levels are kept -- so changing what is drawn re-renders the screen
    /// rather than wiping it and waiting for the sound to come round again.
    private var coherence = [Float]()
    private var columnRefs = [Float]()

    /// Which engine column each screen column was drawn from.
    ///
    /// Carried so that a position on screen can be turned back into a position
    /// in the recorded audio -- what RePlay needs, and the only way to get it
    /// that survives the two things the picture routinely does to its own time
    /// base. Elapsed time will not do: the picture is *not* wiped when the
    /// Speed detent changes, because keeping what is already drawn is worth
    /// more than the mixed scale costs, so the columns on either side of a
    /// scale mark stand for different numbers of milliseconds and no single
    /// figure describes the display. And with the close-up on there are two
    /// time bases on screen at once by design. There is always, though, exactly
    /// one engine column behind every screen column, whatever scale it was
    /// drawn at -- so the close-up needs no special case here, and neither does
    /// a scale change. See REPLAY-DESIGN.md.
    ///
    /// Shifted wherever `columnRefs` is shifted, and for the same reason: it is
    /// anchored to content, not to the screen.
    private var columnFine = [Int64]()

    /// How the levels currently look. Rebuilt incrementally as columns
    /// arrive, and wholesale when the mapping changes.
    private var pixels = [UInt8]()
    private var width = 0
    private var height = 0

    /// The level-to-grey mapping. Setting any of it re-renders everything.
    struct Exposure: Equatable {
        /// The two ends of the mapping, in dB. Below `whiteDB` everything is
        /// white; above `blackDB` everything is black; between them the curve
        /// below. Under Invert the two colours swap -- the levels do not.
        /// Overwritten from `Settings` before anything is drawn, by the
        /// `applyToEngine` that follows every engine build. Kept in step with
        /// those defaults all the same: if the engine never builds -- a denied
        /// microphone, a missing coefficient file -- this is what the window
        /// is showing, and it should not be an older idea of the picture.
        var whiteDB: Double = -180
        var blackDB: Double = -10
        /// Measure both against the engine's tracked reference rather than
        /// against full scale.
        var autoGain = false
        /// false = dark ink on white paper, the original look.
        var inverted = false
        /// Which quantity the picture is drawn from. `whiteDB`, `blackDB`
        /// and `autoGain` apply in both: under `.coherence` they set opacity
        /// rather than grey, so the range slider goes on meaning the same
        /// thing -- what is white in Amplitude is paper here, and what is
        /// black is full colour.
        var mode: DisplayMode = .amplitude
        /// Half-width of the coherence hue ramp, in cycles: `-span` is red,
        /// zero is green and `+span` is blue.
        ///
        /// The number is a *signed deviation* from the phase step the
        /// filterbank imposes on neighbouring taps by itself, so zero is the
        /// meaningful centre rather than an end. On white noise the deviation
        /// sits within about ±0.05 of a cycle across the whole display, which
        /// is where this default comes from; a wider span puts everything at
        /// green.
        var coherenceSpan: Double = 0.05

        /// How far from the middle of the ramp each colour has faded out
        /// completely, as a fraction of the half-span. The two knees sit at
        /// `0.5 ± knee` on the normalised ramp: red at one end fades to
        /// neutral by `0.5 - knee` and green climbs back from there, and the
        /// same mirrored above.
        ///
        /// Smaller narrows green and widens red and blue; larger does the
        /// reverse. It cannot narrow all three at once -- that needs a neutral
        /// *band* rather than a neutral point, which is a second parameter and
        /// a later question. 0.25 puts the knees at the midpoints; 0.08 leaves
        /// green a thin band and gives most of the picture to the neutral,
        /// which is where this reads as most informative.
        var coherenceKnee: Double = 0.08
    }
    var exposure = Exposure() {
        didSet {
            guard exposure != oldValue else { return }
            remapAll()
            needsDisplay = true
        }
    }
    /// The bitmap is RGB even in Amplitude, where all three components are
    /// equal. One buffer and one image path is worth more than the three
    /// bytes: the alternative was two of everything -- two allocations, two
    /// scrolls, two `CGImage` constructions -- differing only in stride, which
    /// is exactly the kind of pair that drifts.
    private let bytesPerPixel = 3
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// The four category inks, matched in perceived darkness.
    ///
    /// Full-strength red, green and blue are nothing like equally dark. Their
    /// relative luminances are 0.213, 0.715 and 0.072, so against white paper
    /// pure green has a contrast ratio of 1.37:1 and is barely there, red
    /// manages 4.0:1, and blue 8.6:1 dominates both. In a display where the
    /// colour is a *category* that is a lie about importance: the eye reads
    /// the blue as the strong finding and the green as almost nothing, when
    /// they mean equally much.
    ///
    /// So all four are matched to the darkest one that cannot be made darker
    /// without ceasing to be itself -- pure blue, luminance 0.0722, L* 32.3.
    /// Red comes down to 158, green to 89, and the neutral becomes a grey of
    /// 76 rather than black. Measured contrast against white is then 8.56,
    /// 8.65, 8.59 and 8.59 to one.
    ///
    /// Matching luminance also makes them equal against a *black* paper, since
    /// contrast either way is a function of luminance alone -- though all four
    /// are then equally dim, which is a separate problem for Invert.
    private struct CategoryInk {
        let r0: Float, g0: Float, b0: Float     // early -- transient
        let r1: Float, g1: Float, b1: Float     // on time -- tone
        let r2: Float, g2: Float, b2: Float     // late -- noise
        let rn: Float, gn: Float, bn: Float     // neutral
    }
    ///
    /// Green then sits a little above the matched value by choice rather than
    /// by arithmetic: 100 instead of 89, L* 36.2 against 32.3, contrast 7.4:1
    /// against 8.6:1. Deliberately small -- one step on the ladder below --
    /// and the reason it is written here rather than derived is that it is a
    /// judgement about how the picture reads, not a measurement.
    ///
    ///     89  L* 32.1  8.65:1      110  L* 39.8  6.50:1
    ///     95  L* 34.4  7.96:1      116  L* 42.0  6.00:1
    ///    100  L* 36.2  7.44:1      124  L* 44.8  5.41:1
    ///    105  L* 38.0  6.95:1
    private static let categoryInk = CategoryInk(
        r0: 158, g0: 0,   b0: 0,
        r1: 0,   g1: 100, b1: 0,
        r2: 0,   g2: 0,   b2: 255,
        rn: 76,  gn: 76,  bn: 76)


    // MARK: - layout
    //
    // The bitmap no longer fills the view. A gutter down the left holds the
    // frequency scale and a strip along the bottom holds the readouts, so that
    // neither is drawn over the picture -- a label on top of the data hides
    // exactly the taps it is there to identify.

    /// The frequency scale's column. It runs the full height of the view and
    /// holds nothing else, so a label can sit at its tap's true position even
    /// when that is the very first or very last row -- which is exactly where
    /// 20 Hz and 20 kHz land, being both decade marks and the two ends of the
    /// cascade. Without ticks it needs only the width of "20k" and a margin.
    private let gutter: CGFloat = 28
    /// Tall enough for a 10 pt line with a little room.
    private let statusHeight: CGFloat = 18
    /// Room above the picture for the top label's overhang. Half a line.
    private let plotTopInset: CGFloat = 7

    /// Where the cochleagram itself goes. The view is y-up and unflipped, so
    /// the status strip occupies the bottom of the coordinate space and the
    /// picture sits above it.
    private var plotRect: CGRect {
        CGRect(x: gutter, y: statusHeight,
               width: max(1, bounds.width - gutter),
               height: max(1, bounds.height - statusHeight - plotTopInset))
    }

    /// How many columns are on screen, so the caller can say how much time
    /// that is without knowing anything about the gutter.
    var columnCount: Int { width }

    // Deliberately NOT flipped. In a y-up context CGContext.draw puts a
    // CGImage's first row at the top of the rect, and our first row is tap 0,
    // the highest frequency -- which is where it belongs. Flipping the view
    // would mirror the display vertically.
    override var isOpaque: Bool { true }

    // MARK: - bitmap

    /// Take on a new engine, keeping the picture where that is meaningful.
    ///
    /// Every source change builds a fresh `Cochlea` -- a file, a device, a
    /// different sample rate. But the *picture* only becomes meaningless if
    /// the geometry changes, and the tap count comes from the coefficient
    /// file, so it almost never does. Wiping on every source change threw away
    /// the thing you had just been looking at: play a file, and the moment it
    /// ended and the microphone came back, the file's cochleagram vanished.
    ///
    /// So the pixels are kept and the join is marked instead -- switching
    /// source butts together two moments that were never adjacent, which is
    /// exactly what a seam is for, and the same thing pausing live input does.
    func adopt(_ c: Cochlea?, join: MarkKind) {
        cochlea = c
        adoptCochlea(join)
    }

    private func adoptCochlea(_ join: MarkKind) {
        // Taken from whatever engine we are now on, rather than zeroed. A new
        // engine does start its count at zero, but a *reused* one -- which is
        // what a Replay at the same tuning now gets -- carries its running
        // total. Zeroing here would make the next `tick` find a total already
        // above the high-water mark, log a drop that did not happen, and paint
        // a spurious seam beside the genuine join, on every replay.
        lastDropped = cochlea?.droppedColumns ?? 0
        // Engine columns drawn since this join went down. Against the samples
        // the tap has delivered, this says whether a mark placed "on the
        // newest column" is where the audio actually is.
        columnsSinceJoin = 0
        let taps = cochlea?.tapCount ?? 0
        guard taps > 0 else {
            height = 0
            width = 0
            pixels = []
            levels = []
            columnRefs = []
            columnFine = []
            marks.removeAll()
            return
        }
        if taps == height, width > 0, !pixels.isEmpty {
            Log.say("COCHLEA replaced, same \(taps) taps — keeping the "
                    + "picture, marking the join as \(join)")
            mark(join)
            return
        }
        // Geometry changed, so nothing already drawn is comparable. This
        // needs a different tap count -- ERB scale does not change it, only
        // taps-per-octave or the frequency range would.
        Log.say("COCHLEA \(height) -> \(taps) taps — wiping the picture")
        height = taps
        marks.removeAll()
        width = 0                       // force syncSize to allocate
        syncSize()
    }

    /// Keep the bitmap exactly as wide as the plot, in points.
    ///
    /// This used to live only in `setFrameSize`, which was a mistake with two
    /// faces. If the cochlea arrived before layout -- which happens whenever
    /// microphone permission has already been granted, because then the
    /// callback is synchronous -- the bitmap was sized against an empty
    /// `bounds`. And `setFrameSize` bailed out early when height was still 0,
    /// so the real width was never recorded. Either way the image ended up
    /// being stretched across a window it did not match, which is what made
    /// the picture appear to jump sideways, and it put marks in a coordinate
    /// space that no longer lined up with anything on screen.
    ///
    /// Called from everything that can change the geometry or consume the
    /// bitmap -- `layout`, `setFrameSize`, `viewDidMoveToWindow`, `tick` and
    /// `mark` -- so there is no ordering left to get wrong. Never from
    /// `draw`: reallocating mid-pass draws a frame against stale geometry.
    private func syncSize() {
        guard height > 0 else { return }
        let w = max(64, Int(plotRect.width.rounded()))
        guard w != width else { return }

        var next = [UInt8](repeating: 0, count: w * height * bytesPerPixel)
        var nextLevels = [Float](repeating: kSilentDB, count: w * height)
        var nextCoh = [Float](repeating: kNoCoherence, count: w * height)
        var nextRefs = [Float](repeating: 0, count: w)
        // -1 for "no engine column was ever drawn here", which is what the
        // freshly exposed columns of a widened window are. Distinct from 0,
        // which is a real column: the first one after a wipe.
        var nextFine = [Int64](repeating: -1, count: w)
        var keptFrom = w                 // first column that has to be rendered
        if width > 0, !pixels.isEmpty {
            // Keep the right-hand (most recent) part of the old image.
            let keep = min(w, width)
            keptFrom = w - keep
            // Element by element, this was the reason a drag felt like mud:
            // AppKit sends a resize per mouse event, and each one was copying
            // about three million array elements through bounds checks. As
            // block copies it is a few memcpys. Levels and coherence are one
            // contiguous run of columns; the bitmap is still row-major and
            // still has to go a row at a time.
            let floats = keep * height * MemoryLayout<Float>.size
            nextLevels.withUnsafeMutableBufferPointer { d in
                levels.withUnsafeBufferPointer { sp in
                    guard let dp = d.baseAddress, let s0 = sp.baseAddress else { return }
                    memcpy(dp + (w - keep) * height,
                           s0 + (width - keep) * height, floats)
                }
            }
            nextCoh.withUnsafeMutableBufferPointer { d in
                coherence.withUnsafeBufferPointer { sp in
                    guard let dp = d.baseAddress, let s0 = sp.baseAddress else { return }
                    memcpy(dp + (w - keep) * height,
                           s0 + (width - keep) * height, floats)
                }
            }
            let bpp = bytesPerPixel
            next.withUnsafeMutableBufferPointer { d in
                pixels.withUnsafeBufferPointer { sp in
                    guard let dp = d.baseAddress, let s0 = sp.baseAddress else { return }
                    for y in 0..<height {
                        memcpy(dp + (y * w + (w - keep)) * bpp,
                               s0 + (y * width + (width - keep)) * bpp,
                               keep * bpp)
                    }
                }
            }
            // Length checked, like `columnFine` below. A raw memcpy out of an
            // array shorter than `width` is an out-of-bounds read that shows up
            // as a wrong exposure somewhere else entirely; no path produces one
            // today, and this is a cheap way of keeping it that way.
            if columnRefs.count == width {
                nextRefs.withUnsafeMutableBufferPointer { d in
                    columnRefs.withUnsafeBufferPointer { sp in
                        guard let dp = d.baseAddress, let s0 = sp.baseAddress
                        else { return }
                        memcpy(dp + (w - keep), s0 + (width - keep),
                               keep * MemoryLayout<Float>.size)
                    }
                }
            }
            if columnFine.count == width {
                nextFine.withUnsafeMutableBufferPointer { d in
                    columnFine.withUnsafeBufferPointer { sp in
                        guard let dp = d.baseAddress, let s0 = sp.baseAddress
                        else { return }
                        memcpy(dp + (w - keep), s0 + (width - keep),
                               keep * MemoryLayout<Int64>.size)
                    }
                }
            }
            // Seams are anchored to content, so they move with it.
            let delta = w - width
            marks = marks.compactMap {
                var m = $0
                m.column += delta
                return (0..<w).contains(m.column) ? m : nil
            }
            // The measurement's two lines are anchored to content in exactly
            // the same way, and a resize can happen while the picture is
            // frozen -- `tick` sizes before it looks at `isPaused`. Left
            // alone they would go on stating the same duration over different
            // audio, which is worse than losing them. Either line falling off
            // the left edge takes the whole measurement with it: half of a
            // duration is not a shorter duration.
            if var m = measurement {
                m.anchor += Double(delta)
                m.cursor = m.cursor.map { $0 + Double(delta) }
                let ends = [m.anchor] + (m.cursor.map { [$0] } ?? [])
                measurement = ends.allSatisfy { $0 >= 0 && $0 <= Double(w) }
                    ? m : nil
            }
        } else {
            marks.removeAll()
            measurement = nil
        }
        resizeCount += 1
        lastResize = "\(width)->\(w)"
        Log.say("RESIZE #\(resizeCount) bitmap \(width) -> \(w) "
                + "(view \(bounds.width)) — content right-aligned, so the "
                + "picture shifts right by \(w - width)")
        pixels = next
        levels = nextLevels
        coherence = nextCoh
        columnRefs = nextRefs
        columnFine = nextFine
        width = w
        // Whatever was just *allocated* has to be rendered, not assumed: the
        // newly exposed columns are silence, and silence is white on paper but
        // black inverted, so filling them with a constant put a white band
        // down the side of an inverted picture. Only those columns, though --
        // the pixels for the kept part were copied above and are still right,
        // and re-rendering the whole width on every mouse event was the other
        // half of why dragging an edge felt slow.
        if keptFrom > 0 { renderColumns(from: 0, count: keptFrom) }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        syncSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSize()
    }

    /// Wipe the image. Used when the source changes and when settings are
    /// reset -- not when the time scale changes, where keeping what is already
    /// drawn is worth more than the mixed scale costs.
    func clear() {
        clearMeasurement()
        // Before the guard, not after: a wipe that found nothing to wipe has
        // still ended the old numbering, and a recorder that missed the bump
        // would go on mapping columns to audio through an anchor that no longer
        // means anything.
        contentEpoch &+= 1
        playhead = nil
        guard height > 0, width > 0 else { return }
        fineIndex = 0
        levels = [Float](repeating: kSilentDB, count: width * height)
        coherence = [Float](repeating: kNoCoherence, count: width * height)
        columnRefs = [Float](repeating: 0, count: width)
        columnFine = [Int64](repeating: -1, count: width)
        renderColumns(from: 0, count: width)
        marks.removeAll()
        needsDisplay = true
    }

    /// Record a discontinuity at the newest column -- the join that the next
    /// column will land against. Called at the moment it happens, while that
    /// column is still the right-hand edge; from then on it travels with the
    /// picture like everything else.
    func markSeam() { mark(.seam) }

    /// Record a change of horizontal scale at the newest column.
    func markScaleChange() { mark(.scaleChange) }

    /// Record the end of a file at the newest column.
    func markFileEnd() { mark(.fileEnd) }

    private func mark(_ kind: MarkKind) {
        syncSize()
        guard width > 0 else { return }
        let x = width - 1
        // One line per column, and the first claim wins. A file ending and the
        // microphone coming back land on the same column -- nothing scrolls in
        // between, because the display is paused -- and the green line is the
        // more specific statement of the two, so the seam that would otherwise
        // paint over it is dropped.
        guard !marks.contains(where: { $0.column == x }) else { return }
        marks.append(Mark(column: x, kind: kind))
        Log.say("MARK \(kind) at column \(x) of \(width); "
                + "\(marks.count) mark(s) on screen")
        needsDisplay = true
    }

    /// Pull everything the engine has ready and scroll it in.
    func tick() {
        guard let c = cochlea, height == c.tapCount else { return }
        syncSize()
        guard width > 0 else { return }
        if isPaused {
            // Keep the queue from overflowing while frozen on live input.
            if discardWhilePaused { c.drainColumns { _, _, _, _ in } }
            return
        }
        // Columns the engine had to throw away because nobody was draining.
        // A display link stops firing when the window is minimised or fully
        // occluded, so this is reachable in ordinary use, and it is a gap in
        // time exactly like a pause -- mark it *before* the new columns land,
        // while the join is still the right-hand edge.
        let dropped = c.droppedColumns
        if dropped > lastDropped {
            Log.say("DROPPED \(dropped - lastDropped) columns "
                    + "(\(dropped) total) — marking a seam")
            lastDropped = dropped
            markSeam()
        }

        var pending = 0
        c.drainColumns { lv, co, rf, n in
            pending += n
            self.append(lv, co, rf, columns: n)
        }
        if pending > 0 { needsDisplay = true }
        columnsSinceJoin += pending

        // One line a second, so the log shows whether the display is keeping
        // up and whether marks are surviving.
        frames += 1
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 1.0 {
            // Sanity check on the time axis: columns per second should be
            // 1000 / columnMs. If it is not, the display's horizontal scale is
            // lying about how much time it is showing.
            let expected = 1000.0 / c.columnMilliseconds
            let ratio = Double(colsThisSecond) / expected
            let rate = String(format: "%.0f/s vs %.0f/s expected (%.2fx)",
                              Double(colsThisSecond), expected, ratio)
            Log.say("tick frames=\(frames) cols=\(rate) "
                    + "lastTake=\(lastTake) maxTake=\(maxTake) "
                    + "marks=\(marks.count) dropped=\(c.droppedColumns) "
                    + "bitmap=\(width)x\(height) plot=\(Int(plotRect.width))")
            frames = 0
            colsThisSecond = 0
            lastReport = now
        }
        colsThisSecond += pending
    }

    private var loggedFirstSeamDraw = false
    /// Last value of the engine's dropped-column counter, so `tick` can notice
    /// it moving rather than its absolute value.
    private var lastDropped: UInt64 = 0
    /// Engine columns appended since the cochlea was adopted -- not since the
    /// most recent mark, which `markSeam` and the rest place without touching
    /// this. Columns the engine *dropped* are not counted either, so a seam in
    /// the log means this figure is short by however many went with it.
    private(set) var columnsSinceJoin = 0
    private var frames = 0
    private var colsThisSecond = 0
    private var lastReport = Date()

    // MARK: - the two time bases
    //
    // With Close-up off there is one: every column the engine produces is a
    // column of the picture, and the whole bitmap scrolls together.
    //
    // With it on the engine runs `aggregate` times faster and the bitmap is
    // two regions with different scroll rates. The rightmost `closeUpColumns`
    // are the close-up, one engine column each, showing roughly the last
    // sixth of a second at full resolution. Everything to their left is the
    // ordinary picture, which advances one column for every `aggregate`
    // columns that fall off the close-up's left edge -- so a column enters at
    // the right, crosses the close-up at speed, and joins the main picture at
    // the far side having aged by exactly the close-up's span.
    //
    // Taking every `aggregate`-th column rather than averaging is deliberate:
    // it lands on the same audio instants the main display samples with
    // Close-up off, so the ordinary picture is unchanged by the feature being
    // available.

    /// Width of the close-up region in columns, or 0 when it is off.
    private(set) var closeUpColumns = 0
    /// Engine columns per column of the main picture. 1 when Close-up is off.
    private(set) var aggregate = 1
    /// Engine columns appended since the last reset, so the view can tell
    /// which of them are due to become columns of the main picture.
    private var fineIndex = 0
    /// Columns handed to the main picture on the last append, for the readout.
    private var lastPromoted = 0
    private var closeUpLogs = 0

    /// Turn the close-up on or off. The two regions cannot be reconciled
    /// across the change -- one column of the main picture would have to be
    /// unpicked into `aggregate` of the close-up, and the data to do it with
    /// was never kept -- so the picture is wiped rather than left half in one
    /// scale and half in the other.
    /// Clamped where it is *used*, not here: this can be called before the
    /// view has been laid out, and clamping against a width of zero would
    /// quietly turn the feature off at launch and leave the checkbox on.
    func setCloseUp(columns: Int, aggregate k: Int) {
        let c = max(0, columns)
        let a = max(1, k)
        guard c != closeUpColumns || a != aggregate else { return }
        // Only a change of *timing* is worth a wipe. Moving the boundary
        // leaves both regions carrying exactly what they carried before -- it
        // only changes where one ends and the other begins -- so the mixed
        // strip it creates scrolls off by itself in a fraction of a second,
        // and wiping on every step of a drag would be unusable.
        let retime = a != aggregate || (c > 0) != (closeUpColumns > 0)
        clearMeasurement()
        closeUpColumns = c
        aggregate = a
        Log.say("CLOSE-UP \(c) columns, 1 main column per \(a) engine columns")
        if retime {
            fineIndex = 0
            closeUpLogs = 0
            clear()
        } else {
            needsDisplay = true
        }
    }

    // MARK: - dragging the boundary
    //
    // The line is the control. There is no obvious place in the toolbar for
    // "how much of the recent past", and a number in a box would be a worse
    // way to answer a question you are answering by eye anyway.

    private var draggingBoundary = false
    private var dragGrab: CGFloat = 0
    /// Called when a drag finishes, so the width can be remembered. Not on
    /// every step: a drag is one decision, not fifty.
    var onCloseUpWidthChanged: ((Int) -> Void)?
    /// Turns a width the user is dragging towards into the nearest one that
    /// can actually be drawn.
    ///
    /// The view does not know the span or the Speed setting and has no
    /// business knowing them; it knows where the mouse is. So the legality is
    /// asked for rather than computed here, and the line goes exactly where
    /// the answer says -- it cannot be dragged somewhere illegal and corrected
    /// afterwards, because a control that springs back is a control that lied.
    var snapCloseUpWidth: ((Int) -> Int)?

    /// Widest the strip may be: the close-up is meant to be read against the
    /// ordinary picture, not instead of it.
    var maxCloseUpColumns: Int { max(0, width / 2) }

    /// Where the boundary is on screen, or nil when there is no close-up.
    private var boundaryX: CGFloat? {
        let near = min(closeUpColumns, max(0, width / 2))
        guard near > 0, width > 0 else { return nil }
        let plot = plotRect
        return plot.minX + CGFloat(width - near) * (plot.width / CGFloat(width))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let bx = boundaryX, abs(p.x - bx) <= 4,
              plotRect.contains(p) else {
            // Not on the boundary. On a frozen picture this begins a
            // measurement; on a moving one there is nothing to measure
            // against, so the click is somebody else's.
            if isPaused, plotRect.contains(p) {
                beginMeasurement(at: p)
            } else {
                super.mouseDown(with: event)
            }
            return
        }
        draggingBoundary = true
        measuring = false
        // Dragging the boundary clears the measurement as soon as it moves, so
        // it changes the selection just as surely as a click on the picture
        // does -- and it is reached by a mouse-down that never gets as far as
        // `beginMeasurement`. Announced here too, or a playback would carry on
        // over a selection that had quietly become a different one.
        onSelectionDisturbed?()
        dragGrab = p.x - bx
        // One mark for the whole drag, at the moment it starts: what is to the
        // left of it was drawn with the boundary somewhere else.
        markScaleChange()
    }

    override func mouseDragged(with event: NSEvent) {
        if measuring {
            extendMeasurement(to: convert(event.locationInWindow, from: nil))
            return
        }
        guard draggingBoundary, width > 0 else {
            super.mouseDragged(with: event)
            return
        }
        let plot = plotRect
        guard plot.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let sx = plot.width / CGFloat(width)
        let col = Int((((p.x - dragGrab) - plot.minX) / sx).rounded())
        let asked = min(max(0, width - col), maxCloseUpColumns)
        let want = snapCloseUpWidth?(asked) ?? asked
        guard want > 0, want != closeUpColumns else { return }
        closeUpColumns = want
        // The boundary is where the time scale changes, so moving it changes
        // what a distance across the picture means.
        clearMeasurement()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if measuring {
            // The lines stay. Reading a duration off the picture and then
            // looking at what is between them is one action, not two, and a
            // measurement that vanished when the button came up could only be
            // read while it was being made.
            measuring = false
            return
        }
        guard draggingBoundary else {
            super.mouseUp(with: event)
            return
        }
        draggingBoundary = false
        Log.say("CLOSE-UP boundary dragged to \(closeUpColumns) columns")
        onCloseUpWidthChanged?(closeUpColumns)
    }

    /// Move columns [lo, hi) of one plane left by `k`. Column-major, so this
    /// is a single move however tall the picture is.
    private func shiftPlane(_ d: UnsafeMutablePointer<Float>,
                            _ lo: Int, _ hi: Int, _ k: Int) {
        guard k > 0, hi - lo > k else { return }
        memmove(d + lo * height, d + (lo + k) * height,
                (hi - lo - k) * height * MemoryLayout<Float>.size)
    }

    private func shiftPixels(_ lo: Int, _ hi: Int, _ k: Int) {
        guard k > 0, hi - lo > k else { return }
        let bpp = bytesPerPixel
        pixels.withUnsafeMutableBufferPointer { dst in
            guard let d = dst.baseAddress else { return }
            for y in 0..<height {
                let row = d + y * width * bpp
                memmove(row + lo * bpp, row + (lo + k) * bpp,
                        (hi - lo - k) * bpp)
            }
        }
    }

    /// The reference each incoming column should be drawn against.
    ///
    /// Per column, and stored alongside the column, so that a column keeps the
    /// exposure it was drawn with. Re-exposing the whole picture every time the
    /// reference moved would make everything already on screen shimmer in step
    /// with whatever had just happened, which is a display that cannot be read
    /// while it is changing.
    ///
    /// Runs whether or not Auto gain is on, so that switching it on gives a
    /// reference that has already found the room rather than one starting from
    /// a standing start.
    private func autoExpose(_ src: UnsafePointer<Float>, columns n: Int)
    -> [Float] {
        var out = [Float](repeating: 0, count: n)
        guard height > 0 else { return out }
        let white = Float(exposure.whiteDB), black = Float(exposure.blackDB)
        let span = (black - white) == 0 ? 1 : (black - white)
        // These are *engine* columns, which under Close-up arrive `aggregate`
        // times faster than the main picture scrolls -- so the rate has to be
        // in the engine's time, not the display's, or the loop would chase
        // that much harder the moment the strip was opened.
        let engineMS = mainColumnMS / Double(max(1, aggregate))
        let step = autoRateDB * Float(engineMS / 1000.0)
        for j in 0..<n {
            let base = j * height
            let lo = white + autoRef
            var sum: Float = 0
            for y in 0..<height {
                let t = (src[base + y] - lo) / span
                sum += t < 0 ? 0 : (t > 1 ? 1 : t)
            }
            out[j] = autoRef
            // Too much ink means the window is too low, so lift it.
            let err = sum / Float(height) - autoTargetInk
            // Wide, because the reference has to carry the window from
            // wherever Sensitivity was left to wherever the signal actually
            // is, and those can be a hundred and fifty decibels apart -- a
            // MacBook and an iPad in one quiet room differ by about fifty.
            autoRef = min(250, max(-250, autoRef + step * err))
        }
        return out
    }

    private func append(_ lv: UnsafeBufferPointer<Float>,
                        _ co: UnsafeBufferPointer<Float>,
                        _ rf: UnsafeBufferPointer<Float>, columns n: Int) {
        // `rf` -- the engine's own peak-following reference -- is deliberately
        // ignored. See `autoExpose`.
        guard let src = lv.baseAddress, let srcCoh = co.baseAddress,
              n > 0, width > 0, height > 0
        else { return }
        let srcRef = autoExpose(src, columns: n)
        // Belt and braces: everything below indexes it as `width` long, and it
        // is written in more places than `columnRefs` is. A wrong length here
        // would be an out-of-bounds crash rather than a wrong picture.
        if columnFine.count != width {
            columnFine = [Int64](repeating: -1, count: width)
        }

        // Never more than half the window: the strip is now wide enough that
        // on a small window it could otherwise leave the ordinary picture a
        // sliver, and the close-up is meant to be read against that picture.
        let near = min(closeUpColumns, max(0, width / 2))
        let mainHi = width - near

        // ---- one time base -------------------------------------------------
        if near == 0 {
            let take = min(n, width)
            let skip = n - take
            levels.withUnsafeMutableBufferPointer { d in
                guard let p = d.baseAddress else { return }
                shiftPlane(p, 0, width, take)
                memcpy(p + (width - take) * height, src + skip * height,
                       take * height * MemoryLayout<Float>.size)
            }
            coherence.withUnsafeMutableBufferPointer { d in
                guard let p = d.baseAddress else { return }
                shiftPlane(p, 0, width, take)
                memcpy(p + (width - take) * height, srcCoh + skip * height,
                       take * height * MemoryLayout<Float>.size)
            }
            shiftPixels(0, width, take)
            // The engine index of in[c] is `first + c`, so the columns that
            // land are `first + skip ..< first + n`.
            let firstIn = Int64(fineIndex)
            if take < width {
                columnRefs.removeFirst(take)
                columnRefs.append(contentsOf: (0..<take).map { srcRef[skip + $0] })
                columnFine.removeFirst(take)
                columnFine.append(contentsOf:
                    (0..<take).map { firstIn + Int64(skip + $0) })
            } else {
                columnRefs = (0..<take).map { srcRef[skip + $0] }
                columnFine = (0..<take).map { firstIn + Int64(skip + $0) }
            }
            marks = marks.compactMap {
                var m = $0; m.column -= take
                return m.column >= 0 ? m : nil
            }
            renderColumns(from: width - take, count: take)
            // Advanced on this path too, now that it names the audio as well as
            // the close-up's delay line. It used to move only when the close-up
            // was on, which was harmless while nothing else read it; leaving it
            // at zero here would give every column of an ordinary picture the
            // same engine index, and RePlay would play one instant of sound
            // however wide a span was selected. Both ways into and out of the
            // two-time-base mode go through `setCloseUp`, which resets it and
            // wipes, so the two readings can never be mixed on one screen.
            fineIndex += n
            lastTake = take
            if take > maxTake { maxTake = take }
            return
        }

        // ---- two time bases -------------------------------------------------
        //
        // The close-up is a delay line `near` columns long over the engine's
        // output: the column that entered at index g leaves when the stream
        // reaches g + near, and every `aggregate`-th one becomes a column of
        // the main picture on its way out.
        //
        // Written in terms of that index rather than in terms of positions in
        // the bitmap, because a batch can be longer than the strip is wide.
        // The first version clamped the batch to the strip's width and threw
        // the rest away, which meant that whenever columns arrived faster than
        // the strip could hold them each frame replaced the whole strip
        // instead of scrolling it -- 200-pixel sections that do not join.
        let first = fineIndex                      // index of in[0]
        let leaveLo = max(0, first - near)
        let leaveHi = first - near + n             // exclusive
        var promoteG: [Int] = []
        if leaveHi > leaveLo, aggregate > 0 {
            for g in leaveLo..<leaveHi where g % aggregate == 0 {
                promoteG.append(g)
            }
        }
        // The main region cannot absorb more than its own width in one call,
        // and anything beyond that would be drawn and immediately scrolled
        // off. Bounded here rather than trusted, because an unbounded `m` is
        // an unbounded amount of copying on the main thread.
        let m = min(promoteG.count, mainHi)
        if promoteG.count > mainHi {
            promoteG.removeFirst(promoteG.count - mainHi)
        }
        if closeUpLogs < 4, m > 0 {
            closeUpLogs += 1
            Log.say("CLOSE-UP append n=\(n) first=\(first) near=\(near) "
                    + "mainHi=\(mainHi) K=\(aggregate) m=\(m) "
                    + "bitmap=\(width)x\(height) refs=\(columnRefs.count)")
        }

        // Collect the promoted columns. A column leaving the strip is usually
        // still in it, but if the batch is longer than the strip then some of
        // them arrive and leave within this one call and have to be taken
        // straight from the input.
        var keepL = [Float](repeating: 0, count: m * height)
        var keepC = [Float](repeating: 0, count: m * height)
        var keepR = [Float](repeating: 0, count: m)
        if m > 0 {
            levels.withUnsafeBufferPointer { dl in
            coherence.withUnsafeBufferPointer { dc in
                guard let pl = dl.baseAddress, let pc = dc.baseAddress else { return }
                for (i, g) in promoteG.enumerated() {
                    if g >= first {                        // still in flight
                        let c = g - first
                        let colL = src + c * height
                        let colC = srcCoh + c * height
                        for y in 0..<height {
                            keepL[i * height + y] = colL[y]
                            keepC[i * height + y] = colC[y]
                        }
                        keepR[i] = srcRef[c]
                    } else {                               // in the strip
                        let x = mainHi + (g - (first - near))
                        guard x >= mainHi, x < width else { continue }
                        for y in 0..<height {
                            keepL[i * height + y] = pl[x * height + y]
                            keepC[i * height + y] = pc[x * height + y]
                        }
                        keepR[i] = columnRefs[x]
                    }
                }
            }
            }
        }

        // Main region: scroll by however many were promoted, then write them.
        if m > 0 {
            let put = m
            levels.withUnsafeMutableBufferPointer { d in
                guard let p = d.baseAddress else { return }
                shiftPlane(p, 0, mainHi, put)
                keepL.withUnsafeBufferPointer { k in
                    guard let kp = k.baseAddress else { return }
                    memcpy(p + (mainHi - put) * height, kp + (m - put) * height,
                           put * height * MemoryLayout<Float>.size)
                }
            }
            coherence.withUnsafeMutableBufferPointer { d in
                guard let p = d.baseAddress else { return }
                shiftPlane(p, 0, mainHi, put)
                keepC.withUnsafeBufferPointer { k in
                    guard let kp = k.baseAddress else { return }
                    memcpy(p + (mainHi - put) * height, kp + (m - put) * height,
                           put * height * MemoryLayout<Float>.size)
                }
            }
            shiftPixels(0, mainHi, put)
            if put < mainHi {
                for x in 0..<(mainHi - put) { columnRefs[x] = columnRefs[x + put] }
                for x in 0..<(mainHi - put) { columnFine[x] = columnFine[x + put] }
            }
            for i in 0..<put { columnRefs[mainHi - put + i] = keepR[m - put + i] }
            // A promoted column keeps the engine index it entered the strip
            // with -- `promoteG` is that index. So a column of the main picture
            // names the first of the `aggregate` engine columns it stands for,
            // which is where in the audio it begins.
            for i in 0..<put {
                columnFine[mainHi - put + i] = Int64(promoteG[m - put + i])
            }
        }

        // Close-up region: it holds the last `near` columns of the stream,
        // whatever the batch size.
        let fill = min(n, near)
        let skip = n - fill
        levels.withUnsafeMutableBufferPointer { d in
            guard let p = d.baseAddress else { return }
            shiftPlane(p, mainHi, width, fill)
            memcpy(p + (width - fill) * height, src + skip * height,
                   fill * height * MemoryLayout<Float>.size)
        }
        coherence.withUnsafeMutableBufferPointer { d in
            guard let p = d.baseAddress else { return }
            shiftPlane(p, mainHi, width, fill)
            memcpy(p + (width - fill) * height, srcCoh + skip * height,
                   fill * height * MemoryLayout<Float>.size)
        }
        shiftPixels(mainHi, width, fill)
        if fill < near {
            for x in mainHi..<(width - fill) { columnRefs[x] = columnRefs[x + fill] }
            for x in mainHi..<(width - fill) { columnFine[x] = columnFine[x + fill] }
        }
        for c in 0..<fill { columnRefs[width - fill + c] = srcRef[skip + c] }
        // One engine column each, so the index is the stream's own.
        for c in 0..<fill {
            columnFine[width - fill + c] = Int64(first + skip + c)
        }

        // Marks travel at whichever rate the region they are in moves. One
        // that crosses the boundary lands on it: the alternative is to lose
        // it, and a seam that vanishes is worse than one a few milliseconds
        // out of place.
        marks = marks.compactMap {
            var mk = $0
            if mk.column >= mainHi {
                mk.column -= fill
                if mk.column < mainHi { mk.column = mainHi - 1 }
            } else {
                mk.column -= m
            }
            return mk.column >= 0 ? mk : nil
        }

        let take = fill
        fineIndex += n
        lastPromoted = m
        renderColumns(from: max(0, mainHi - min(m, mainHi)), count: min(m, mainHi))
        renderColumns(from: width - take, count: take)

        lastTake = take
        if take > maxTake { maxTake = take }
    }

    // MARK: - exposure
    //
    // The only place level becomes grey. Everything else in this file treats
    // `levels` as the picture and `pixels` as a cache of how it looks.

    /// Map a range of columns from `levels` into `pixels`.
    ///
    /// `u` runs 0 at `whiteDB` to 1 at `blackDB`, and the byte is its
    /// complement unless inverted, because the display is ink on paper. No
    /// logarithm: the levels are already in dB, which is the whole reason for
    /// storing them that way.
    private func renderColumns(from x0: Int, count: Int) {
        guard width > 0, height > 0, count > 0 else { return }
        let lo = max(0, x0), hi = min(width, x0 + count)
        guard lo < hi else { return }

        let inverted = exposure.inverted
        let whiteDB = Float(exposure.whiteDB)
        let span = Float(max(exposure.blackDB - exposure.whiteDB, 1e-6))
        let invSpan = 1 / span
        let auto = exposure.autoGain

        // Coherence: hue from the phase relationship, opacity from the level.
        //
        // The cycles are signed -- the engine has taken out the phase step the
        // filterbank imposes on neighbouring taps by itself -- so zero means
        // "exactly what the filterbank would do anyway" and belongs in the
        // middle of the ramp rather than at an end. A tap peaking *earlier*
        // than that reads red, later reads blue, and one locked to the same
        // driver as its neighbour reads green.
        //
        // The hue alone is a lie about quiet parts of the picture: a tap with
        // nothing in it still reports a phase, and reports it confidently. So
        // the level drives opacity, through exactly the mapping and exactly
        // the two ends that Amplitude uses -- the same `u`, the same auto-gain
        // reference. What renders white there renders as paper here and what
        // renders black renders as full colour. That also makes the dB range
        // slider live in this mode, where before it did nothing.
        //
        // Composited by hand rather than with an alpha channel: the bitmap has
        // no alpha, the paper it would blend against is a known constant, and
        // one multiply-add per component is cheaper than asking Core Graphics
        // to blend a full-screen image every frame.
        if exposure.mode == .coherence {
            let half = Float(0.5 / max(exposure.coherenceSpan, 1e-6))
            let paper: Float = inverted ? 0 : 255
            // Where each colour has given up entirely, measured from the
            // middle of the ramp. Reciprocals hoisted: this is four divisions
            // that would otherwise happen at every one of ~900,000 pixels.
            let knee = Float(min(max(exposure.coherenceKnee, 0.01), 0.49))
            let loKnee = 0.5 - knee, hiKnee = 0.5 + knee
            let invLoKnee = 1 / loKnee, invHiKnee = 1 / (1 - hiKnee)
            let invGap = 1 / knee
            let ink = CochleagramView.categoryInk
            levels.withUnsafeBufferPointer { lv in
                coherence.withUnsafeBufferPointer { cv in
                    pixels.withUnsafeMutableBufferPointer { px in
                        guard let l = lv.baseAddress, let c = cv.baseAddress,
                              let p = px.baseAddress else { return }
                        for x in lo..<hi {
                            let ref = auto ? columnRefs[x] : 0
                            let base = x * height
                            for y in 0..<height {
                                let i = base + y
                                let o = (y * width + x) * 3

                                // Opacity: 0 at the white end of the dB range,
                                // 1 at the black end. Silence is `kSilentDB`,
                                // which lands at 0, so a wiped screen is paper
                                // and needs no special case.
                                var a = (l[i] - ref - whiteDB) * invSpan
                                a = a < 0 ? 0 : (a > 1 ? 1 : a)
                                if a <= 0 {
                                    let g = UInt8(paper)
                                    p[o] = g; p[o + 1] = g; p[o + 2] = g
                                    continue
                                }

                                // Hue: 0 at -span, 0.5 at no deviation, 1 at
                                // +span. Invert flips the paper, not this --
                                // red stays red, as a category should.
                                var t = c[i] * half + 0.5
                                t = t < 0 ? 0 : (t > 1 ? 1 : t)
                                var r: Float, g: Float, b: Float
                                if t < loKnee {                  // red -> neutral
                                    let k = t * invLoKnee
                                    r = ink.r0 + (ink.rn - ink.r0) * k
                                    g = ink.g0 + (ink.gn - ink.g0) * k
                                    b = ink.b0 + (ink.bn - ink.b0) * k
                                } else if t < 0.5 {              // neutral -> green
                                    let k = (t - loKnee) * invGap
                                    r = ink.rn + (ink.r1 - ink.rn) * k
                                    g = ink.gn + (ink.g1 - ink.gn) * k
                                    b = ink.bn + (ink.b1 - ink.bn) * k
                                } else if t < hiKnee {           // green -> neutral
                                    let k = (t - 0.5) * invGap
                                    r = ink.r1 + (ink.rn - ink.r1) * k
                                    g = ink.g1 + (ink.gn - ink.g1) * k
                                    b = ink.b1 + (ink.bn - ink.b1) * k
                                } else {                         // neutral -> blue
                                    let k = (t - hiKnee) * invHiKnee
                                    r = ink.rn + (ink.r2 - ink.rn) * k
                                    g = ink.gn + (ink.g2 - ink.gn) * k
                                    b = ink.bn + (ink.b2 - ink.bn) * k
                                }
                                let bg = paper * (1 - a)
                                p[o]     = UInt8(r * a + bg + 0.5)
                                p[o + 1] = UInt8(g * a + bg + 0.5)
                                p[o + 2] = UInt8(b * a + bg + 0.5)
                            }
                        }
                    }
                }
            }
            return
        }

        // Amplitude: the same `u`, rendered as grey rather than as opacity.
        levels.withUnsafeBufferPointer { lv in
            pixels.withUnsafeMutableBufferPointer { px in
                guard let l = lv.baseAddress, let p = px.baseAddress else { return }
                for x in lo..<hi {
                    let ref = auto ? columnRefs[x] : 0
                    let base = x * height
                    for y in 0..<height {
                        let i = base + y
                        // 0 at the white end, 1 at the black end.
                        var u = (l[i] - ref - whiteDB) * invSpan
                        u = u < 0 ? 0 : (u > 1 ? 1 : u)
                        // --- the curve goes here. Linear for now; whatever
                        // replaces it acts on u in [0,1] and returns [0,1],
                        // and is the only thing that needs to change.
                        if !inverted { u = 1 - u }
                        let g = UInt8(u * 255 + 0.5)
                        let o = (y * width + x) * 3
                        p[o] = g; p[o + 1] = g; p[o + 2] = g
                    }
                }
            }
        }
    }

    /// Re-expose everything on screen. A screenful is about 900,000 pixels of
    /// subtract-scale-clamp, which is a millisecond or two -- fast enough that
    /// dragging Gain or Level feels continuous even with the display frozen at
    /// the end of a file, which is the case that motivated keeping the levels
    /// at all.
    private func remapAll() {
        renderColumns(from: 0, count: width)
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Deliberately no syncSize() here: reallocating the bitmap in the
        // middle of a draw pass is how you get a frame drawn against the wrong
        // geometry. Sizing happens in layout/tick only.
        let plot = plotRect

        // Chrome first, then the paper. The gutter and the status strip take
        // the window's own colour so they read as frame rather than as data,
        // and so they follow the system appearance; the plot is always paper
        // white, because the picture is ink on paper unless inverted.
        ctx.setFillColor(Self.chrome.cgColor)
        ctx.fill(bounds)
        // The plot's backing colour has to agree with what silence renders
        // as, or the margins disagree with the picture.
        ctx.setFillColor((exposure.inverted ? NSColor.black : .white).cgColor)
        ctx.fill(plot)

        if showGrid { drawFrequencyScale(plot) }
        if showDiagnostics { drawDiagnostics(plot) }
        if isPaused { drawPausedBadge() }

        guard width > 0, height > 0, !pixels.isEmpty else { return }

        // The image is built from a COPY of the bitmap, not a pointer into it.
        //
        // The previous version handed CGImage a data provider aimed straight at
        // `pixels` with a no-op release callback. Core Graphics does not
        // promise to read that memory before `draw` returns -- it may keep the
        // image in a display list and rasterise later -- by which time `append`
        // has scrolled the buffer or `syncSize` has reallocated it entirely.
        // Anything drawn afterwards, marks included, is then at the mercy of
        // when the image actually gets composited.
        if let data = CFDataCreate(nil, pixels, pixels.count),
           let provider = CGDataProvider(data: data),
           let image = CGImage(
            width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 8 * bytesPerPixel,
            bytesPerRow: width * bytesPerPixel,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent) {

            ctx.interpolationQuality = .none   // one tap = one row, exactly
            ctx.draw(image, in: plot)           // row 0 (highest CF) at the top
        }

        // Where the time scale changes. Not a mark -- marks travel with the
        // picture and this is a property of the window -- and drawn in the
        // ink colour rather than in a seam's blue for that reason: it is a
        // fixed edge of the instrument, not an event in the recording. Which
        // is why it follows Invert while the seams do not: the marks are
        // coloured to be found, this is meant to look like part of the frame.
        let nearDrawn = min(closeUpColumns, max(0, width / 2))
        if nearDrawn > 0 {
            let sx = plot.width / CGFloat(width)
            let x = plot.minX + CGFloat(width - nearDrawn) * sx
            ctx.setFillColor((exposure.inverted ? NSColor.white
                                                : NSColor.black).cgColor)
            ctx.fill(CGRect(x: x - 0.5, y: plot.minY,
                            width: max(1, 1.0 / (window?.backingScaleFactor ?? 1)),
                            height: plot.height))
        }

        drawMarks(ctx, plot)
        drawReadout(ctx, plot)
    }

    private func drawMarks(_ ctx: CGContext, _ plot: CGRect) {
        guard !marks.isEmpty, width > 0 else { return }
        let scale = window?.backingScaleFactor ?? 1.0
        let sx = plot.width / CGFloat(width)
        if !loggedFirstSeamDraw {
            loggedFirstSeamDraw = true
            Log.say("DRAW \(marks.count) mark(s) sx=\(sx) "
                    + "plot=\(plot.width)x\(plot.height) "
                    + "scale=\(window?.backingScaleFactor ?? 0)")
        }

        // "One pixel" means one column of the cochleagram, which is the unit
        // the display is actually built in. An earlier version drew one
        // *device* pixel at an unsnapped position: it straddled two pixels,
        // each got half coverage, and antialiasing turned a red hairline into
        // pale pink that was invisible on white.
        let lw = max(sx, 1.0 / scale)

        ctx.saveGState()
        ctx.setShouldAntialias(false)
        // Drawn in order of precedence, not in the order they were recorded.
        //
        // At a replay boundary two marks land on the same column -- the old
        // recording ended and a new one began, both true -- and whichever is
        // painted second is the one you see. That was insertion order, which
        // differed between this and the browser version for no reason anybody
        // chose, so the same moment came out green here and red there. `rank`
        // is the same table in both.
        for m in marks.sorted(by: { $0.kind.rank < $1.kind.rank }) {
            ctx.setFillColor(m.color.cgColor)
            var x = plot.minX + CGFloat(m.column) * sx
            x = (x * scale).rounded() / scale          // land on a real pixel
            // A mark is made on the newest column, so it sits hard against the
            // right edge and would otherwise be half outside the view -- the
            // one moment it most needs to be visible, since that is while you
            // are looking at whatever you just did. Keep it fully inside.
            x = min(max(x, plot.minX), plot.maxX - lw)
            ctx.fill(CGRect(x: x, y: plot.minY, width: lw, height: plot.height))
        }
        ctx.restoreGState()
    }

    // MARK: - reading time and frequency off the picture
    //
    // The two axes are the whole point of the display and neither can be read
    // accurately by eye: the frequency scale has nine labels on six hundred
    // taps, and the time axis has none at all. So the pointer answers for
    // both -- a crosshair with the frequency under it wherever it goes, and,
    // on a frozen picture, a pair of lines whose separation is stated in
    // milliseconds.
    //
    // Measuring is confined to the paused display on purpose. A line is
    // anchored to a *column*, and on a moving picture the column it named has
    // scrolled somewhere else by the time the second line is placed.

    /// Milliseconds per column of the *main* picture -- the Speed setting.
    /// Set from the delegate, which owns it; the close-up's own columns are
    /// this divided by `aggregate`.
    var mainColumnMS: Double = 4.0

    private struct Measurement {
        /// Fractional column of the line dropped by the mouse-down.
        var anchor: Double
        /// Fractional column of the line the drag is carrying, or nil for a
        /// click that never became a drag -- one line, no duration.
        var cursor: Double?
        /// Where to put the label: the mouse's height, so it lands next to
        /// what is being measured rather than at some fixed edge.
        var y: CGFloat
    }
    private var measurement: Measurement?
    private var measuring = false
    /// The pointer, in view coordinates, while it is over the view.
    private var hover: CGPoint?

    /// Hold the frequency line back while a duration is being taken, and for
    /// as long as the pointer stays put afterwards.
    ///
    /// A drag puts the two of them at the same height, so the arrows would be
    /// drawn along the frequency line and neither would read cleanly. Waiting
    /// for the pointer to *move* rather than for the button to come up is the
    /// point: on release it is still sitting on the arrows, and a line
    /// appearing through the measurement the instant you let go is the same
    /// collision a moment later.
    private var frequencyHeldBack = false

    private var tracker: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracker { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited,
                      .mouseMoved, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        tracker = t
    }

    /// The pointer says what it will do. Crosshair over the picture, because
    /// it is about to read a position off it; the resize cursor within a few
    /// pixels of the close-up boundary, which is a control.
    ///
    /// Done here rather than with cursor rects, which is how the boundary used
    /// to do it: two overlapping cursor rects have no defined precedence, and
    /// the boundary's sits inside the plot's.
    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil), event)
    }

    /// `.cursorUpdate` on a tracking area is entry-driven -- it behaves like a
    /// cursor rect and says nothing about movement *within* the area. Since
    /// there is one area over the whole view and the distinctions are made
    /// inside it, the decision has to be made on every move as well, or which
    /// cursor you got would depend on where you crossed the edge: come in over
    /// the toolbar, through the seven points of top inset, and the pointer
    /// would stay an arrow for the whole visit.
    private func applyCursor(at p: CGPoint, _ event: NSEvent? = nil) {
        let plot = plotRect
        if let bx = boundaryX, abs(p.x - bx) <= 4, plot.contains(p) {
            NSCursor.resizeLeftRight.set()
        } else if plot.contains(p) {
            NSCursor.crosshair.set()
        } else if let event {
            // Not ours: let the chain and the window decide. The view is
            // pinned to the window's bottom edge, where the window's own
            // resize cursor belongs.
            super.cursorUpdate(with: event)
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let was = hover
        hover = p
        frequencyHeldBack = false
        // Only redraw when something visible depends on it. The picture is
        // rebuilt from a copy of the whole bitmap on every draw, so a redraw
        // per mouse-move over the chrome would be several megabytes for
        // nothing.
        let plot = plotRect
        applyCursor(at: p, event)
        if plot.contains(p) || (was.map { plot.contains($0) } ?? false) {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hover != nil else { return }
        hover = nil
        needsDisplay = true
    }

    /// Something has changed what a playback would be playing -- a click that
    /// begins a new measurement, or a grab of the close-up boundary, which
    /// clears the measurement as soon as it moves.
    ///
    /// RePlay listens, because the measurement is the thing it plays: leaving
    /// the sound running while the span underneath it changed would put the
    /// line across something nobody chose. Either gesture is therefore a Stop,
    /// and whatever the gesture goes on to do, it does.
    var onSelectionDisturbed: (() -> Void)?

    private func beginMeasurement(at p: CGPoint) {
        measurement = Measurement(anchor: column(atX: p.x, plotRect),
                                  cursor: nil, y: p.y)
        measuring = true
        hover = p
        frequencyHeldBack = true
        needsDisplay = true
        onSelectionDisturbed?()
    }

    private func extendMeasurement(to p: CGPoint) {
        guard measurement != nil else { return }
        measurement?.cursor = column(atX: p.x, plotRect)
        measurement?.y = p.y
        hover = p
        needsDisplay = true
    }

    /// Take the lines away. Escape, or playback resuming.
    func clearMeasurement() {
        guard measurement != nil || measuring else { return }
        measurement = nil
        measuring = false
        needsDisplay = true
    }

    /// True when there is something for Escape to dismiss, so the delegate can
    /// leave the key alone when there is not.
    var hasMeasurement: Bool { measurement != nil }

    // MARK: - RePlay: from the picture back to the audio
    //
    // The picture is several seconds of sound. These turn a position on it
    // back into a position in the recording, so that what is on screen can be
    // heard. Everything here is in *engine columns*: the one coordinate that
    // is still meaningful when the close-up puts two time scales on the screen
    // at once, and when a change of Speed leaves the older half of the picture
    // at a scale the newer half is not. See REPLAY-DESIGN.md.

    /// Bumped whenever the engine-column numbering starts again -- which is
    /// whenever the picture is wiped. Anything still holding a column index
    /// from before the bump is holding a number that now names other audio.
    private(set) var contentEpoch = 0

    /// The index the next engine column to arrive will have. What a recorder
    /// pairs with its own position to line the two up.
    var nextEngineColumn: Int64 { Int64(fineIndex) }

    /// Playback position as an engine column, or nil when nothing is playing.
    var playhead: Int64? {
        didSet { if playhead != oldValue { needsDisplay = true } }
    }

    /// The engine column drawn at a fractional screen column, or nil where
    /// nothing has been drawn yet.
    private func engineColumn(at u: Double) -> Int64? {
        guard width > 0, columnFine.count == width else { return nil }
        let x = min(max(Int(u.rounded(.down)), 0), width - 1)
        let g = columnFine[x]
        return g >= 0 ? g : nil
    }

    /// The oldest and newest engine columns anywhere on screen.
    ///
    /// Not simply the two ends of the array: after a wipe, or on a window that
    /// has just been widened, the left of the picture is columns that were
    /// never drawn, and playing from there would begin with silence that is not
    /// in the recording.
    var drawnColumns: (lo: Int64, hi: Int64)? {
        guard width > 0, columnFine.count == width else { return nil }
        guard let lo = columnFine.first(where: { $0 >= 0 }),
              let hi = columnFine.last(where: { $0 >= 0 }), hi >= lo
        else { return nil }
        return (lo, hi)
    }

    /// How much of the stream one screen column stands for.
    ///
    /// One engine column in the close-up strip, `aggregate` of them in the main
    /// picture. The distinction matters at the right-hand end of a selection: a
    /// main-picture column *names* the first of the engine columns it draws, so
    /// a selection that stopped at that name would be short by the rest of them
    /// -- at aggregate 8, a single column would play an eighth of what it
    /// shows.
    private func engineSpan(atScreenColumn x: Int) -> Int64 {
        let near = min(closeUpColumns, max(0, width / 2))
        if near > 0 && x >= width - near { return 1 }
        return Int64(max(1, aggregate))
    }

    /// The screen column a fractional position falls in, clamped to the picture.
    private func screenIndex(at u: Double) -> Int {
        min(max(Int(u.rounded(.down)), 0), max(0, width - 1))
    }

    /// What Play Selection would play: the first engine column, and one past
    /// the last.
    ///
    /// The measurement's three states are the three playback modes, which is
    /// why RePlay has no selection of its own: no lines plays the width of the
    /// picture, one line plays from there to the right-hand edge, two lines
    /// play what is between them. A selection that could disagree with what is
    /// drawn would be a second thing to keep in step.
    ///
    /// The upper bound is exclusive and already extended past the last column
    /// by that column's own span, so a one-column selection is a column's worth
    /// of sound rather than none.
    var selectionColumns: (lo: Int64, end: Int64)? {
        guard let drawn = drawnColumns, width > 0 else { return nil }
        let lastX = width - 1
        let wholePicture = (drawn.lo, drawn.hi + engineSpan(atScreenColumn: lastX))
        guard let m = measurement else { return wholePicture }

        let ax = screenIndex(at: m.anchor)
        // Where a line stands over picture that was never drawn, the sound it
        // would name does not exist. Undrawn columns are only ever at the left
        // -- a wipe, or a window just widened -- so both ends fall back to the
        // oldest column there is, never to the newest: falling back to the
        // right-hand edge would turn a leftward drag into a rightward
        // selection.
        let a = engineColumn(at: m.anchor) ?? drawn.lo
        guard let c = m.cursor else {
            return (a, drawn.hi + engineSpan(atScreenColumn: lastX))
        }
        let bx = screenIndex(at: c)
        let b = engineColumn(at: c) ?? drawn.lo
        let hiX = a <= b ? bx : ax
        return (min(a, b), max(a, b) + engineSpan(atScreenColumn: hiX))
    }

    /// Where an engine column sits on screen, as a fractional screen column.
    ///
    /// Interpolated inside whichever column it lands in, because in the main
    /// picture one column stands for `aggregate` engine columns and a line that
    /// only ever sat on column boundaries would advance in visible jerks at the
    /// coarser Speed settings. `columnFine` is non-decreasing left to right in
    /// both regions, so this is a binary search.
    private func screenColumn(forEngine g: Int64) -> Double? {
        guard width > 0, columnFine.count == width else { return nil }
        guard let first = columnFine.firstIndex(where: { $0 >= 0 }),
              g >= columnFine[first] else { return nil }
        var lo = first, hi = width - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if columnFine[mid] <= g { lo = mid } else { hi = mid - 1 }
        }
        let g0 = columnFine[lo]
        // A wipe with the close-up open refills the main region and the strip
        // from opposite ends, so for a fraction of a second there is a run of
        // never-drawn columns *between* two runs of real ones, and the search
        // above can land in it. Nothing sensible can be drawn against a column
        // that has no engine column behind it.
        guard g0 >= 0 else { return nil }
        // How much of the stream this column stands for. Taken from the next
        // column along where there is one -- which is right across the close-up
        // boundary too, where the two regions' widths differ -- and from the
        // region's own rate at the right-hand edge, where there is no next.
        let near = min(closeUpColumns, max(0, width / 2))
        var span = Int64(lo >= width - near && near > 0 ? 1 : max(1, aggregate))
        if lo + 1 < width, columnFine[lo + 1] > g0 { span = columnFine[lo + 1] - g0 }
        let frac = Double(g - g0) / Double(max(Int64(1), span))
        return Double(lo) + min(max(frac, 0), 1)
    }

    // MARK: converting a position into a quantity

    /// Fractional column under an x, clamped to the picture.
    private func column(atX x: CGFloat, _ plot: CGRect) -> Double {
        guard width > 0, plot.width > 0 else { return 0 }
        let u = Double((x - plot.minX) / plot.width) * Double(width)
        return min(max(u, 0), Double(width))
    }

    private func xFor(column u: Double, _ plot: CGRect) -> CGFloat {
        guard width > 0 else { return plot.minX }
        return plot.minX + CGFloat(u / Double(width)) * plot.width
    }

    /// Milliseconds from the left edge of the picture to a fractional column.
    ///
    /// Piecewise, because with the close-up open the picture has two time
    /// scales: the main region runs at the Speed setting and the strip on the
    /// right at that divided by `aggregate`. Expressing both as a distance
    /// from one origin means a difference is a subtraction even when the two
    /// lines are on opposite sides of the boundary -- which is exactly the
    /// measurement the close-up makes people want to take.
    private func timeMS(atColumn u: Double) -> Double {
        let near = Double(min(closeUpColumns, max(0, width / 2)))
        let far = Double(width) - near
        let fine = mainColumnMS / Double(max(1, aggregate))
        return u <= far ? u * mainColumnMS
                        : far * mainColumnMS + (u - far) * fine
    }

    /// The best frequency of the tap under a y, interpolated geometrically
    /// between the two it falls between.
    ///
    /// Interpolated rather than rounded to a tap: at sixty taps to the octave
    /// one row is 1.2%, which at 8 kHz is nearly a hundred hertz -- more than
    /// the "nearest Hz" the readout claims. Between taps is also where the
    /// pointer usually is, the rows being about a pixel tall.
    private func frequency(atY y: CGFloat, _ plot: CGRect) -> Double? {
        guard let cf = cochlea?.frequencies, height > 0 else { return nil }
        let n = min(cf.count, height)
        guard n >= 2, plot.height > 0 else { return nil }
        let r = Double((plot.maxY - y) / plot.height) * Double(height) - 0.5
        let rr = min(max(r, 0), Double(n - 1))
        let i = min(n - 2, max(0, Int(rr)))
        return cf[i] * pow(cf[i + 1] / cf[i], rr - Double(i))
    }

    private func timeLabel(_ ms: Double) -> String {
        if ms < 10   { return String(format: "%.2f mS", ms) }
        if ms < 100  { return String(format: "%.1f mS", ms) }
        if ms < 1000 { return String(format: "%.0f mS", ms) }
        return String(format: "%.2f S", ms / 1000)
    }

    // MARK: drawing it

    private func drawReadout(_ ctx: CGContext, _ plot: CGRect) {
        let ink = NSColor.systemOrange
        // Underneath the measurement, so the duration's arrows read as drawn
        // on top of the reticle rather than tangled with it.
        //
        // A line across the picture rather than a number at the pointer: the
        // question the frequency readout answers is "what is this row", and a
        // row is a horizontal thing. The number beside the pointer named the
        // right tap but you still had to sight along to find it, which on a
        // 600-row picture is the whole difficulty.
        if let p = hover, plot.contains(p), !draggingBoundary,
           !frequencyHeldBack, window?.isKeyWindow == true,
           let f = frequency(atY: p.y, plot) {
            drawFrequencyCursor(ctx, plot, at: p.y, f, ink)
        }
        if let m = measurement {
            drawMeasureLine(ctx, plot, at: m.anchor, ink)
            if let c = m.cursor {
                drawMeasureLine(ctx, plot, at: c, ink)
                drawDimension(ctx, plot, m.anchor, c, m.y, ink)
            }
        }
        // On top of the measurement, and a different colour from it: the orange
        // lines say where the sound will be taken from, and this one says where
        // in it the ear has got to. Two statements about the same axis, so they
        // must not be mistakable for each other.
        if let g = playhead, let u = screenColumn(forEngine: g) {
            drawMeasureLine(ctx, plot, at: u, Self.playheadInk)
        }
    }

    /// Violet. Far enough from the orange of the measurement to be told apart
    /// at a glance, and from the red seam and the green end-of-file mark. Named
    /// here rather than written at the point of use so the browser has one
    /// number to match.
    static let playheadInk = NSColor(srgbRed: 0.55, green: 0.24, blue: 0.95,
                                     alpha: 1.0)

    /// The horizontal line, with its frequency at the left end.
    ///
    /// The label sits inside the picture rather than in the gutter: the gutter
    /// is the fixed scale and belongs to the instrument, and a number that
    /// came and went there would be read as one of its marks. The line starts
    /// clear of the label so the two do not overlap.
    private func drawFrequencyCursor(_ ctx: CGContext, _ plot: CGRect,
                                     at y: CGFloat, _ f: Double,
                                     _ color: NSColor) {
        let text = "\(Int(f.rounded())) Hz"
        let size = (text as NSString).size(withAttributes: chipAttributes)
        let pad: CGFloat = 3
        let left = plot.minX + 2
        drawChip(text, size, CGPoint(x: left + pad, y: y), plot)
        let x0 = left + size.width + 2 * pad + 5
        guard x0 < plot.maxX else { return }
        drawHairline(ctx, y: y, from: x0, to: plot.maxX, color)
    }

    /// The duration, drawn the way a dimension is drawn on a drawing: the
    /// number in the gap, an arm from each end of it out to the line it
    /// measures, arrowheads against the lines.
    ///
    /// When the two lines are too close together for the number to fit
    /// between them the arms go outside and point inwards and the number
    /// stands clear -- which is the same convention, and is the case the
    /// close-up creates constantly, since measuring a single glottal pulse
    /// puts the two lines a few pixels apart.
    private func drawDimension(_ ctx: CGContext, _ plot: CGRect,
                               _ a: Double, _ b: Double, _ y: CGFloat,
                               _ color: NSColor) {
        let dt = abs(timeMS(atColumn: b) - timeMS(atColumn: a))
        let text = timeLabel(dt)
        let size = (text as NSString).size(withAttributes: chipAttributes)
        let pad: CGFloat = 3
        let chipW = size.width + 2 * pad
        let xa = xFor(column: a, plot), xb = xFor(column: b, plot)
        let xL = min(xa, xb), xR = max(xa, xb)
        // Shortest arm worth drawing: below this the arrowhead is the arm.
        let stub: CGFloat = 10

        if xR - xL >= chipW + 2 * stub {
            let mid = (xL + xR) / 2
            drawArm(ctx, y: y, from: mid - chipW / 2 - 1, to: xL, color)
            drawArm(ctx, y: y, from: mid + chipW / 2 + 1, to: xR, color)
            drawChip(text, size, CGPoint(x: mid - size.width / 2, y: y), plot)
        } else {
            let arm: CGFloat = 16
            drawArm(ctx, y: y, from: xL - arm, to: xL, color)
            drawArm(ctx, y: y, from: xR + arm, to: xR, color)
            var tx = xR + arm + 5
            if tx + size.width + pad > plot.maxX {
                tx = xL - arm - 5 - size.width
            }
            drawChip(text, size, CGPoint(x: tx, y: y), plot)
        }
    }

    /// One device pixel, snapped to the pixel grid so it cannot straddle two
    /// and be antialiased into invisibility -- the same care the marks take.
    private func drawHairline(_ ctx: CGContext, y: CGFloat,
                              from x0: CGFloat, to x1: CGFloat,
                              _ color: NSColor) {
        let scale = window?.backingScaleFactor ?? 1.0
        let lw = 1.0 / scale
        let yy = (y * scale).rounded() / scale
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: min(x0, x1), y: yy,
                        width: abs(x1 - x0), height: lw))
        ctx.restoreGState()
    }

    /// An arm of the dimension line: a hairline from `x0` to `x1` with a
    /// filled arrowhead at the `x1` end.
    private func drawArm(_ ctx: CGContext, y: CGFloat,
                         from x0: CGFloat, to x1: CGFloat,
                         _ color: NSColor) {
        drawHairline(ctx, y: y, from: x0, to: x1, color)
        let scale = window?.backingScaleFactor ?? 1.0
        let yy = (y * scale).rounded() / scale + 0.5 / scale
        let dir: CGFloat = x1 >= x0 ? 1 : -1
        let len: CGFloat = 7, half: CGFloat = 3
        ctx.saveGState()
        // Antialiased, unlike the lines: the head's edges are diagonal, and
        // snapping a triangle to the pixel grid only makes it ragged.
        ctx.setShouldAntialias(true)
        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x1, y: yy))
        ctx.addLine(to: CGPoint(x: x1 - dir * len, y: yy - half))
        ctx.addLine(to: CGPoint(x: x1 - dir * len, y: yy + half))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// One of the two vertical lines, the full height of the picture.
    private func drawMeasureLine(_ ctx: CGContext, _ plot: CGRect,
                                 at u: Double, _ color: NSColor) {
        let scale = window?.backingScaleFactor ?? 1.0
        let lw = 1.0 / scale
        var x = xFor(column: u, plot)
        x = (x * scale).rounded() / scale
        x = min(max(x, plot.minX), plot.maxX - lw)
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: x, y: plot.minY, width: lw, height: plot.height))
        ctx.restoreGState()
    }

    /// Black on the paper patch, white when the paper is black.
    ///
    /// Not the orange of the lines. The lines have to be found against the
    /// picture, which is what the colour is for; the text sits on a patch of
    /// paper that has been cleared for it, and against paper the highest
    /// contrast available is the ink the picture itself is drawn in. Orange
    /// on white is 3.1:1 at 11 point, which is below what small text wants.
    private var chipAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
         .foregroundColor: exposure.inverted ? NSColor.white : NSColor.black]
    }

    /// The label itself, on a patch of paper so it is legible over ink.
    private func drawChip(_ text: String, _ size: CGSize, _ origin: CGPoint,
                          _ plot: CGRect) {
        let pad: CGFloat = 3
        var r = CGRect(x: origin.x - pad, y: origin.y - size.height / 2 - 1,
                       width: size.width + 2 * pad, height: size.height + 2)
        r.origin.x = min(max(r.minX, plot.minX), plot.maxX - r.width)
        r.origin.y = min(max(r.minY, plot.minY), plot.maxY - r.height)
        let paper = (exposure.inverted ? NSColor.black : NSColor.white)
            .withAlphaComponent(0.82)
        paper.setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(
            at: CGPoint(x: r.minX + pad, y: r.minY + 1),
            withAttributes: chipAttributes)
    }

    // MARK: - the status strip

    private func drawDiagnostics(_ plot: CGRect) {
        // The close-up's three numbers are here because the two ways it can
        // fail look alike on screen and completely different in the numbers:
        // if `eng` has not moved off the Speed setting then the engine never
        // changed rate and the strip is not a close-up at all, whereas if
        // `take` is at the strip's width every frame then columns are arriving
        // faster than they can be shown and each frame replaces the whole
        // strip rather than scrolling it.
        let near = closeUpColumns > 0
            ? "  near \(closeUpColumns) K \(aggregate) promoted \(lastPromoted)"
              + String(format: "  eng %.2fms", cochlea?.columnMilliseconds ?? 0)
            : ""
        let text = "bmp \(width)x\(height)  plot \(Int(plot.width))"
                 + "  resizes \(resizeCount) (\(lastResize))"
                 + "  take \(lastTake)/max \(maxTake)"
                 + near
                 + "  MARKS \(marks.count)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        // Starts at the picture's left edge, not the window's: the gutter is
        // the frequency scale's column and has to stay clear all the way down
        // so the bottom label can hang below the picture. No background box
        // needed now it sits on chrome rather than on data.
        (text as NSString).draw(at: CGPoint(x: plot.minX, y: 4),
                                withAttributes: attrs)
    }

    private func drawPausedBadge() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
        ]
        let s = "PAUSED" as NSString
        let w = s.size(withAttributes: attrs).width
        s.draw(at: CGPoint(x: bounds.maxX - w - 6, y: 4), withAttributes: attrs)
    }

    // MARK: - the frequency scale

    /// Drawn in the gutter, never over the picture: a label on top of the data
    /// hides the taps it exists to identify. Numbers are right-justified
    /// against the plot edge so the digits line up whatever their width.
    ///
    /// No ticks. The column is clear from top to bottom and nothing else is
    /// drawn in it, so a number's vertical position is unambiguous on its own
    /// -- and dropping them lets the column be narrow enough to cost the
    /// picture almost nothing.
    private func drawFrequencyScale(_ plot: CGRect) {
        guard let c = cochlea, c.tapCount > 0, c.frequencies.count >= 2 else {
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        // Octaves, not decades. A cochlea is a log-frequency instrument and its structure is
        // octave-spaced -- harmonics, formants, the spacing of the taps
        // themselves -- so a scale that halves each time reads against the
        // picture instead of across it. Some of these fall outside the taps:
        // a cascade designed for 20 Hz to 20 kHz actually peaks at 20.9 and
        // 20089, because the accumulated skirt pulls each channel's response
        // below its own pole. Such labels are drawn past the end of the
        // picture, which is why the gutter runs the full height of the view.
        let octaves: [Double] = [16000, 8000, 4000, 2000, 1000,
                                 500, 250, 125, 64, 32]
        var drawn: [CGFloat] = []
        for f in octaves {
            let y = rowY(row(for: f, c.frequencies), plot)
            guard drawn.allSatisfy({ abs($0 - y) >= 11 }) else { continue }
            if place(f, y, plot, attrs) { drawn.append(y) }
        }
    }

    /// Where a frequency sits on the tap axis, interpolated between the two
    /// taps that bracket it -- and extrapolated, at the spacing of the
    /// outermost pair, for one that lies beyond either end.
    ///
    /// The measured best frequencies are not exactly geometric: the cascade
    /// pulls each peak below its pole by a little more at one end than the
    /// other, so assuming a constant number of taps per octave is wrong by
    /// several rows at the extremes -- which is precisely where the two
    /// labels that matter most are.
    private func row(for f: Double, _ cf: [Double]) -> Double {
        let n = cf.count
        if f >= cf[0] {
            let span = log(cf[0] / cf[1])
            return span > 0 ? -log(f / cf[0]) / span : 0
        }
        if f <= cf[n - 1] {
            let span = log(cf[n - 2] / cf[n - 1])
            return span > 0 ? Double(n - 1) + log(cf[n - 1] / f) / span
                            : Double(n - 1)
        }
        var i = 0
        while i + 1 < n && cf[i + 1] > f { i += 1 }
        let span = log(cf[i] / cf[i + 1])
        return Double(i) + (span > 0 ? log(cf[i] / f) / span : 0)
    }

    /// View is y-up and image row 0 is at the top, so invert. The half is the
    /// row's centre rather than its top edge: a tap occupies a band.
    private func rowY(_ row: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - (CGFloat(row) + 0.5) * plot.height / CGFloat(height)
    }

    /// Draws one number at its true height, or not at all.
    ///
    /// Nothing is clamped into view. A label nudged to fit is a label in the
    /// wrong place, and on a frequency scale that is worse than a gap: it
    /// would put 20 Hz level with the lowest tap and quietly claim the display
    /// reaches further down than it does.
    private func place(_ f: Double, _ y: CGFloat, _ plot: CGRect,
                       _ attrs: [NSAttributedString.Key: Any]) -> Bool {
        let label = frequencyLabel(f) as NSString
        let size = label.size(withAttributes: attrs)
        let ly = y - size.height / 2
        guard ly >= 0, ly + size.height <= bounds.maxY else { return false }
        label.draw(at: CGPoint(x: plot.minX - 6 - size.width, y: ly),
                   withAttributes: attrs)
        return true
    }

    private func frequencyLabel(_ f: Double) -> String {
        guard f >= 1000 else { return "\(Int(f.rounded()))" }
        let k = f / 1000
        return k >= 10 || k == k.rounded()
            ? "\(Int(k.rounded()))k"
            : String(format: "%.1fk", k)
    }
}
