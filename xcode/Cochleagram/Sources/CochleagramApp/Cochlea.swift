import Foundation
// Under SwiftPM the C core is a separate module. In the Xcode target it is
// compiled into the app and reached through a bridging header, so there is
// nothing to import.
#if SWIFT_PACKAGE
import CochleaDSP
#endif

/// Swift face of the C core.  Owns the engine and hands out display columns.
///
/// `CochleaEngine` is an opaque struct in the header -- declared but never
/// defined -- so Swift imports every `CochleaEngine *` as `OpaquePointer`.
/// That means the handle is passed straight through; no `UnsafeMutablePointer`
/// conversion is needed anywhere, and attempting one will not compile.
/// What a column of numbers means.
///
/// A first attempt at the display the original called mode colouring, which
/// Stephen remembers as being built on the phase relationship between peaks in
/// neighbouring taps. This is the raw material for that and not yet the thing
/// itself: it shows the relationship, it does not classify it.
enum DisplayMode: Int32, CaseIterable {
    /// Held peak level, dB relative to full scale. The original display.
    case amplitude = 0
    /// When a tap peaks, how long ago the tap above it last peaked, in cycles
    /// of the reporting tap's own best frequency. Not dB, not measured against
    /// any reference.
    case coherence = 1

    var title: String {
        switch self {
        case .amplitude: return "Amplitude"
        case .coherence: return "Coherence"
        }
    }
}

final class Cochlea {

    private let engine: OpaquePointer
    let tapCount: Int
    let frequencies: [Double]      // best frequency per tap, high to low
    let internalRate: Double
    /// What this engine was built from, so a caller can tell whether the one
    /// it is holding is already the one it wants. Building costs about half a
    /// second -- two calibration sweeps over the whole cascade -- and it is
    /// spent on the main thread, so "do I need a new one" is worth asking.
    let coefficientURL: URL
    let inputRate: Double

    /// Column scratch buffers, reused so drawing never allocates.
    /// One allocation behind everything `drainColumns` pulls, laid out as
    /// levels | coherence | refs | input low | input high. See `drainColumns`
    /// for why it is one buffer and not five.
    private var scratch: [Float]
    /// Columns per drain call. At the close-up's finest setting the engine
    /// makes 20,000 a second, which is 333 in a 60 Hz frame and more after a
    /// dropped one, so 512 was about to become the limit rather than a
    /// generous ceiling. The buffers are floats per tap: 2048 columns of 599
    /// taps is 4.9 MB for the two of them.
    private let maxPull = 2048

    init?(coefficientURL: URL, inputRate: Double) {
        // Swift bridges String to `const char *` for the duration of the call.
        guard let e = cochlea_create(coefficientURL.path, inputRate) else {
            return nil
        }
        engine = e
        tapCount = Int(cochlea_tap_count(e))
        internalRate = cochlea_internal_rate(e)
        self.coefficientURL = coefficientURL
        self.inputRate = inputRate

        if tapCount > 0, let f = cochlea_frequencies(e) {
            frequencies = Array(UnsafeBufferPointer(start: f, count: tapCount))
        } else {
            frequencies = []
        }
        // Two planes of tapCount-per-column, then three of one-per-column.
        scratch = [Float](repeating: 0,
                          count: max(1, tapCount * maxPull * 2 + maxPull * 3))
    }

    /// The apex's calibrated delay, in milliseconds: what De-skew costs in
    /// display latency, and the whole picture's hold-back.
    ///
    /// Logged at every engine build because it is also a fingerprint of *which
    /// calibration* produced this engine. Changing how the delays are measured
    /// moves it -- ERB 0.5 went from 247.3 ms to 215.1 when calibration
    /// started running through the resampler -- and an afternoon was spent
    /// comparing a screenshot against a source tree that no longer described
    /// the binary taking the screenshot. One number in the log settles that.
    var maxDelayMS: Double {
        guard tapCount > 0, let d = cochlea_delays(engine) else { return 0 }
        return (UnsafeBufferPointer(start: d, count: tapCount).max() ?? 0) * 1000
    }

    /// The base's calibrated delay, in milliseconds: the fastest anything in
    /// the cascade can respond, and so the earliest the picture can show an
    /// event at all.
    var minDelayMS: Double {
        guard tapCount > 0, let d = cochlea_delays(engine) else { return 0 }
        return (UnsafeBufferPointer(start: d, count: tapCount).min() ?? 0) * 1000
    }

    /// How far behind the sound the picture is, in milliseconds.
    ///
    /// This is the number that turns a column back into a moment of audio, and
    /// De-skew changes it by nearly two hundred milliseconds.
    ///
    /// With De-skew **on** every tap is held back to the slowest, so a column
    /// stands for one instant, uniformly `maxDelayMS` in the past. That is the
    /// whole point of the feature -- a click stands vertical -- and it is also
    /// the largest single offset anywhere in the app.
    ///
    /// With it **off** there is no one answer: the column holds each tap's own
    /// response to an event `gdelay[k]` ago, so it is a smear from the base's
    /// delay to the apex's, which is exactly the slant De-skew exists to
    /// remove. The base's is the number used, because the top of the slant is
    /// the leading edge -- the first ink an event produces, and what the eye
    /// reads a click's position from. Anything lower on the picture is later,
    /// as the picture itself shows.
    var displayLagMS: Double { deskew ? maxDelayMS : minDelayMS }

    deinit { cochlea_destroy(engine) }

    // MARK: - configuration

    var columnMilliseconds: Double = 4.0 {
        didSet { cochlea_set_column_ms(engine, columnMilliseconds) }
    }

    /// How fast the reported auto-gain reference decays back after a peak.
    /// The engine only *tracks* it -- the display decides whether to use it.
    func setAutoGainHalflife(_ halflife: Double) {
        cochlea_set_auto_gain_halflife(engine, halflife)
    }

    /// Reference the engine is currently tracking, dB.
    var currentRefDB: Double { cochlea_current_ref_db(engine) }

    /// Compensate the travelling-wave delay. Costs ~186 ms of display latency,
    /// because the correction can only hold the fast taps back, never advance
    /// the slow ones.
    var deskew: Bool = true {
        didSet { cochlea_set_deskew(engine, deskew ? 1 : 0) }
    }

    // MARK: - audio thread

    /// Real-time safe. Call from the render callback.
    func process(_ samples: UnsafePointer<Float>, count: Int) {
        cochlea_process(engine, samples, Int32(count))
    }

    // MARK: - drawing thread

    /// Hands the caller however many finished columns are waiting.
    ///
    /// The closure receives column-major levels in dB relative to full scale
    /// -- `tapCount` per column, tap 0 (highest frequency) first -- the same
    /// shape again in coherence cycles, and one auto-gain reference per
    /// column, also in dB. Turning those into pixels is the display's job: it
    /// is the only part of the system that knows what the controls are set
    /// to, and the only part that can re-render what is already on screen
    /// when they move.
    ///
    /// Both quantities arrive on every column whichever one is being drawn,
    /// so switching mode costs a re-render rather than a wipe.
    /// `inLo` and `inHi` are the input's smallest and largest sample over each
    /// column, already delayed by the engine to match de-skew -- so a caller
    /// drawing them under the picture needs no correction of its own.
    ///
    /// One buffer behind five pointers, rather than five arrays behind five
    /// nested `withUnsafeMutableBufferPointer` closures. The nesting was three
    /// deep with three quantities and would be five with five, which is both
    /// unreadable and the shape that makes Swift's type checker give up.
    func drainColumns(_ body: (_ levels: UnsafeBufferPointer<Float>,
                               _ coherence: UnsafeBufferPointer<Float>,
                               _ refs: UnsafeBufferPointer<Float>,
                               _ inLo: UnsafeBufferPointer<Float>,
                               _ inHi: UnsafeBufferPointer<Float>,
                               _ count: Int) -> Void) {
        guard tapCount > 0 else { return }
        let plane = maxPull * tapCount
        let offLevels = 0
        let offCoherence = plane
        let offRefs = plane * 2
        let offLo = offRefs + maxPull
        let offHi = offLo + maxPull
        while true {
            let n = scratch.withUnsafeMutableBufferPointer { p -> Int in
                guard let b = p.baseAddress else { return 0 }
                return Int(cochlea_pull_columns(engine,
                                                b + offLevels,
                                                b + offCoherence,
                                                b + offRefs,
                                                b + offLo,
                                                b + offHi,
                                                Int32(maxPull)))
            }
            if n == 0 { break }
            scratch.withUnsafeBufferPointer { p in
                guard let b = p.baseAddress else { return }
                body(UnsafeBufferPointer(start: b + offLevels, count: n * tapCount),
                     UnsafeBufferPointer(start: b + offCoherence, count: n * tapCount),
                     UnsafeBufferPointer(start: b + offRefs, count: n),
                     UnsafeBufferPointer(start: b + offLo, count: n),
                     UnsafeBufferPointer(start: b + offHi, count: n),
                     n)
            }
            if n < maxPull { break }
        }
    }

    var droppedColumns: UInt64 { cochlea_dropped_columns(engine) }

    // MARK: - keeping the input

    /// Whether the engine is also keeping the samples the picture is drawn
    /// from, so that what is on screen can be played back.
    ///
    /// Turned off while the display is frozen on live input, which is how the
    /// recording comes to skip exactly the interval the picture skips. See
    /// `cochlea.h`.
    var capturing: Bool = false {
        didSet {
            guard capturing != oldValue else { return }
            cochlea_set_capture(engine, capturing ? 1 : 0)
        }
    }

    /// Room for one display link's worth of input at any rate anyone runs at.
    /// A 60 Hz frame is 800 samples at 48 kHz; this is a frame at ten times
    /// the rate, or ten frames at the real one, which covers a late tick
    /// without another lap of the loop.
    private var inputBuffer = [Float](repeating: 0, count: 8192)

    /// Hand the caller everything captured since the last call.
    ///
    /// The closure can be called more than once, as `drainColumns` can, when
    /// more is waiting than the scratch buffer holds.
    func drainInput(_ body: (UnsafeBufferPointer<Float>) -> Void) {
        while true {
            let n = inputBuffer.withUnsafeMutableBufferPointer { p -> Int in
                guard let b = p.baseAddress else { return 0 }
                return Int(cochlea_pull_input(engine, b, Int32(p.count)))
            }
            if n == 0 { break }
            inputBuffer.withUnsafeBufferPointer { p in
                body(UnsafeBufferPointer(rebasing: p[0..<n]))
            }
            if n < inputBuffer.count { break }
        }
    }

    var droppedInput: UInt64 { cochlea_dropped_input(engine) }

    /// Peak input level since the previous call, linear.
    var peakLevel: Float { cochlea_peak_level(engine) }
}
