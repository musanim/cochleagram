import AppKit

/// A slider with two knobs, for setting both ends of a range at once.
///
/// AppKit has no such control, and the two-slider arrangement it replaces was
/// a worse fit for the job: Gain set where black was and Level set how far
/// below it white was, so moving the black point moved the white point with
/// it, and reading the actual span meant doing arithmetic in your head. Here
/// the two knobs *are* the two ends. Dragging one moves that end -- a contrast
/// change; dragging the band between them moves both and keeps the span -- a
/// gain change. Clicking anywhere else does nothing: the picture is not worth
/// rearranging on the strength of a mis-aimed click.
///
/// The knobs cannot cross, and cannot come closer than `minimumSeparation` --
/// which is also roughly where they would start to overlap visually, so the
/// limit is honest rather than arbitrary.
final class RangeSlider: NSControl {

    /// Which knobs the last click grabbed. Persists after the mouse is
    /// released, so the arrow keys have something to act on and so the
    /// picture shows what is about to move.
    enum Selection { case low, high, both }
    private(set) var selection: Selection = .both { didSet { needsDisplay = true } }

    var range: ClosedRange<Double> = -90 ... 10 { didSet { clamp() } }
    var minimumSeparation: Double = 3 { didSet { clamp() } }

    private var low: Double = -35
    private var high: Double = 0

    /// The lower end -- where the picture reaches white.
    var lowValue: Double {
        get { low }
        set { set(low: newValue, high: high, yielding: .high) }
    }
    /// The upper end -- where it reaches black.
    var highValue: Double {
        get { high }
        set { set(low: low, high: newValue, yielding: .low) }
    }

    private var dragging: Selection?
    /// Where the pointer was, and where the knobs were, when a band drag
    /// began. A band drag has to move by a delta rather than to an absolute
    /// position, or the span would jump to centre itself on the cursor.
    private var dragAnchor: Double = 0
    private var dragStartLow: Double = 0
    private var dragStartHigh: Double = 0

    private var knobDiameter: CGFloat { min(bounds.height - 2, 14) }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 18) }

    // MARK: - values

    /// The one place values change. `yielding` says which end gives way if
    /// they are pushed closer than the minimum -- always the one the user is
    /// not holding.
    private func set(low l: Double, high h: Double, yielding: Selection) {
        let lo = range.lowerBound, hi = range.upperBound
        var newLow = min(max(l, lo), hi)
        var newHigh = min(max(h, lo), hi)
        if newHigh - newLow < minimumSeparation {
            switch yielding {
            case .low:  newLow = max(lo, newHigh - minimumSeparation)
            case .high: newHigh = min(hi, newLow + minimumSeparation)
            case .both: break                 // a band drag keeps its span
            }
            // If the range itself is narrower than the minimum, give up
            // gracefully rather than oscillate.
            if newHigh - newLow < minimumSeparation {
                newLow = lo
                newHigh = min(hi, lo + minimumSeparation)
            }
        }
        guard newLow != low || newHigh != high else { return }
        low = newLow
        high = newHigh
        needsDisplay = true
    }

    private func clamp() { set(low: low, high: high, yielding: .high) }

    // MARK: - geometry

    private func x(for value: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return bounds.midX }
        let t = (value - range.lowerBound) / span
        return knobDiameter / 2 + CGFloat(t) * (bounds.width - knobDiameter)
    }

    private func value(atX px: CGFloat) -> Double {
        let usable = max(1, bounds.width - knobDiameter)
        let t = Double((px - knobDiameter / 2) / usable)
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    private func knobRect(_ centreX: CGFloat) -> NSRect {
        NSRect(x: centreX - knobDiameter / 2, y: bounds.midY - knobDiameter / 2,
               width: knobDiameter, height: knobDiameter)
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        let trackHeight: CGFloat = 4
        let track = NSRect(x: knobDiameter / 2,
                           y: bounds.midY - trackHeight / 2,
                           width: bounds.width - knobDiameter,
                           height: trackHeight)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2,
                     yRadius: trackHeight / 2).fill()

        // The band between the knobs: the part of the level axis the greyscale
        // actually covers, and the target for a drag that moves both.
        let xl = x(for: low), xh = x(for: high)
        let band = NSRect(x: xl, y: track.minY,
                          width: max(0, xh - xl), height: trackHeight)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: band, xRadius: trackHeight / 2,
                     yRadius: trackHeight / 2).fill()

        drawKnob(at: xl, selected: selection == .low || selection == .both)
        drawKnob(at: xh, selected: selection == .high || selection == .both)
    }

    private func drawKnob(at centreX: CGFloat, selected: Bool) {
        let path = NSBezierPath(ovalIn: knobRect(centreX))
        (isEnabled ? NSColor.controlColor : .disabledControlTextColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        // A dot for what a drag or an arrow key would move. Both knobs carry
        // one after a band click, which is the only way to tell that state
        // apart from having grabbed a single knob.
        guard selected else { return }
        let d = knobDiameter * 0.42
        let dot = NSRect(x: centreX - d / 2, y: bounds.midY - d / 2,
                         width: d, height: d)
        (isEnabled ? NSColor.controlAccentColor : .disabledControlTextColor)
            .setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        let xl = x(for: low), xh = x(for: high)
        let onLow = knobRect(xl).contains(p)
        let onHigh = knobRect(xh).contains(p)

        // A knob first, then the band between them -- and nothing else.
        // Knobs win where they overlap the band, or the ends of the band
        // would be unreachable once the two are squeezed to the minimum
        // separation, where the knobs cover it entirely.
        let grabbed: Selection?
        if onLow && onHigh {
            grabbed = abs(p.x - xl) <= abs(p.x - xh) ? .low : .high
        } else if onLow {
            grabbed = .low
        } else if onHigh {
            grabbed = .high
        } else if p.x > xl && p.x < xh {
            grabbed = .both
        } else {
            // Outside everything. Treated as a miss and ignored entirely --
            // not even a change of selection. A click on bare track used to
            // fling the nearest knob to the pointer, which is a large,
            // silent change to the picture in response to what is more often
            // a mis-aimed click than an instruction.
            grabbed = nil
        }
        guard let grabbed else { return }

        selection = grabbed
        dragging = grabbed
        dragAnchor = value(atX: p.x)
        dragStartLow = low
        dragStartHigh = high
        // Nothing moves yet. Every drag is by displacement from where it was
        // grabbed, so a knob does not jump to centre itself under the pointer
        // and a press with no movement changes nothing at all.
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, dragging != nil else { return }
        drag(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }

    private func drag(to px: CGFloat) {
        let delta = value(atX: px) - dragAnchor
        switch dragging {
        case .low:
            set(low: dragStartLow + delta, high: high, yielding: .high)
        case .high:
            set(low: low, high: dragStartHigh + delta, yielding: .low)
        case .both:
            // Stop the pair when *either* end reaches the range, rather than
            // letting one pile up against the wall while the other keeps
            // going and the span quietly shrinks.
            var d = delta
            d = max(d, range.lowerBound - dragStartLow)
            d = min(d, range.upperBound - dragStartHigh)
            set(low: dragStartLow + d, high: dragStartHigh + d,
                yielding: .both)
        case nil:
            return
        }
        // Continuously, so the picture re-exposes under the cursor. That is
        // the whole point of keeping the levels around.
        sendAction(action, to: target)
    }

    // MARK: - keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
        let delta: Double
        switch event.keyCode {
        case 123, 125: delta = -step             // left, down
        case 124, 126: delta = +step             // right, up
        default: super.keyDown(with: event); return
        }
        // Whatever the last click selected is what moves, so the dots are not
        // decoration -- they say what the arrow keys will do.
        switch selection {
        case .low:  set(low: low + delta, high: high, yielding: .high)
        case .high: set(low: low, high: high + delta, yielding: .low)
        case .both:
            var d = delta
            d = max(d, range.lowerBound - low)
            d = min(d, range.upperBound - high)
            set(low: low + d, high: high + d, yielding: .both)
        }
        sendAction(action, to: target)
    }
}
