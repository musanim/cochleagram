import Foundation

/// The toolbar controls, remembered between launches.
///
/// One value read and written whole, rather than `UserDefaults` calls
/// sprinkled through the delegate. The defaults then live in exactly one
/// place -- the property initialisers below -- and "reset" is a single
/// assignment instead of a list of keys somebody has to keep in step.
///
/// Slider positions are stored as the slider reads them, not as the engine
/// wants them. The two differ in sign (turning gain *up* lowers the reference
/// the display is measured against), and storing the sign flip would mean
/// remembering to undo it in three places.
struct Settings: Equatable {

    /// De-skew off, Auto gain off, and a deliberately wide exposure window.
    ///
    /// These are also what the toolbar's Defaults button restores, and the
    /// agreement is deliberate: a first launch and a press of Defaults are the
    /// same request from the same kind of person, so they should not land in
    /// different places. The button differs from a fresh `Settings()` only in
    /// *which* values it touches -- it leaves ERB and Speed alone, because
    /// those say what the picture is rather than how it is exposed, and
    /// somebody who has chosen a tuning and a time scale is not asking to be
    /// moved off them.
    ///
    /// Auto gain is **off**, and this is the one place where "show a stranger
    /// something" loses to something else. Auto gain would guarantee a picture
    /// on any hardware, but it owns Sensitivity while it is on, and switching
    /// it off hands back wherever the controller had drifted to -- which
    /// depends on everything the app has heard since it started. Two copies of
    /// this program given the same file would then disagree about Sensitivity
    /// unless they had also had the same history, and one of them is the Mac
    /// app and the other is the browser. A default that cannot be reproduced
    /// across the two is not a default worth having.
    ///
    /// So the picture has to come from a fixed window wide enough to survive
    /// not knowing the input level. Mean ink over pink and white noise, from
    /// the offline engine at ERB 0.6 -- the engine aims for 0.30 when it is
    /// choosing for itself:
    ///
    ///       input   -20   -40   -60   -80  -100  -120 dBFS
    ///        pink  0.74  0.62  0.51  0.39  0.28  0.16
    ///       white  0.71  0.60  0.48  0.37  0.25  0.14
    ///
    /// Never a black slab at the top, never blank at the bottom, and monotone
    /// in between. The cost is contrast: 170 dB from white to black is a soft
    /// picture, and 60 dB around wherever the signal actually is remains the
    /// better thing to read once you have found it. That is what the two
    /// sliders are for, and this is only where they start.
    var deskew            = false
    var invert            = false
    var autoGain          = false
    /// Where the middle of the level-to-grey window sits, and how wide it is.
    ///
    /// `sensDB` is the *negated* midpoint, so that turning it up moves the
    /// window down, more of the signal ends up above black, and the picture
    /// darkens -- the direction the word promises. `rangeDB` is the distance
    /// from white to black. Both are relative to the auto-gain reference when
    /// Auto gain is on and to full scale when it is off.
    ///
    /// This is the third shape. Gain and Level came first: Gain set where
    /// black was and Level how far below it white fell, so moving one moved
    /// the other end and the span you were looking at had to be worked out
    /// rather than read. White and black replaced them and did read directly
    /// -- but two ends of one scale *collide*. They cannot cross, they need a
    /// minimum separation, and the guard enforcing it has nowhere to push once
    /// one of them is against a limit. In the browser that guard failed
    /// silently and produced a one-decibel window: a picture with no grey in
    /// it anywhere, and nothing to say a setting had been refused.
    ///
    /// A midpoint and a width cannot interact at all, and the objection that
    /// sank Gain and Level does not apply to them, because here the span is
    /// itself a control rather than a consequence of two others.
    ///
    /// 95 and 170 -- a window from -180 to -10 dB -- chosen by measurement
    /// rather than taste, because with Auto gain off it is the only thing
    /// standing between a stranger and a blank screen. See the note on
    /// `autoGain` above for the numbers and for why the controller cannot do
    /// this job instead.
    ///
    /// Wide, and knowingly so. 70 and 60 -- the window that used to be written
    /// -100 to -40 -- is still the one the display is *read* at, and is worth
    /// reaching for the moment you can see where the signal is. It is simply
    /// not a safe place to start when nobody knows what the microphone is.
    var sensDB:  Double = 95
    var rangeDB: Double = 170

    /// Whether the spectrum trace is drawn over the picture.
    ///
    /// On by default. It is the newest column of the picture stood on its side
    /// -- the same numbers, against the same frequency scale -- so it says
    /// nothing the display is not already saying, and a stranger meeting it has
    /// the picture beside it to read it against.
    var showSpectrum: Bool = true

    /// Whether the waveform strip is drawn above the picture.
    ///
    /// Off by default, unlike the spectrum, because switching it on makes the
    /// window taller -- and a first launch that opened at an unexpected size,
    /// or squeezed the picture to make room for something nobody asked for,
    /// would be a worse introduction than an absent feature.
    var showWaveform: Bool = false

    /// How loud Play Selection is, in dB relative to what the microphone heard.
    ///
    /// Zero by default -- unity -- so that what you hear is the recording, not
    /// an opinion about it. The travel runs above unity as well as below
    /// because a microphone recording often sits well below full scale and
    /// nothing else in the app can lift it; anything that then exceeds full
    /// scale clips at the device, audibly, which is the right thing for an
    /// instrument to do rather than pretending to headroom it has not got.
    var replayGainDB: Double = 0

    /// The pair the view actually wants, so the sign of the negation is
    /// written down in exactly one place.
    var exposureWindow: (white: Double, black: Double) {
        (white: -sensDB - rangeDB / 2, black: -sensDB + rangeDB / 2)
    }
    /// Milliseconds per display column. Always one of `columnSteps`; the
    /// stored value is snapped on load so a defaults file written by an older
    /// build, or by hand, still lands on a detent.
    var columnMS: Double  = 4.0

    /// Tuning sharpness, as a multiple of one ERB.
    ///
    /// 1.0 is the psychoacoustic standard -- Glasberg & Moore's equivalent
    /// rectangular bandwidth, which is what human auditory filters measure.
    /// Below it the filters are sharper than hearing: more legible, less
    /// faithful. The difference is not subtle. On a 132 Hz voice, one ERB can
    /// produce ripple between harmonics only up to about the sixth, because
    /// above that the excitation pattern is genuinely flat; 0.7 ERB reaches
    /// the tenth. Whether that is an improvement depends on whether you are
    /// modelling the ear or trying to read the picture.
    ///
    /// This is a *design-time* parameter -- it takes a twenty-iteration fit to
    /// place the poles -- so each value is a separately baked coefficient
    /// file, and choosing one loads a different file rather than computing
    /// anything. See `prototype/export_coeffs.py --erb-scale`.
    ///
    /// 0.6, which is not the accurate value, and is the right default anyway.
    ///
    /// Two kinds of person arrive here. One wants to see what their voice
    /// looks like, and is served by the clearer picture. The other wants a
    /// representation faithful to what the cochlea does, and is served by 1.0
    /// -- but that person knows the difference exists, knows which way they
    /// want it, and will find the menu. The first person does not know there
    /// is a question, so the default should be the one that does not need to
    /// be understood to be worth looking at. Defaulting to fidelity would
    /// protect the reading of the user who was never going to be misled.
    ///
    /// It also settles a second question: the browser starts here too, and two
    /// programs claiming to be the same display should not draw the same file
    /// differently before anybody has touched a control. Neither Defaults
    /// button restores this, so a fresh start is the only place they can be
    /// made to agree.
    var erbScale: Double = 0.6

    /// Which quantity the picture is drawn from. Not persisted as an enum:
    /// a defaults file naming a mode a later build has dropped would be a
    /// nuisance, and the raw value is already what the engine wants.
    var displayMode: DisplayMode = .amplitude

    /// How much of the recent past the close-up strip shows, in milliseconds;
    /// zero is off. Mutually exclusive with De-skew, which works by delaying
    /// the whole picture by the apex's group delay and so has nothing recent
    /// to show.
    ///
    /// The *span* is what is stored, not the width, because the width that
    /// gives it depends on the Speed setting -- and what you want when you
    /// come back to the app is the same amount of time, not the same number of
    /// pixels.
    ///
    /// Off by default. It is the least self-explanatory thing in the window,
    /// and a stranger meeting a display already divided into two regions
    /// scrolling at different rates would reasonably conclude it was broken.
    var closeUpSpanMS: Double = 0

    /// How much room that span is given, in columns. The line's position.
    /// Snapped to a legal value whenever it is used, so a stored one from a
    /// wider window or a different Speed cannot put it somewhere illegal.
    var closeUpColumns = 400

    /// Where file playback goes, by CoreAudio device UID. Empty is the system
    /// default, which is what almost everybody wants and what the app did
    /// before there was any choice.
    ///
    /// The UID rather than the numeric device ID: an ID is handed out when a
    /// device appears and is not the same number after a reboot or a replug,
    /// so a stored one would eventually name whatever inherited it.
    var outputDeviceUID = ""

    /// Which of the output device's channels a played file goes to.
    /// 0 = every channel; 1 = channels 1-2; 2 = channels 3-4; and so on.
    ///
    /// Every channel is the default, and on an ordinary two-channel device it
    /// is *identical* to the normal behaviour -- the map comes out as [0, 1].
    /// It only does anything on a device with more than two, which is exactly
    /// the case where the stereo pair can land somewhere nobody is listening:
    /// an aggregate of a DAC plus a monitor's audio presents four channels,
    /// and if the DAC is the second pair, the default routing is silence.
    /// Sending to all of them means you hear it wherever you happen to be.
    var outputChannelPair = 0

    /// Diagnostics, all off unless asked for. Three separate destinations
    /// because they are useful in different situations: the readout on the
    /// picture while you are watching it, stdout when the app was launched
    /// from Xcode or a shell, the unified log when it was not.
    var logToConsole   = false
    var logToLogStream = false
    var showReadout    = false

    static let erbScales: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9,
                                      1.0, 1.1, 1.2, 1.3]

    /// How the close-up is sized.
    ///
    /// The spans span two different jobs. 160 ms is about ten frames at 60 Hz
    /// and is where the *whole* display has something to show: 20 peaks at
    /// 125 Hz, 10 at 64. The short ones are for the top of the picture, where
    /// a 20 ms window holds 320 cycles at 16 kHz and individual glottal pulses
    /// are separate events rather than a texture -- at the cost of the lowest
    /// two octaves, which hold 2.5 peaks at 125 Hz and 1.3 at 64 and say
    /// almost nothing. Neither is the right setting; they answer different
    /// questions.
    ///
    /// Span and width are both chosen -- the menu sets one, dragging the line
    /// sets the other -- and the magnification falls out of them, since
    /// span = width x ms-per-column.
    ///
    /// Two things bound the result, and both are expressed in the controls
    /// rather than left to be discovered:
    ///
    /// * the engine's column time cannot go below `minEngineMS`. It is
    ///   `columnMS / K` for whole K, so this is a ceiling on K, and it is a
    ///   real one: at 0.25 ms the display managed one frame in a second.
    /// * the strip cannot be narrower than `minCloseUpColumns` or wider than
    ///   half the window, which is a floor and a ceiling on the width.
    ///
    /// Because K is a whole number the width comes in steps, so the line
    /// snaps; and a span with no K satisfying both is greyed out on the menu.
    /// The engine's finest column time.
    ///
    /// 0.4 was set from a measurement taken while the picture was still stored
    /// row-major, when appending a column meant 599 scattered writes; the
    /// column-major change made that a single copy and the number was never
    /// re-derived. 0.05 ms is 20,000 columns a second, and it is where the
    /// information runs out rather than where the machine does: a tap at
    /// 16 kHz peaks every 0.0625 ms, so at 0.05 each peak is about one column
    /// and finer would only stretch what is already there.
    ///
    /// Which is, admittedly, the point at a short span -- stretched peaks read
    /// as separate events. If this wants to go lower the thing to watch is the
    /// audio thread: `emitColumn` does one `log10` per tap, which is 12 million
    /// a second here.
    static let minEngineMS = 0.05
    static let minCloseUpColumns = 40
    static let closeUpSpans: [Double] = [0, 5, 10, 20, 40, 80, 160, 320]

    /// Width in columns for a span at a given divisor.
    static func closeUpWidth(spanMS: Double, columnMS: Double, k: Int) -> Int {
        Int((spanMS * Double(k) / columnMS).rounded())
    }

    /// Divisors that give a legal strip, or nil when the span cannot be shown
    /// at all -- which is what greys it out.
    static func closeUpDivisors(spanMS: Double, columnMS: Double,
                                maxColumns: Int) -> ClosedRange<Int>? {
        guard spanMS > 0, columnMS > 0, maxColumns >= minCloseUpColumns
        else { return nil }
        let kCap = Int(columnMS / minEngineMS)
        guard kCap >= 2 else { return nil }
        let lo = max(2, Int((Double(minCloseUpColumns) * columnMS / spanMS).rounded(.up)))
        let hi = min(kCap, Int((Double(maxColumns) * columnMS / spanMS).rounded(.down)))
        guard lo <= hi else { return nil }
        return lo...hi
    }

    /// The legal width nearest the one asked for, and the divisor that gives
    /// it. Nil when the span cannot be shown.
    static func closeUpFit(spanMS: Double, columnMS: Double, maxColumns: Int,
                           desiredColumns: Int) -> (k: Int, columns: Int)? {
        guard let ks = closeUpDivisors(spanMS: spanMS, columnMS: columnMS,
                                       maxColumns: maxColumns) else { return nil }
        var bestK = ks.lowerBound
        var bestErr = Int.max
        for k in ks {
            let w = closeUpWidth(spanMS: spanMS, columnMS: columnMS, k: k)
            let e = abs(w - desiredColumns)
            if e < bestErr { bestErr = e; bestK = k }
        }
        return (bestK, closeUpWidth(spanMS: spanMS, columnMS: columnMS, k: bestK))
    }

    /// Whether any close-up at all is possible at this Speed. A divisor of at
    /// least two is what makes the strip finer than the main picture, and the
    /// engine ceiling caps the divisor, so below 0.8 ms per column there is
    /// nothing to be had.
    static func closeUpAvailable(_ columnMS: Double) -> Bool {
        Int(columnMS / minEngineMS) >= 2
    }

    /// The resource name a scale is baked into, matching export_coeffs.py.
    static func coefficientName(_ scale: Double, rate: Int = 88200) -> String {
        "cochlea_\(rate)_erb\(String(format: "%03d", Int((scale * 100).rounded())))"
    }

    static func nearestErbScale(_ v: Double) -> Double {
        // NaN fails every comparison, so `min(by:)` would silently return the
        // first element -- 0.5 -- rather than the default. Taken from
        // `Settings()` rather than written out, so that changing the default
        // cannot leave a stale number here to be reached by a corrupt file.
        guard v.isFinite else { return Settings().erbScale }
        return erbScales.min { abs($0 - v) < abs($1 - v) } ?? Settings().erbScale
    }

    /// Ranges, kept here so the sliders and the clamp cannot drift apart.
    /// What the two-knob slider spans. Wide enough to put black above the
    /// reference, which is useful when auto-gain has over-exposed a quiet
    /// passage, and to pull white far enough down to see the noise floor.
    ///
    /// The bottom was -90, and -90 turned out to be the floor of the room
    /// rather than the floor of the instrument. Six hundred taps divide a
    /// broadband signal six hundred ways: quiet pink noise at -70 dBFS puts
    /// each individual tap at -82 to -88, so the interesting part of a room
    /// tone was already pressed against the end of the slider before the
    /// middle ear took another two to eight decibels out of the top and bottom
    /// octaves. Measured on that signal, a window of -100 to -70 renders a
    /// mean of 33 out of 255; -120 to -90 renders 156. The detail was there
    /// the whole time and the control could not reach it.
    /// And then it happened a second time, for the same reason, which is why
    /// the bottom is now -200 rather than the -130 the paragraph above argued
    /// its way to. On an iPad the browser version's whole picture sat below
    /// -130 and clipped to white, and no setting could reach it; the argument
    /// for -130 had been about the level of the *input*, where it is indeed
    /// below any converter's noise floor, but the scale is per tap and 599
    /// narrow filters divide the signal among themselves. Nothing bottoms out
    /// until kTinyLevel, which is also what an untouched column reads. That
    /// floor has since been moved from -240 to -600 dB, because -240 was
    /// inside a window this range can express and silence was drawn grey.
    ///
    /// The general lesson, twice paid for: the end of a range is a claim about
    /// what the instrument will ever be pointed at, and it should be set by
    /// where the arithmetic gives out, not by where the signal is expected.
    ///
    /// That history is about the white/black pair, which no longer exists. It
    /// is kept because the lesson is what set the two ranges below.

    /// What Sensitivity spans, as a negated midpoint. The measurement behind
    /// the numbers: the cascade is linear, so input level maps one-for-one
    /// onto a shift of the window -- median tap level runs -53.3 / -103.3 /
    /// -153.3 dB for inputs of -20 / -70 / -120 dBFS. Covering digital full
    /// scale down to a very quiet phone microphone is a midpoint from -10 to
    /// -190, rounded out to 200.
    ///
    /// Not chosen so that the two ends are "all white" and "all black". That
    /// guarantee needs the window pushed past the tails of the distribution,
    /// and the tails run eighty decibels beyond the first percentile: the last
    /// third of the travel would do nothing but chase a signal that is not
    /// there. The window is free to hang off either end of the level scale,
    /// which is harmless, because levels outside it simply clamp.
    static let sensitivityRange = 0.0 ... 200.0
    /// What Range spans. Below about five decibels the picture stops being a
    /// grey scale and becomes a threshold; above two hundred there is nothing
    /// outside the window left to bring in.
    static let rangeRange = 5.0 ... 200.0
    /// What the RePlay volume slider spans, in dB about unity. Forty below is
    /// as quiet as anything needs to be before the bottom of the travel, which
    /// is silence rather than -40; twelve above brings a recording that peaks
    /// around -20 dBFS up to a comfortable level without inviting clipping on
    /// one that does not need it.
    static let replayGainRange = -40.0 ... 12.0
    static let columnRange =   0.5 ... 64.0

    /// The Time control's detents: ten equal *ratios* across the range, not
    /// ten equal numbers of milliseconds. A time scale is a ratio quantity --
    /// the step from 1 ms to 2 ms is the same change as the step from 32 to 64
    /// -- so equal spacing on screen has to mean equal spacing in the log.
    ///
    /// 0.5 to 64 ms is 128x, seven octaves. Divided fourteen ways each step is
    /// exactly half an octave -- a ratio of root two -- which puts 0.5, 1, 2,
    /// 4, 8, 16, 32 and 64 all on the grid with one detent between each pair.
    /// Two presses of a bracket key is therefore a doubling, exactly.
    static let columnDivisions = 14
    static let columnSteps: [Double] = (0...columnDivisions).map { i in
        columnRange.lowerBound
            * pow(columnRange.upperBound / columnRange.lowerBound,
                  Double(i) / Double(columnDivisions))
    }

    /// Nearest detent, measured in the log -- 3 ms is nearer to 3.48 than to
    /// 2.14 by ratio even though it is equidistant by subtraction.
    static func nearestColumnStep(_ ms: Double) -> Int {
        let target = log(max(ms, 1e-9))
        var best = 0
        var bestErr = Double.greatestFiniteMagnitude
        for (i, v) in columnSteps.enumerated() {
            let err = abs(log(v) - target)
            if err < bestErr { bestErr = err; best = i }
        }
        return best
    }

    /// How a detent is written in its tooltip. Two significant figures is
    /// enough to tell any two of them apart.
    static func columnLabel(_ ms: Double) -> String {
        if ms < 1 { return String(format: "%.2f mS", ms) }
        if ms < 10 { return String(format: "%.1f mS", ms) }
        return String(format: "%.0f mS", ms)
    }

    // MARK: - storage

    private enum K {
        static let erbScale = "display.erbScale"
        static let deskew   = "display.deskew"
        static let invert   = "display.invert"
        static let autoGain = "display.autoGain"
        static let sens     = "display.sensitivityDB"
        static let range    = "display.rangeDB"
        /// Two superseded shapes of the same setting, each still read once so
        /// that an upgrade carries somebody's display over rather than
        /// silently resetting it. white/black replaced gain/level; sensitivity
        /// and range replaced white/black.
        static let white    = "display.whiteDB"
        static let black    = "display.blackDB"
        static let oldGain  = "display.gainDB"
        static let oldLevel = "display.levelDB"
        static let column   = "display.columnMS"
        static let mode     = "display.mode"
        static let closeUp  = "display.closeUpSpanMS"
        static let closeUpW = "display.closeUpColumns"
        static let outDev   = "audio.outputDeviceUID"
        static let outPair  = "audio.outputChannelPair"
        static let spectrum = "display.spectrum"
        static let waveform = "display.waveform"
        static let replayDB = "audio.replayGainDB"
        static let logCon   = "diagnostics.console"
        static let logOS    = "diagnostics.logStream"
        static let readout  = "diagnostics.readout"

        static let all = [deskew, invert, autoGain, sens, range, column,
                          erbScale, mode, closeUp, closeUpW, spectrum, waveform,
                          outDev, outPair, replayDB, logCon, logOS, readout,
                          white, black, oldGain, oldLevel]
    }

    /// AppKit's own frame autosave writes the window's size and position under
    /// this name, in the same defaults domain, so there is nothing to do for
    /// geometry beyond naming it -- see `AppDelegate.buildWindow`.
    static let windowAutosaveName = "main"

    /// The key AppKit uses for that. An implementation detail, but a stable
    /// one, and reset has to be able to clear it too.
    static let windowFrameKey = "NSWindow Frame " + windowAutosaveName

    /// Absent keys keep the default: `UserDefaults.double(forKey:)` returns 0
    /// for a missing key, which is a legal gain and an illegal column width,
    /// so presence has to be asked about rather than inferred.
    static func load(from store: UserDefaults = .standard) -> Settings {
        var s = Settings()
        if store.object(forKey: K.deskew)   != nil { s.deskew   = store.bool(forKey: K.deskew) }
        if store.object(forKey: K.invert)   != nil { s.invert   = store.bool(forKey: K.invert) }
        if store.object(forKey: K.autoGain) != nil { s.autoGain = store.bool(forKey: K.autoGain) }
        if store.object(forKey: K.sens)  != nil { s.sensDB  = store.double(forKey: K.sens) }
        if store.object(forKey: K.range) != nil { s.rangeDB = store.double(forKey: K.range) }

        // Carried over from whichever earlier shape is on disk, once, and only
        // if the current one is not. Both older shapes name the two ends, so
        // they convert through the same two lines.
        if store.object(forKey: K.sens) == nil {
            var ends: (white: Double, black: Double)? = nil
            if store.object(forKey: K.white) != nil,
               store.object(forKey: K.black) != nil {
                ends = (store.double(forKey: K.white),
                        store.double(forKey: K.black))
            } else if store.object(forKey: K.oldGain) != nil
                   || store.object(forKey: K.oldLevel) != nil {
                // Gain set the reference (negated); Level set how far below
                // it white fell.
                let ref = -store.double(forKey: K.oldGain)
                let depth = store.object(forKey: K.oldLevel) != nil
                          ? store.double(forKey: K.oldLevel) : 35
                ends = (ref - depth, ref)
            }
            if let e = ends {
                s.rangeDB = e.black - e.white
                s.sensDB  = -(e.white + e.black) / 2
            }
        }
        if store.object(forKey: K.column)   != nil { s.columnMS = store.double(forKey: K.column) }
        if store.object(forKey: K.erbScale) != nil { s.erbScale = store.double(forKey: K.erbScale) }

        // A half-written or hand-edited defaults file would otherwise put a
        // slider outside its range, where nothing crashes and the picture is
        // quietly wrong. That is the worst kind of bug to be handed, so the
        // values are made safe on the way in rather than trusted.
        // `isFinite` before the clamp, not after: a NaN out of a hand-edited
        // plist survives min and max in Swift as it does in JavaScript, and a
        // NaN window renders an all-black picture that nothing but deleting
        // the defaults can undo.
        if store.object(forKey: K.spectrum) != nil {
            s.showSpectrum = store.bool(forKey: K.spectrum)
        }
        if store.object(forKey: K.waveform) != nil {
            s.showWaveform = store.bool(forKey: K.waveform)
        }
        if store.object(forKey: K.replayDB) != nil {
            s.replayGainDB = store.double(forKey: K.replayDB)
        }
        if !s.sensDB.isFinite  { s.sensDB  = Settings().sensDB }
        if !s.rangeDB.isFinite { s.rangeDB = Settings().rangeDB }
        if !s.replayGainDB.isFinite { s.replayGainDB = Settings().replayGainDB }
        s.sensDB  = clamp(s.sensDB,  to: sensitivityRange)
        s.rangeDB = clamp(s.rangeDB, to: rangeRange)
        s.replayGainDB = clamp(s.replayGainDB, to: replayGainRange)
        s.columnMS = columnSteps[nearestColumnStep(s.columnMS)]
        // Only the baked scales exist as files; anything else would fail to
        // load and leave the app with no cochlea at all.
        s.erbScale = nearestErbScale(s.erbScale)
        // An unknown raw value means a defaults file from a build that had a
        // mode this one does not; fall back rather than refuse to start.
        if store.object(forKey: K.closeUp) != nil {
            s.closeUpSpanMS = max(0, min(store.double(forKey: K.closeUp), 2000))
        }
        if let uid = store.string(forKey: K.outDev) { s.outputDeviceUID = uid }
        if store.object(forKey: K.outPair) != nil {
            s.outputChannelPair = max(0, store.integer(forKey: K.outPair))
        }
        if store.object(forKey: K.logCon) != nil {
            s.logToConsole = store.bool(forKey: K.logCon)
        }
        if store.object(forKey: K.logOS) != nil {
            s.logToLogStream = store.bool(forKey: K.logOS)
        }
        if store.object(forKey: K.readout) != nil {
            s.showReadout = store.bool(forKey: K.readout)
        }
        if store.object(forKey: K.closeUpW) != nil {
            s.closeUpColumns = max(minCloseUpColumns,
                                   min(store.integer(forKey: K.closeUpW), 4000))
        }
        // De-skew wins: the two cannot both be on, and a defaults file could
        // have been written by hand.
        if s.deskew { s.closeUpSpanMS = 0 }
        if store.object(forKey: K.mode) != nil {
            s.displayMode = DisplayMode(rawValue: Int32(store.integer(forKey: K.mode)))
                         ?? .amplitude
        }
        return s
    }

    func save(to store: UserDefaults = .standard) {
        store.set(deskew,   forKey: K.deskew)
        store.set(invert,   forKey: K.invert)
        store.set(autoGain, forKey: K.autoGain)
        store.set(sensDB,   forKey: K.sens)
        store.set(rangeDB,  forKey: K.range)
        store.set(columnMS, forKey: K.column)
        store.set(erbScale, forKey: K.erbScale)
        store.set(Int(displayMode.rawValue), forKey: K.mode)
        store.set(closeUpSpanMS, forKey: K.closeUp)
        store.set(closeUpColumns, forKey: K.closeUpW)
        store.set(outputDeviceUID, forKey: K.outDev)
        store.set(outputChannelPair, forKey: K.outPair)
        store.set(showSpectrum,   forKey: K.spectrum)
        store.set(showWaveform,   forKey: K.waveform)
        store.set(replayGainDB,   forKey: K.replayDB)
        store.set(logToConsole,   forKey: K.logCon)
        store.set(logToLogStream, forKey: K.logOS)
        store.set(showReadout,    forKey: K.readout)
    }

    /// Forget everything, window geometry included. Removing the keys rather
    /// than writing the defaults over them means a later change to a default
    /// reaches anyone who has reset.
    static func forgetEverything(in store: UserDefaults = .standard) {
        for key in K.all { store.removeObject(forKey: key) }
        store.removeObject(forKey: windowFrameKey)
    }

    private static func clamp(_ v: Double, to r: ClosedRange<Double>) -> Double {
        // NaN fails both comparisons, so it would survive a naive min/max.
        guard v.isFinite else { return r.lowerBound }
        return Swift.min(r.upperBound, Swift.max(r.lowerBound, v))
    }
}
