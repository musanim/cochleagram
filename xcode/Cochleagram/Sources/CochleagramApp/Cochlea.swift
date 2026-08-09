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

    /// Column scratch buffers, reused so drawing never allocates.
    private var levelBuffer: [Float]
    private var coherenceBuffer: [Float]
    private var refBuffer: [Float]
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

        if tapCount > 0, let f = cochlea_frequencies(e) {
            frequencies = Array(UnsafeBufferPointer(start: f, count: tapCount))
        } else {
            frequencies = []
        }
        levelBuffer = [Float](repeating: 0, count: max(1, tapCount * maxPull))
        coherenceBuffer = [Float](repeating: 0, count: max(1, tapCount * maxPull))
        refBuffer = [Float](repeating: 0, count: maxPull)
    }

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
    func drainColumns(_ body: (UnsafeBufferPointer<Float>,
                               UnsafeBufferPointer<Float>,
                               UnsafeBufferPointer<Float>, Int) -> Void) {
        guard tapCount > 0 else { return }
        while true {
            let n = levelBuffer.withUnsafeMutableBufferPointer { lv -> Int in
                coherenceBuffer.withUnsafeMutableBufferPointer { co -> Int in
                    refBuffer.withUnsafeMutableBufferPointer { rf -> Int in
                        guard let l = lv.baseAddress, let c = co.baseAddress,
                              let r = rf.baseAddress else { return 0 }
                        return Int(cochlea_pull_columns(engine, l, c, r,
                                                        Int32(maxPull)))
                    }
                }
            }
            if n == 0 { break }
            levelBuffer.withUnsafeBufferPointer { lv in
                coherenceBuffer.withUnsafeBufferPointer { co in
                    refBuffer.withUnsafeBufferPointer { rf in
                        body(lv, co, rf, n)
                    }
                }
            }
            if n < maxPull { break }
        }
    }

    var droppedColumns: UInt64 { cochlea_dropped_columns(engine) }

    /// Peak input level since the previous call, linear.
    var peakLevel: Float { cochlea_peak_level(engine) }
}
