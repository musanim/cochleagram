import AppKit
import AVFoundation
import QuartzCore                // CADisplayLink, macOS 14+
import UniformTypeIdentifiers  // NSOpenPanel.allowedContentTypes

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var view: CochleagramView!
    /// One of these drives redraw; see `startRedrawClock`. The link is held as
    /// `AnyObject` because `CADisplayLink` did not reach macOS until 14 and
    /// the deployment target is 12.
    private var timer: Timer?
    private var displayLink: AnyObject?

    private let audio = AudioSource()
    private var cochlea: Cochlea?

    /// Everything the toolbar controls, restored from the last run.
    /// The controls are seeded from it, and it is written back on every
    /// change, so it is the single source of truth for display state.
    private var settings = Settings.load()

    private var autoGain: Bool { settings.autoGain }
    /// Milliseconds of audio per display column -- the horizontal scale.
    private var columnMS: Double { settings.columnMS }

    private var paused = false
    /// Set when a file has played to its end. There is nothing left to resume,
    /// so space means "back to the microphone" rather than "play".
    private var fileFinished = false
    /// Whether this file's green line has been drawn. Two things now want to
    /// draw it -- the sample boundary, which is where it belongs, and the
    /// output's completion, which is the only one a file stopped early will
    /// ever reach -- and exactly one of them should win.
    private var fileEndMarked = false
    /// Whether the finished file's graph has been taken down. Teardown removes
    /// the tap, so it cannot happen until the tap has delivered the tail.
    private var fileTornDown = false
    /// When to stop waiting for that tail. A file that was stopped rather than
    /// finished never reaches its own last sample, so the wait needs an end.
    private var fileEndDeadline: CFTimeInterval?
    private var keyMonitor: Any?

    /// The last file played, and the button that replays it. Session-scoped:
    /// remembering it across launches would mean holding a security-scoped
    /// bookmark, which is a lot of machinery for a convenience.
    private var lastFileURL: URL?
    /// True once the current file has run to its end. Replay is hidden until
    /// then: before a file has been heard through, "again" has no referent.
    private var hasPlayedThrough = false
    private var replayButton: NSButton!
    private let fileNameLabel = NSTextField(labelWithString: "")

    private var deskewBox: NSButton!
    private var closeUpPopup: NSPopUpButton!
    private var invertBox: NSButton!
    private var autoBox: NSButton!
    private var defaultsButton: NSButton!
    private var sensSlider: NSSlider!
    private var rangeSlider: NSSlider!
    private var timeButtons: [NSButton] = []
    private var erbPopup: NSPopUpButton!
    private var modePopup: NSPopUpButton!
    private var pauseButton: NSButton!
    private var spectrumButton: NSButton!
    private var waveformButton: NSButton!

    // ---- RePlay ---------------------------------------------------------
    //
    // Hearing what is on screen. Only ever offered on a frozen picture from
    // live input: a file is already audible and already on disk, so a second
    // way to play it would be two controls doing one job.
    /// Named for what it plays, not for the feature: `replayButton` is already
    /// taken by the button that plays the *file* again, and the two are
    /// different enough that sharing a name would be a trap.
    private var selectionButton: NSButton!
    private var selectionSlider: NSSlider!
    private var selectionDivider: NSView!
    /// The samples the picture was drawn from, and the arithmetic that turns a
    /// column back into a position in them.
    private let recorder = ReplayRecorder()
    /// Where the sound started, in engine columns, so the moving line can be
    /// placed without asking the audio graph what it is playing.
    private var replayFromColumn: Int64 = 0
    private var replayToColumn: Int64 = 0
    /// Where in the recording the sound began, taken once at the start.
    private var replayFromSample: Int64 = 0
    /// The picture's numbering when recording began. A wipe restarts it, and a
    /// column index from before the wipe names other audio.
    private var recordedEpoch = -1
    /// What the recorder was last told a column is worth, so a change of Speed
    /// can be noticed without asking every frame.
    private var recordedPerColumn = 0.0
    /// And how far behind the sound the picture was, which De-skew changes by
    /// nearly two hundred milliseconds. `-1` is "not yet asked".
    private var recordedLag: Int64 = -1

    /// Settings lives in its own window rather than the toolbar. Held so it
    /// survives being closed -- with `isReleasedWhenClosed` left at its
    /// default, reopening a closed window is a use-after-free.
    private var settingsWindow: NSWindow?
    private var devicePopup: NSPopUpButton!
    private var outputPopup: NSPopUpButton!
    private var outputDevices: [AudioDevice] = []
    private var channelPopup: NSPopUpButton!
    private var readoutBox: NSButton!
    private var consoleBox: NSButton!
    private var logStreamBox: NSButton!
    private let deviceSummary = NSTextField(labelWithString: "")
    private var devices: [AudioDevice] = []
    private let status = NSTextField(labelWithString: "")

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        // Tool tips immediately, rather than after the system's
        // second-and-a-half.
        //
        // The tips here are not the usual "what does this button do", which
        // you only ask once: they carry *values* -- what a Speed detent is in
        // milliseconds, how much time the window holds -- and a value you have
        // to hold still for is a value you stop asking for. So they behave
        // less like help and more like a readout that follows the pointer,
        // which is what a readout should do.
        //
        // 1 rather than 0, because zero is the value a preference has when it
        // is absent, and a framework reading it that way would take it to mean
        // "unset" and use its own default. One millisecond is indistinguishable
        // from none and cannot be mistaken for nothing.
        //
        // `NSInitialToolTipDelay` is long-standing but undocumented. It has
        // to be *set*, not registered: AppKit reads it through
        // `CFPreferencesCopyAppValue`, which sees the application's own
        // preferences domain and not `UserDefaults`' registration domain --
        // so a registered value is invisible to it, which is why the first
        // attempt at this changed nothing at all.
        //
        // The cost is that it lands in the preferences file. That is a fair
        // trade for a value the app is choosing rather than reading.
        UserDefaults.standard.set(1, forKey: "NSInitialToolTipDelay")
        buildWindow()
        startRedrawClock()
        installKeyMonitor()
        startLiveInput(deviceID: nil)      // nil = whatever the system default is
    }

    /// Drive redraw from the screen's own refresh where that is available.
    ///
    /// A 60 Hz `Timer` is not locked to anything: on a 120 Hz display it
    /// beats against the refresh, and even on a 60 Hz one it drifts, so the
    /// scroll advances by an uneven number of columns per frame. That reads as
    /// judder however smoothly the audio is arriving. A display link fires
    /// once per frame, by definition.
    ///
    /// The engine queues columns regardless of when we look, so a late frame
    /// costs nothing but a slightly bigger scroll step.
    private func startRedrawClock() {
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: self,
                                        selector: #selector(redrawTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            Log.say("REDRAW driven by the display link")
            return
        }
        // Built rather than scheduled, so adding it to .common mode does not
        // register it twice.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.frameTick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.say("REDRAW driven by a 60 Hz timer (macOS 13 or earlier)")
    }

    /// The link passes itself as the argument; the timer path passes nothing.
    /// Both land here.
    @objc private func redrawTick(_ sender: AnyObject?) { frameTick() }

    private func frameTick() {
        captureTick()
        // Before the columns land, so that a hole whose turn has come is
        // marked on the column at the edge now rather than behind the batch
        // about to arrive. Unlike `view.tick`'s own dropped-column seam, this
        // one waits for the cascade to catch up first; see `markInputDropouts`.
        markInputDropouts()
        view.tick()
        // What has scrolled off the left of the picture is audio nobody can
        // select any more, and this is the whole of the memory policy: the
        // recording is as long as the picture is wide.
        if let drawn = view.drawnColumns { recorder.trim(olderThan: drawn.lo) }
        replayTick()
        // Position and fill the spectrum window. Every frame rather than on a
        // resize notification: the frame depends on the window's position, its
        // size, the toolbar's height and which screen it is on, and one cheap
        // recomputation is less to get wrong than four observers.
        updateSpectrum()
        // The end of the file, as the audio defines it: the frame after the
        // last one was fed to the cascade. Noticed here rather than signalled
        // from the audio thread, which is not a place to be scheduling work.
        if audio.fileSamplesEnded { markFileEndOnce() }
        // And the teardown, which waits for that as well as for the output.
        endFileIfReady()
        showAutoSensitivity()
        reportAudioMeters()
    }

    /// `Settings.clamp` is private to `Settings`, and this is the one place
    /// outside it that needs the same limits applied.
    private static func clampSens(_ v: Double) -> Double {
        min(Settings.sensitivityRange.upperBound,
            max(Settings.sensitivityRange.lowerBound, v))
    }

    /// Last value written to the Sensitivity control, so it is touched only
    /// when what it shows would change rather than sixty times a second.
    private var shownSens: Double?

    /// While Auto gain is on, Sensitivity reports what the controller has
    /// arrived at: the setting in force is then visible, not merely in effect.
    ///
    /// The knob can pin at either end while the reference goes further, in
    /// which case it stops reporting -- but reaching that needs a source more
    /// than two hundred decibels from where Sensitivity was left.
    private func showAutoSensitivity() {
        guard settings.autoGain else { shownSens = nil; return }
        let v = Self.clampSens((settings.sensDB - view.autoReferenceDB).rounded())
        guard v != shownSens else { return }
        shownSens = v
        sensSlider.doubleValue = v
    }

    // MARK: - metering
    //
    // The audio thread counts; this turns counts into a sentence. It used to
    // happen on the audio thread, which was tolerable when a buffer covered
    // 100 ms and is not now that one covers 6.

    private var lastMeters = AudioSource.Meters()
    private var lastMeterReport = Date()
    private var lastRenderErrors: UInt64 = 0

    private func reportAudioMeters() {
        let now = Date()
        let dt = now.timeIntervalSince(lastMeterReport)
        guard dt >= 1.0 else { return }
        lastMeterReport = now

        let m = audio.meters
        let samples = m.samples - lastMeters.samples
        let buffers = m.buffers - lastMeters.buffers
        let dsp = m.dspSeconds - lastMeters.dspSeconds
        lastMeters = m
        guard buffers > 0 else { return }

        let rate = audio.sampleRate
        let perSec = Double(samples) / dt
        let ratio = perSec / max(rate, 1)
        // Seconds of CPU per second of audio. Measured against the audio
        // covered, not against wall clock, so it stays meaningful even when
        // the device is misbehaving.
        let load = dsp / max(Double(samples) / max(rate, 1), 1e-9)
        let msPerBuffer = Double(m.lastFrames) * 1000 / max(rate, 1)

        Log.say(String(format:
            "AUDIO %.0f samples/s (format claims %.0f) — %.2fx; "
            + "%d buffers/s, %d frames each (%.1f ms); DSP load %.2f%@%@",
            perSec, rate, ratio, buffers, m.lastFrames, msPerBuffer, load,
            ratio < 0.95 ? "  *** DEVICE NOT KEEPING UP ***" : "",
            load > 0.9 ? "  *** NOT REAL TIME ***" : ""))

        // The tail of a burst of dropouts, if one stopped inside this second.
        flushDropLog()

        // Greater than, not different from: the count goes back to zero when
        // the input unit is replaced, and "0 errors" is not news.
        let errors = audio.renderErrors
        if errors > lastRenderErrors {
            Log.say("AUDIO render errors: \(errors)")
        }
        lastRenderErrors = errors
    }

    private func stopRedrawClock() {
        timer?.invalidate()
        timer = nil
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ note: Notification) {
        stopRedrawClock()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        audio.stop()
        tearDownSpectrum()
    }

    /// Detach and hide the spectrum window. Idempotent: it runs from the main
    /// window closing and again at termination, and either may come first.
    private func tearDownSpectrum() {
        guard let w = spectrumWindow else { return }
        // Detached before it is hidden. A child window left attached to a
        // window that is going away is the kind of thing AppKit tolerates until
        // it does not, and this one is created behind the scenes -- so it is
        // taken down the same way.
        if w.parent != nil { window?.removeChildWindow(w) }
        w.orderOut(nil)
        spectrumWindow = nil
        spectrumView = nil
    }

    // MARK: - keyboard
    //
    // A local monitor rather than the responder chain: the buttons and sliders
    // in the toolbar would otherwise swallow space, and there is nothing here
    // that wants a literal space character.

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            // Only when the cochleagram itself is frontmost. The monitor sees
            // every key the app receives, so without this, space would pause
            // the display while you were typing in Settings.
            guard self.window.isKeyWindow else { return event }
            // Escape dismisses a measurement, and only that: swallowing it
            // when there is nothing to dismiss would stop it doing whatever
            // else it does -- closing a sheet, cancelling a drag in a panel.
            if event.keyCode == 53 {
                guard self.view.hasMeasurement else { return event }
                self.view.clearMeasurement()
                return nil
            }
            switch event.charactersIgnoringModifiers {
            case " ":
                self.togglePause()
                return nil
            case "[":
                // One detent, not a doubling: a doubling no longer lands on
                // one, and a control that cannot be reached from the keyboard
                // it shares with the mouse is worse than a coarser step.
                self.stepTime(by: +1)         // slower scroll, wider view
                return nil
            case "]":
                self.stepTime(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    private func togglePause() {
        // A file that has run out has nothing to resume. Rather than have the
        // space bar do nothing at all, it takes you back to live input on the
        // device the menu is showing.
        if fileFinished {
            fileFinished = false
            startLiveInput(deviceID: selectedDeviceID)
            return
        }
        setPaused(!paused)
    }

    /// Freeze or resume, and say so on the picture.
    ///
    /// Separate from `togglePause` because opening a file has to do this too:
    /// a modal file panel runs its own event loop, so the display stops
    /// whatever we do. Stopping it *deliberately* first, with the seam that a
    /// pause would leave, turns an unexplained hitch into something the
    /// picture accounts for.
    private func setPaused(_ on: Bool) {
        paused = on
        let live = !audio.isFilePlayback
        view.discardWhilePaused = live
        view.isPaused = paused
        audio.setPaused(paused)

        // Live input cannot be paused, only ignored. Everything that arrives
        // while the display is frozen is thrown away, so resuming butts
        // together two moments that were never adjacent -- and nothing in the
        // picture would say so. Mark the join now, while it is still the
        // newest column; it then scrolls away with the sound either side of
        // it. A file is genuinely paused and loses nothing, so there is no
        // seam to mark and drawing one would be a lie in the other direction.
        if paused && live { view.markSeam() }

        // Resuming starts the picture moving again and starts recording over
        // what was being played, so it is the one control that must interrupt.
        //
        // *Before* capture is turned back on, not after. Stopping a playback is
        // not instantaneous -- the graph has its own buffered latency to drain
        // -- and with the microphone already recording, the tail of the
        // selection would come back in through it and be written into the ring
        // as though it were the room.
        if !paused {
            stopReplay()
            // A new stretch: the interval just skipped is in neither the
            // picture nor the recording, so the old terms no longer describe
            // what arrives next.
            recordedPerColumn = 0
        }
        // Recording follows the picture exactly. Nothing is kept while the
        // display is frozen, so the recording skips the same interval the
        // picture skips and a selection spanning the seam plays straight across
        // it -- the join the red line marks, and no gap to reason about. It
        // also keeps the microphone from recording the playback it is about to
        // hear out of the speakers. See REPLAY-DESIGN.md.
        cochlea?.capturing = live && !paused

        showPauseButton()
        showReplayControls()
        report(paused
               ? (live ? "Paused — the red line is where time will jump."
                       : "Paused — space resumes.")
               : "Running.")
    }

    /// Move to a detent by index. Everything that changes the time scale --
    /// the buttons, the bracket keys, a restored setting -- goes through here,
    /// so the scale can only ever be one of the eleven.
    private func setColumnStep(_ index: Int) {
        let i = min(Settings.columnSteps.count - 1, max(0, index))
        // Clicking the selected button, or pressing `[` at the end of the
        // range, is not a change and must not leave a mark.
        guard i != Settings.nearestColumnStep(columnMS) else { return }
        settings.columnMS = Settings.columnSteps[i]
        // The divisor is derived from the main column time, so changing Speed
        // changes the engine's rate as well when the close-up is open.
        applyCloseUp()
        // A blue line where the scale changed: everything to its left was
        // drawn at a different number of milliseconds per column, so widths
        // either side of it are not comparable. Marked now, while this is
        // still the newest column, so it travels with the join.
        view.markScaleChange()
        // The picture is deliberately NOT wiped. What is already on screen was
        // drawn at the old scale and the new columns arrive at the new one, so
        // strictly the image becomes two scales side by side -- but you asked
        // for the change, you can see where it happened, and what is on screen
        // is usually the thing you are changing scale in order to look at.
        // Throwing it away to preserve a purity nobody was in doubt about
        // costs more than it protects.
        showTimeStep()
        reportTimeScale()
        save()
    }

    /// What a Speed button says when the pointer rests on it: its own column
    /// time, and how much of the past the window would then hold.
    ///
    /// Each button answers for *itself* rather than reporting the current
    /// setting, so the row reads as a set of alternatives -- hovering along it
    /// tells you what you would get. On the selected button that is the
    /// current width, which is the other thing somebody might have wanted.
    private func speedTip(_ ms: Double) -> String {
        let s = viewSpanSeconds(ms)
        let n = s >= 10 ? String(format: "%.0f", s)
              : s >= 1  ? String(format: "%.1f", s)
                        : String(format: "%.2f", s)
        // Both lines named, not just the second: a bare number above a
        // labelled one reads as a heading for it rather than as a separate
        // quantity, which is exactly what it is not.
        return "Resolution: " + Settings.columnLabel(ms)
             + "\nView width: \(n) seconds"
    }

    /// How much time the picture would hold at a given column time.
    ///
    /// Not simply columns x milliseconds: with the close-up open the right
    /// hand strip runs faster, so it holds its own span and the main region
    /// holds the rest. And the fit has to be worked out for the *candidate*
    /// column time rather than the current one -- the divisor, and with it
    /// the strip's width, changes with Speed, and at some speeds the close-up
    /// cannot be fitted at all.
    private func viewSpanSeconds(_ ms: Double) -> Double {
        let cols = view.columnCount
        guard cols > 0 else { return 0 }
        let on = settings.closeUpSpanMS > 0 && !settings.deskew
                 && Settings.closeUpAvailable(ms)
        let fit = on ? Settings.closeUpFit(spanMS: settings.closeUpSpanMS,
                                           columnMS: ms,
                                           maxColumns: view.maxCloseUpColumns,
                                           desiredColumns: settings.closeUpColumns)
                     : nil
        let near = min(fit?.columns ?? 0, cols)
        // The strip's own span from its own columns, not from the setting:
        // the width is a whole number of columns, so what is drawn is the
        // setting rounded, and this is the number the picture agrees with.
        let nearMS = fit.map { Double(near) * ms / Double($0.k) } ?? 0
        return (Double(cols - near) * ms + nearMS) / 1000
    }

    private func showTimeStep() {
        let i = Settings.nearestColumnStep(columnMS)
        for (k, b) in timeButtons.enumerated() { b.state = k == i ? .on : .off }
    }

    private func reportTimeScale() {
        // Columns, not view width: the picture no longer spans the whole view
        // now that there is a gutter for the frequency scale.
        let across = Double(view.columnCount) * columnMS / 1000.0
        report(String(format: "%.2f ms/column — %.1f s across the window",
                      columnMS, across))
    }

    // MARK: - UI

    private func buildWindow() {
        view = CochleagramView()
        view.translatesAutoresizingMaskIntoConstraints = false

        // Two rows. One row ran to about 1100 points once everything was in
        // it, which set a floor on how narrow the window could be for no
        // reason but arrangement. Vertical space is the thing there is plenty
        // of.
        //
        // Grouped by how often you touch them: the upper row is what you set
        // for a session -- tuning, de-skew -- and the transport; the lower row
        // is what you move while watching a picture.
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 10

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 10

        let bar = NSStackView(views: [topRow, bottomRow])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false

        // The controls below are built empty. Every one of them is seeded by
        // `showSettingsInControls` further down, so only one place knows what
        // a control's starting position should be and there is nothing for a
        // stale literal here to disagree with.

        // ---- upper row -------------------------------------------------

        // Pause, first, in its own compartment. Space has always done this;
        // the button exists because space does not reach a Mac being used over
        // screen sharing with the keyboard somewhere else, and because nothing
        // in the window said the key existed.
        //
        // At the head of the row rather than between the display controls and
        // the file controls, which is where it used to sit on the reasoning
        // that it belonged to neither. It belongs to neither, but the browser
        // puts it first, and a transport control that changes position between
        // two versions of the same instrument is worse than one filed under
        // the wrong heading.
        pauseButton = button("", #selector(pauseButtonPressed(_:)))
        pauseButton.imagePosition = .imageOnly
        topRow.addArrangedSubview(pauseButton)

        topRow.addArrangedSubview(divider())

        // The spectrum trace: the newest column of the picture stood on its
        // side, in its own window beyond the right-hand edge of this one.
        //
        // A drawn icon rather than an SF Symbol. The symbol set has waveforms
        // and none of them is a single clean cycle, and what this control turns
        // on is a curve of amplitude against frequency rather than "audio" in
        // general. Acknowledged as not right yet -- a sine says "one tone",
        // where the trace is a whole spectrum -- but it is a shape, not a word,
        // and it will do until there is a better one.
        spectrumButton = button("", #selector(toggleSpectrum(_:)))
        makeIconToggle(spectrumButton,
                       off: Self.spectrumIcon(paper: nil),
                       on: Self.spectrumIcon(paper: Self.iconPaperOn),
                       #selector(toggleSpectrum(_:)))
        spectrumButton.toolTip = "Draw the newest column as a solid shape, "
                               + "level running right from the picture's edge "
                               + "and outside the window. The same numbers the "
                               + "picture is drawn from, and the same exposure "
                               + "window, so it moves with Sensitivity and "
                               + "Range. Nothing shows if the window is hard "
                               + "against the right of the screen, or full "
                               + "screen: there is nowhere for it to go."
        topRow.addArrangedSubview(spectrumButton)

        // And the waveform strip: the sound the picture was made from, above
        // it and sharing its columns. Same icon as the spectrum for now, which
        // is wrong in an obvious way and will be replaced.
        waveformButton = button("", #selector(toggleWaveform(_:)))
        waveformButton.setButtonType(.pushOnPushOff)
        waveformButton.image = Self.sineIcon()
        waveformButton.imagePosition = .imageOnly
        waveformButton.toolTip = "Draw the waveform above the picture, sharing "
                               + "its columns. Scaled by Sensitivity: a sound "
                               + "loud enough to render solid black fills most "
                               + "of the strip, and both saturate together. "
                               + "Switching it on makes the window taller "
                               + "rather than making the picture shorter."
        topRow.addArrangedSubview(waveformButton)

        // Matched to the bezelled button beside it rather than to a number.
        // Its own intrinsic size is its image, which is smaller, and AppKit's
        // bezel metrics are not something to write down here and have go stale.
        NSLayoutConstraint.activate([
            spectrumButton.widthAnchor.constraint(
                equalTo: waveformButton.widthAnchor),
            spectrumButton.heightAnchor.constraint(
                equalTo: waveformButton.heightAnchor),
        ])

        topRow.addArrangedSubview(divider())

        // Tuning sharpness. Each entry is a separately baked coefficient
        // file, so this is a chooser, not a computation.
        //
        // The unit is in each item rather than in a label beside the menu:
        // one control instead of two, and a menu whose entries read as
        // measurements rather than as bare numbers that could be anything.
        erbPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        erbPopup.target = self
        erbPopup.action = #selector(erbScaleChanged(_:))
        for scale in Settings.erbScales {
            erbPopup.addItem(withTitle: String(format: "ERB %.1f", scale))
        }
        erbPopup.toolTip = "Filter bandwidth as a multiple of one ERB. "
                         + "1.0 matches human hearing; lower is sharper and "
                         + "resolves more harmonics."
        topRow.addArrangedSubview(erbPopup)

        // What the picture is drawn from. Unlike ERB this costs nothing to
        // change -- the engine computes both quantities all the time and this
        // only chooses which one it ships -- so there is no rebuild here.
        modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.target = self
        modePopup.action = #selector(displayModeChanged(_:))
        for m in DisplayMode.allCases { modePopup.addItem(withTitle: m.title) }
        modePopup.toolTip = "Amplitude: each tap's held peak level, the usual "
                          + "picture. Coherence: colour says how much earlier "
                          + "or later than the filterbank's own delay the tap "
                          + "above last peaked -- red earlier, green on time, "
                          + "blue later -- and the level range still sets how "
                          + "solid the colour is, so quiet parts fade out."
        topRow.addArrangedSubview(modePopup)

        topRow.addArrangedSubview(divider())

        // ---- RePlay ------------------------------------------------------
        //
        // A group of two between the display's controls and the file's, with a
        // line on each side: the divider above is the left one, and the button
        // and its volume belong together because neither is any use alone.
        //
        // Hidden rather than disabled when it does not apply. A disabled
        // control is an invitation with a reason to find; this one applies only
        // to a frozen live picture, which is a state the user is already in or
        // not, and a greyed-out slider beside it would say nothing.
        selectionButton = button(replayIdleTitle, #selector(replayPressed(_:)))
        // Pinned at the width of the longer title, so it does not shrink to
        // "Stop" and grow again. A button that changes size when it changes
        // what it says moves everything to the right of it, and the thing you
        // are about to press a second time is not where you just pressed it.
        // Measured rather than written down: the number would be wrong the
        // moment the title, the font or the control size changed.
        selectionButton.widthAnchor.constraint(
            equalToConstant: selectionButton.intrinsicContentSize.width)
            .isActive = true
        selectionButton.toolTip =
            "Play the sound the picture was drawn from. With no measurement "
          + "lines this is the whole width of the display; with one line it "
          + "starts there; with two it plays what is between them."
        topRow.addArrangedSubview(selectionButton)

        selectionSlider = NSSlider(value: Settings().replayGainDB,
                                   minValue: Settings.replayGainRange.lowerBound,
                                   maxValue: Settings.replayGainRange.upperBound,
                                   target: self,
                                   action: #selector(replayGainChanged(_:)))
        selectionSlider.toolTip = "How loud. Unity -- the level the microphone "
                                + "heard -- is towards the right; the far left "
                                + "is silent."
        selectionSlider.widthAnchor.constraint(equalToConstant: 110)
            .isActive = true
        topRow.addArrangedSubview(selectionSlider)

        // Held, because it is hidden and shown with the pair it closes.
        selectionDivider = divider()
        topRow.addArrangedSubview(selectionDivider)

        // Nothing is frozen at launch, and nothing has been recorded. Set here
        // as well as in `showReplayControls` because the window is on screen
        // before the first frame tick.
        selectionButton.isHidden = true
        selectionSlider.isHidden = true
        selectionDivider.isHidden = true

        // No "Live Input" button. The device menu in Settings starts live
        // input on whatever you choose, and two controls doing the same job
        // is how they came to disagree: the button ignored the menu and
        // reopened the *system default*, leaving the menu showing a device
        // that was not the one being captured.
        let playButton = button("Play File", #selector(openFile(_:)))

        // The file's name, beside the button that opened it. Truncated in the
        // middle rather than at the tail: the extension and the end of the
        // name distinguish takes from each other, and are what gets lost when
        // a long path is cut from the right.
        // Taken from the button rather than written as a number, so the two
        // cannot drift apart if the control size ever changes.
        fileNameLabel.font = playButton.font
        fileNameLabel.textColor = .labelColor
        fileNameLabel.usesSingleLineMode = true
        (fileNameLabel.cell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.setContentCompressionResistancePriority(.init(1),
                                                              for: .horizontal)
        fileNameLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        // A ceiling as well as a floor. Without it a long name would take
        // whatever the spacer would otherwise have given up, and push the
        // rest of the row about as it changed.
        fileNameLabel.widthAnchor.constraint(
            lessThanOrEqualToConstant: 220).isActive = true
        fileNameLabel.isHidden = true


        // Replay. Beside Play File, not at the end of the row -- see the note
        // below on the order; this comment described where it used to be.
        replayButton = button("", #selector(replayFile(_:)))
        if let symbol = NSImage(systemSymbolName: "arrow.clockwise",
                                accessibilityDescription: "Replay") {
            replayButton.image = symbol
            replayButton.imagePosition = .imageOnly
        } else {
            replayButton.title = "↻"        // if the symbol is ever missing
        }
        replayButton.toolTip = "Play the same file again"
        replayButton.isHidden = true

        // Play file, then Replay, then the name -- the same order as the
        // browser version, and the order the three things happen in. Replay
        // used to sit at the far right with the spacer between, which put the
        // button furthest from the button it repeats.
        //
        // The spacer goes last, so the group stays left and the slack is at
        // the end of the row rather than inside it.
        for v in [playButton, replayButton, fileNameLabel, spacer()] as [NSView] {
            topRow.addArrangedSubview(v)
        }

        // ---- lower row -------------------------------------------------

        invertBox = NSButton(checkboxWithTitle: "Invert",
                             target: self, action: #selector(toggleInvert(_:)))
        autoBox = NSButton(checkboxWithTitle: "Auto gain",
                           target: self, action: #selector(toggleAuto(_:)))
        autoBox.toolTip = "Move Sensitivity automatically, aiming to keep the "
                        + "average pixel about 30% of the way to full ink. "
                        + "Sensitivity then reports what it is doing rather "
                        + "than accepting instructions; switch this off to "
                        + "take over from wherever it had got to."

        // De-skew sits next to Invert: both are about how the picture is
        // drawn rather than what it is drawn from. It is also the control
        // that greys Close-up out, which is a reason to keep them in one row
        // -- a switch that disables another has to be within sight of it, or
        // the other simply appears to have stopped working.
        deskewBox = NSButton(checkboxWithTitle: "De-skew",
                             target: self, action: #selector(toggleDeskew(_:)))
        deskewBox.toolTip = "Compensate the travelling-wave delay so a click "
                          + "stands vertical. Costs about 186 ms of display "
                          + "latency, and more at sharper tunings. Close-up is "
                          + "unavailable while this is on."
        // The menu sets how much time; the line sets how much room it gets.
        // Magnification is the quotient, and the constraints on it live in
        // `Settings.closeUpFit` -- the view asks, it does not decide.
        view.snapCloseUpWidth = { [weak self] asked in
            guard let self else { return asked }
            return Settings.closeUpFit(spanMS: self.settings.closeUpSpanMS,
                                       columnMS: self.columnMS,
                                       maxColumns: self.view.maxCloseUpColumns,
                                       desiredColumns: asked)?.columns ?? asked
        }
        view.onCloseUpWidthChanged = { [weak self] columns in
            guard let self else { return }
            self.settings.closeUpColumns = columns
            self.applyCloseUp()          // the divisor changes with the width
            self.save()
        }
        // A click on the picture chooses what to play, so it cannot also be
        // ignored while something is playing.
        view.onSelectionDisturbed = { [weak self] in self?.stopReplay() }

        closeUpPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        closeUpPopup.target = self
        closeUpPopup.action = #selector(closeUpSpanChanged(_:))
        // Just the durations. Naming the feature in every entry says the same
        // word five times and still does not explain it; the tooltip does, and
        // one try does better than either.
        for span in Settings.closeUpSpans {
            closeUpPopup.addItem(withTitle: span == 0 ? "<none>" : "\(Int(span)) ms")
        }
        closeUpPopup.toolTip = "Show the most recent stretch of audio at full "
                             + "resolution in a strip down the right-hand "
                             + "side, about 0.4 ms per column whichever span "
                             + "you pick -- so the span sets how wide the "
                             + "strip is. Drag the black line for anything in "
                             + "between. Columns leaving the strip join the "
                             + "main picture at the Speed setting. Needs "
                             + "De-skew off: de-skew delays the whole display "
                             + "by the apex's travel time, so there is nothing "
                             + "recent left to show."
        // Two plain sliders, where there used to be one with two knobs.
        //
        // The knobs were the two ends of the mapping, which reads directly --
        // but two ends of one scale collide, and the code keeping them apart
        // failed silently at the limits. These do not interact: one says where
        // the middle of the window is, the other how wide it is. See the note
        // on `Settings.sensDB`.
        //
        // No numeric readout, on either. They are set to taste, by looking at
        // the picture; a number would only be something else to read.
        sensSlider = NSSlider(value: Settings().sensDB,
                              minValue: Settings.sensitivityRange.lowerBound,
                              maxValue: Settings.sensitivityRange.upperBound,
                              target: self, action: #selector(sensChanged(_:)))
        sensSlider.toolTip = "How faint a sound the display can show. Further "
                           + "right is more sensitive, so more ink and a "
                           + "darker picture. Driven by Auto gain while that "
                           + "is on."
        sensSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        rangeSlider = NSSlider(value: Settings().rangeDB,
                               minValue: Settings.rangeRange.lowerBound,
                               maxValue: Settings.rangeRange.upperBound,
                               target: self, action: #selector(rangeChanged(_:)))
        rangeSlider.toolTip = "How many decibels lie between white and black. "
                            + "Narrow is high contrast; wide shows more of the "
                            + "signal at once. Always yours to set, whether or "
                            + "not Auto gain is on."
        rangeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        // The browser version has had this since stored settings started
        // outliving changes to what the defaults are, which is the whole
        // reason it exists: without it the only way to see a new default is to
        // know where the settings are kept and delete them.
        //
        // Not "Reset Settings..." in the Settings panel. That one is a bigger
        // thing -- it forgets the window, the output device and the
        // diagnostics too, and asks first. This restores only what is drawn on
        // the screen, so it is safe to press while comparing two machines,
        // which is what it is for.
        defaultsButton = button("Defaults", #selector(restoreDisplayDefaults(_:)))
        defaultsButton.toolTip = "Put the display controls back to their "
                               + "starting values. Leaves the window, the "
                               + "output device and the diagnostics alone."

        // Horizontal scale. Detents rather than a slider: the useful settings
        // are a handful of ratios apart, and a slider makes you hunt for them
        // and lands you between them. Radio buttons in a shared superview
        // group themselves, so only the selection needs managing.
        //
        // "Speed", not "Time": the detents run widest-column first, so the
        // scroll gets faster to the right, which the label has to agree with.
        // Unlike ERB this one keeps its label -- the dials carry no text at
        // all, so without it the row would end in fifteen anonymous circles.
        let speedLabel = NSTextField(labelWithString: "Speed")
        let times = NSStackView()
        times.orientation = .horizontal
        times.spacing = 0                   // as tight as AppKit will draw them
        timeButtons = Settings.columnSteps.map { ms in
            // Built by hand rather than through
            // `NSButton(radioButtonWithTitle:target:action:)`: that is a
            // factory method, and whether it allocates the class it is sent
            // to or `NSButton` flat is an implementation detail nobody
            // promises. This is the recipe it replaced, and it cannot return
            // the wrong class.
            let b = LiveTipButton(frame: .zero)
            b.setButtonType(.radio)
            b.bezelStyle = .regularSquare
            b.title = ""
            b.target = self
            b.action = #selector(timeStepChosen(_:))
            // Title-less, so the dial is all that takes width. The value is
            // in the tooltip.
            b.imagePosition = .imageOnly
            b.tip = { [weak self] in self?.speedTip(ms) ?? "" }
            return b
        }
        // Added in reverse, so the widest column is at the left and the
        // display gets finer to the right. `timeButtons` stays indexed by
        // detent, so only the order they are hung in changes -- and `[` and
        // `]` then move the selection the way the brackets point.
        for b in timeButtons.reversed() { times.addArrangedSubview(b) }

        // ---- and now the order ------------------------------------------
        //
        // In one place, because that is the only way it can be read. Grouped
        // by what a control is *about*, with a line between the groups:
        //
        //   how the picture is drawn | what part of the sound it shows |
        //   the exposure pair | the width of the grey scale
        //
        // Auto gain sits with Sensitivity because it is Sensitivity, moved by
        // something other than your hand. Range stands alone: it is the one
        // exposure control Auto gain does not touch.
        // Annotated rather than cast: the stored controls are implicitly
        // unwrapped optionals, and an array literal mixing those with fresh
        // `divider()` values gives the compiler no single element type to
        // settle on unless it is told one.
        let ordered: [NSView] = [invertBox, deskewBox, divider(),
                                 speedLabel, times, closeUpPopup, divider(),
                                 sensSlider, autoBox, divider(),
                                 rangeSlider, divider(), defaultsButton]
        for v in ordered { bottomRow.addArrangedSubview(v) }

        // Built here rather than in the row above, because Settings owns it
        // now and the panel is created lazily.
        devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged(_:))

        outputPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        outputPopup.target = self
        outputPopup.action = #selector(outputDeviceChanged(_:))
        outputPopup.toolTip = "Where a played file is heard. \"System default\" "
                            + "follows Sound settings, which is what most "
                            + "people want; choose a device explicitly if your "
                            + "speakers are not the default -- an external DAC "
                            + "or an aggregate device, say."
        channelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        channelPopup.target = self
        channelPopup.action = #selector(outputChannelChanged(_:))
        channelPopup.toolTip = "Which of that device's channels to play to. "
                             + "Only meaningful on a device with more than "
                             + "two -- an aggregate of a DAC and a monitor "
                             + "presents four, and a stereo file goes to the "
                             + "first pair, which may not be the pair you are "
                             + "listening to. \"All\" plays to every one of "
                             + "them."

        refreshDeviceList()
        refreshOutputList()

        showSettingsInControls()
        showTransport()

        // The two rows end at the same place.
        //
        // This has now been wrong twice by naming a particular control instead
        // of the thing meant. It named `times` when Speed happened to be last
        // in the lower row, and stopped meaning anything when four controls
        // were added after it; then it named Replay, which has since moved to
        // sit beside Play file. The rows themselves are what has to line up,
        // and neither of them is going anywhere.
        //
        // Nothing here is tied to the window's edge: each row is as wide as it
        // needs to be, and the top row's trailing spacer takes up the slack.
        topRow.trailingAnchor.constraint(
            equalTo: bottomRow.trailingAnchor).isActive = true

        // And nothing in the toolbar may widen the window.
        for row in [topRow, bottomRow, bar] {
            row.setClippingResistancePriority(.init(1), for: .horizontal)
            row.setHuggingPriority(.init(1), for: .horizontal)
        }

        let root = NSView()
        root.addSubview(bar)
        root.addSubview(view)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // Pin the minimum so no control can grow the window out from under
        // the bitmap.
        // The widest row is the lower one, at roughly 620 points. Splitting
        // the controls in two is what makes this number smaller than 700.
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.title = "Cochleagram"
        window.contentView = root
        // The spectrum window is a child of this one, and it has to be detached
        // *before* AppKit decides whether the last window has closed --
        // `applicationWillTerminate` runs after that decision, which is too
        // late. A notification rather than becoming the window's delegate:
        // nothing else here wants to be one, and a delegate is a bigger thing
        // to own than a single observation.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window,
            queue: .main) { [weak self] _ in self?.tearDownSpectrum() }
        // Size and position are AppKit's own business once the frame has a
        // name: it saves on every move and resize. `contentMinSize` is set
        // above so an undersized saved frame is clamped on the way in, and
        // AppKit keeps an off-screen one reachable by itself.
        //
        // Restore *before* naming the frame. Naming it can write the current
        // frame straight out, and then the restore would read back the 1100 x
        // 700 default it had just saved, report success, and rob a first
        // launch of its centring.
        if !window.setFrameUsingName(Settings.windowAutosaveName) {
            window.center()
        }
        if !window.setFrameAutosaveName(Settings.windowAutosaveName) {
            Log.say("WINDOW frame autosave name refused; "
                    + "size and position will not persist")
        }
        // macOS's own Resume machinery would otherwise stash geometry in
        // ~/Library/Saved Application State as well, from where Reset Settings
        // cannot clear it -- and a reset window would come back the old size
        // on the next launch. One owner of the geometry, not two.
        window.isRestorable = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A vertical rule, for separating groups within a row.
    ///
    /// Drawn rather than an `NSBox` separator, whose colour is about as faint
    /// as AppKit gets -- fine between rows of a list, too weak to group items
    /// in a busy toolbar.
    private final class Divider: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setFill()
            bounds.fill()
        }
    }

    private func divider() -> NSView {
        let v = Divider()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    /// Absorbs whatever width is left over, so what follows it is pushed to
    /// the right-hand end of the row.
    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        return b
    }

    /// One cycle of a sine, as a template image.
    ///
    /// Drawn rather than fetched from SF Symbols, so it cannot come back nil on
    /// a system that does not have the name -- every other icon here carries a
    /// fallback for that reason, and a shape this simple is cheaper to draw
    /// than to guard. A template image is alpha only: AppKit tints it for the
    /// button's state, which is what makes the on/off state legible.
    private static func sineIcon() -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let steps = 48
            let amp = (rect.height - 4) / 2
            let mid = rect.midY
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let x = rect.minX + 1.5 + t * (rect.width - 3)
                let y = mid + amp * sin(t * 2 * .pi)
                if i == 0 {
                    path.move(to: NSPoint(x: x, y: y))
                } else {
                    path.line(to: NSPoint(x: x, y: y))
                }
            }
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A spectrum: bars of differing height on paper, in a rounded panel.
    ///
    /// Not a template image, and deliberately. A template is alpha only, so it
    /// would come out as a solid tinted blob -- and what makes this read as a
    /// spectrum is ink *against paper*, which is the same black-on-white the
    /// picture itself uses. It therefore does not follow the system appearance:
    /// it is a tiny display, and the display is paper whichever way the rest of
    /// the window is set.
    ///
    /// Drawn rather than an asset, like the sine beside it: no file to add to
    /// the project, nothing to come back nil, and it is right at any size.
    /// The paper the bars sit on: white while the readout is off, blue while it
    /// is on. The button is borderless, so this *is* the pressed state -- there
    /// is no bezel left to show it.
    ///
    /// Fixed colours rather than `NSColor.systemBlue` or the accent colour: an
    /// `NSImage` drawing handler is called once and cached, so a dynamic colour
    /// here would freeze at whatever appearance happened to be current when the
    /// button was first drawn, which is worse than not adapting at all.
    private static let iconPaperOff = NSColor.white
    private static let iconPaperOn = NSColor(srgbRed: 0.0, green: 0.48,
                                             blue: 1.0, alpha: 1)

    /// `paper` nil draws the bars alone, with nothing behind them, and marks
    /// the result a template -- so the off state is just the spectrum, tinted
    /// by AppKit for whichever appearance is in force. With paper it is a
    /// coloured panel and not a template, because a template is alpha only and
    /// would flatten the bars into the panel.
    ///
    /// No outline either way. It was there to keep white paper from vanishing
    /// into a light toolbar; with the off state carrying no paper at all there
    /// is nothing to lose an edge against.
    private static func spectrumIcon(paper: NSColor?) -> NSImage {
        let size = NSSize(width: 28, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            if let paper {
                paper.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }

            // A plausible spectrum rather than a measured one: a few strong
            // partials, an envelope falling towards the top of the range.
            let heights: [CGFloat] = [0.50, 1.00, 0.62, 0.85, 0.42, 0.55, 0.28]
            let inner = rect.insetBy(dx: 3, dy: 3)
            let gapRatio: CGFloat = 0.6
            let n = CGFloat(heights.count)
            let barW = inner.width / (n + (n - 1) * gapRatio)
            NSColor.black.setFill()
            for (i, h) in heights.enumerated() {
                let x = inner.minX + CGFloat(i) * barW * (1 + gapRatio)
                NSBezierPath(rect: NSRect(x: x, y: inner.minY, width: barW,
                                          height: inner.height * h)).fill()
            }
            return true
        }
        image.isTemplate = (paper == nil)
        return image
    }

    /// Make an icon fill its button.
    ///
    /// Borderless, so the drawn panel is the whole visible control rather than
    /// a small picture inside AppKit's bezel -- the panel already has its own
    /// rounded edge and outline, so a second one around it was two borders and
    /// a lot of grey. `.toggle` is the button type that swaps to
    /// `alternateImage` and stays there until pressed again, which is what
    /// carries the on state now that there is no bezel to shade.
    private func makeIconToggle(_ b: NSButton, off: NSImage, on: NSImage,
                                _ sel: Selector) {
        b.isBordered = false
        b.setButtonType(.toggle)
        b.image = off
        b.alternateImage = on
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyUpOrDown
        b.target = self
        b.action = sel
        // No size constraint here. A borderless button's intrinsic size is its
        // image, which came out visibly smaller than the bezelled buttons
        // beside it; the caller matches it to one of those instead, so the row
        // stays even whatever AppKit's bezel metrics turn out to be.
    }

    @objc private func toggleSpectrum(_ sender: NSButton) {
        settings.showSpectrum = sender.state == .on
        updateSpectrum()
        save()
    }

    @objc private func toggleWaveform(_ sender: NSButton) {
        setWaveform(sender.state == .on, growingWindow: true)
        save()
    }

    /// Show or hide the waveform strip.
    ///
    /// `growingWindow` is the whole subtlety. The strip takes a sixth of the
    /// space it shares with the picture, so switching it on would otherwise
    /// shorten the picture -- and the picture's height is the frequency scale,
    /// which is not a thing to shrink because a readout was added. So a *user*
    /// switching it on makes the window taller by exactly the strip's height,
    /// and the picture comes out where it was.
    ///
    /// Applying the stored setting at launch must not do that. The window's
    /// frame is autosaved, so the saved height already includes the strip; the
    /// two are consistent as long as the growing happens only when someone asks
    /// for it. Every path that changes this from a person's action passes true,
    /// and the one that restores what was already agreed passes false.
    private func setWaveform(_ on: Bool, growingWindow: Bool) {
        let was = view.showsWaveform
        let changing = growingWindow && on != was
        // Measured *before* the change, so it is the height the picture has
        // now and therefore the height it should still have afterwards.
        //
        // The same expression serves both directions, which is not a
        // coincidence: turning on, the strip to be added is a fifth of the
        // picture; turning off, the strip to be removed is a sixth of what the
        // two currently share, and a sixth of six parts is a fifth of five.
        let share = CochleagramView.waveformShare
        let delta = (view.plotFrame.height * share / (1 - share)).rounded()

        settings.showWaveform = on
        view.showsWaveform = on
        waveformButton?.state = on ? .on : .off
        guard changing, let w = window else { return }

        var f = w.frame
        // The top edge stays put and the bottom moves, so the toolbar and the
        // picture stay where the eye left them.
        let d = on ? delta : -delta
        f.origin.y -= d
        f.size.height += d
        // Except when there is no room below. `constrainFrameRect` only keeps
        // the title bar on screen, so a window already sitting on the bottom
        // edge would have its status strip pushed off it -- and the frame is
        // autosaved, so it would stay pushed off. Whatever will not fit
        // downward is taken off the top instead; if it will not fit either way
        // the window simply ends up as tall as the screen and the picture is
        // shorter than it was, which is the honest outcome.
        if let vis = w.screen?.visibleFrame {
            if f.minY < vis.minY { f.origin.y = vis.minY }
            if f.maxY > vis.maxY {
                f.size.height -= f.maxY - vis.maxY
            }
        }
        w.setFrame(f, display: true, animate: false)
    }

    // MARK: - the spectrum window
    //
    // The trace is drawn beyond the right-hand edge of the main window, in a
    // transparent borderless window of its own, so that it has a background
    // that is not the picture. Two inks were tried over the picture and neither
    // read against it.
    //
    // A child window, so it travels with the parent: `addChildWindow` makes
    // AppKit move it when the main window moves, order it with it, and take it
    // away when the main window is minimised or closed. What that does *not* do
    // is resize it, so the frame is recomputed on every frame tick -- cheap,
    // and it means nothing has to listen for a resize, a toolbar reflow or a
    // change of screen.
    //
    // Known costs, all accepted: it is clipped by the edge of the screen, so
    // with the window hard right there is nowhere for it to go; it goes behind
    // with the rest of the app when another app comes forward; and the backdrop
    // is whatever happens to be there.

    private var spectrumWindow: NSWindow?
    private var spectrumView: SpectrumView?

    /// How far the black point sits from the zero line, as a fraction of the
    /// plot's width -- so the scale matches what it was when the trace was
    /// drawn over the picture.
    private let spectrumBlackFraction: CGFloat = 0.25
    /// And how much window there is beyond that. Levels past the black point
    /// are not clipped by the arithmetic, so they need somewhere to go; past
    /// this they are clipped by the window, which cannot be helped.
    private let spectrumHeadroom: CGFloat = 2.0

    private func makeSpectrumWindow() -> NSWindow {
        let v = SpectrumView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let w = NSWindow(contentRect: v.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.contentView = v
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // Clicks belong to whatever is underneath. This window is a readout,
        // not a control, and a transparent rectangle that swallowed clicks
        // over another app would be indefensible.
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        // Nothing here makes it refuse key or main -- being borderless already
        // does, since `canBecomeKey` is false for such a window by default.
        // This only says it should not vanish when another app comes forward,
        // which is the default for a plain window and is stated because the
        // obvious alternative, an NSPanel, does the opposite.
        w.hidesOnDeactivate = false
        spectrumView = v
        return w
    }

    /// Show, hide, position and fill the spectrum window. Called every frame.
    private func updateSpectrum() {
        guard let main = window else { return }
        guard settings.showSpectrum else {
            // Guarded, because this runs sixty times a second for as long as
            // the trace is switched off. Detaching an already-detached window
            // and hiding an already-hidden one is cheap, but not free, and not
            // something to do at frame rate for no reason.
            if let w = spectrumWindow, w.parent != nil || w.isVisible {
                main.removeChildWindow(w)
                w.orderOut(nil)
            }
            return
        }

        let w = spectrumWindow ?? makeSpectrumWindow()
        if spectrumWindow == nil { spectrumWindow = w }

        // The plot's rectangle, in screen coordinates. Its right edge is the
        // view's right edge and so the window's, which is where the trace
        // starts; its top and bottom are the ends of the frequency scale, which
        // the trace has to line up with exactly.
        let plot = view.plotFrame
        let inWindow = view.convert(plot, to: nil)
        let onScreen = main.convertToScreen(inWindow)
        let reach = max(1, onScreen.width * spectrumBlackFraction)
        let frame = NSRect(x: onScreen.maxX, y: onScreen.minY,
                           width: reach * spectrumHeadroom,
                           height: max(1, onScreen.height))
        if w.frame != frame { w.setFrame(frame, display: false) }

        spectrumView?.blackReach = reach
        spectrumView?.update(view.spectrumTrace() ?? [])

        if w.parent == nil {
            // Ordered above the parent, which is what keeps it visible over
            // whatever the parent is sitting on.
            main.addChildWindow(w, ordered: .above)
        }
    }

    /// Add a device to a menu *without* `NSPopUpButton.addItem(withTitle:)`,
    /// which is documented to remove any existing item of the same title. Two
    /// identical interfaces, or two instances of the same DAC, would collapse
    /// into one entry -- and since both menus map position to index in the
    /// device array, every entry after the collision would then name the wrong
    /// device.
    private func addDevice(_ d: AudioDevice, to popup: NSPopUpButton) {
        popup.menu?.addItem(withTitle: d.name + (d.isDefault ? " ✓" : ""),
                            action: nil, keyEquivalent: "")
    }

    private func refreshDeviceList() {
        devices = AudioDevices.inputs()
        devicePopup.removeAllItems()
        for d in devices { addDevice(d, to: devicePopup) }
        if let i = devices.firstIndex(where: { $0.isDefault }) {
            devicePopup.selectItem(at: i)
        }
        deviceSummary.stringValue =
            devices.first { $0.id == audio.currentDeviceID }?.summary ?? ""
    }

    /// The output list, with the system default as the first entry rather than
    /// a device in its own right. Following Sound settings is what the app did
    /// before this menu existed and what nearly everyone wants; naming a device
    /// is the exception, and it should look like one.
    private func refreshOutputList() {
        outputDevices = AudioDevices.outputs()
        outputPopup.removeAllItems()
        outputPopup.menu?.addItem(withTitle: "System default",
                                  action: nil, keyEquivalent: "")
        for d in outputDevices { addDevice(d, to: outputPopup) }
        let uid = settings.outputDeviceUID
        if !uid.isEmpty,
           let i = outputDevices.firstIndex(where: { $0.uid == uid }) {
            outputPopup.selectItem(at: i + 1)
        } else {
            // Either nothing was chosen, or what was chosen is unplugged. Both
            // mean the default, and the menu should say so rather than point at
            // a device that is not there.
            outputPopup.selectItem(at: 0)
        }
        refreshChannelList()
    }

    /// The device actually in use for playback: the chosen one, or -- when
    /// "System default" is selected -- whichever device that currently is.
    /// The channel menu has to be built from the real thing either way, since
    /// the number of channels is a property of the device and not of the
    /// choice.
    private var effectiveOutputDevice: AudioDevice? {
        if !settings.outputDeviceUID.isEmpty,
           let d = outputDevices.first(where: { $0.uid == settings.outputDeviceUID }) {
            return d
        }
        if let id = AudioDevices.defaultOutputID {
            return outputDevices.first { $0.id == id }
        }
        return outputDevices.first { $0.isDefault }
    }

    /// One entry per stereo pair the device has, plus "All".
    ///
    /// Greyed out on an ordinary two-channel device, where every entry would
    /// mean the same thing. Leaving it visible but disabled says "there is
    /// nothing to choose here" -- hiding it would make the row jump about as
    /// the device menu changed, and would hide the control from the one person
    /// who needs it if their device were momentarily unplugged.
    private func refreshChannelList() {
        let n = effectiveOutputDevice?.channels ?? 2
        let pairs = max(1, (n + 1) / 2)
        channelPopup.removeAllItems()
        channelPopup.addItem(withTitle: "All channels")
        for p in 1...pairs {
            let a = (p - 1) * 2 + 1
            let b = a + 1
            channelPopup.addItem(withTitle: b <= n ? "\(a)-\(b)" : "\(a)")
        }
        if settings.outputChannelPair > pairs {
            // The stored pair does not exist on this device -- it was chosen
            // for another one, or the default has changed since. Fall back to
            // all channels, and push it, or the menu would say one thing while
            // playback did another.
            settings.outputChannelPair = 0
            audio.outputChannelPair = 0
            save()
        }
        channelPopup.selectItem(at: settings.outputChannelPair)
        channelPopup.isEnabled = n > 2
    }

    @objc private func outputChannelChanged(_ sender: NSPopUpButton) {
        settings.outputChannelPair = max(0, sender.indexOfSelectedItem)
        audio.outputChannelPair = settings.outputChannelPair
        save()
        if audio.isFilePlayback {
            report("Output channels set. They take effect the next time you "
                   + "play a file.")
        }
    }

    @objc private func outputDeviceChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        settings.outputDeviceUID = (i > 0 && i - 1 < outputDevices.count)
            ? outputDevices[i - 1].uid : ""
        audio.outputDeviceUID = settings.outputDeviceUID
        refreshChannelList()
        audio.outputChannelPair = settings.outputChannelPair
        save()
        // Takes effect on the next Play: the device cannot be changed on a
        // running audio unit, and stopping playback to honour a menu the user
        // may have opened by accident is worse than waiting.
        if audio.isFilePlayback {
            report("Output device set. It takes effect the next time you "
                   + "play a file.", isProblem: false)
        }
    }

    @objc private func deviceChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < devices.count else { return }
        let d = devices[i]
        // A popup fires its action even when the selection did not change.
        // Restarting the unit for that is at best a glitch in the display and
        // at worst leaves it stopped -- but only if that device is what we are
        // already capturing. During file playback `currentDeviceID` is nil, so
        // choosing the same device again is how you get back to live input.
        guard d.id != audio.currentDeviceID else {
            Log.say("DEVICE unchanged (\(d.name)); leaving the unit alone")
            return
        }
        startLiveInput(deviceID: d.id)
    }

    // MARK: - coefficients

    /// `join` says what the picture should show where the old engine ends
    /// and the new one begins. Passed down rather than held as state: an
    /// instance variable survived failed rebuilds -- a denied microphone, a
    /// missing file -- and was then spent on the *next*, unrelated rebuild,
    /// drawing a violet tuning line where a red seam belonged.
    /// Where a coefficient file might be, in the order worth trying.
    ///
    /// Three layouts, because this project has two build paths and SwiftPM
    /// has a third idea of its own:
    ///
    ///   * the Xcode target copies the `.coch` files loose into
    ///     `Contents/Resources`;
    ///   * `make_app.sh` copies SwiftPM's side bundle to
    ///     `Contents/Resources/Cochleagram_CochleagramApp.bundle`;
    ///   * a bare SwiftPM executable has that side bundle beside the binary.
    ///
    /// `Bundle.module` is deliberately not used, and this is the reason.
    /// It is generated code that calls `fatalError` when it cannot find its
    /// bundle, and the only two places it looks are the *top level* of the
    /// .app -- which is not where `make_app.sh` puts it -- and an absolute
    /// path inside the developer's own `.build` directory, which exists on
    /// exactly one machine on earth. So it worked here and killed the app on
    /// first use everywhere else. Versions 0.2 and 0.3 both shipped that way.
    ///
    /// Returning nil is the point: a missing file is then a message in the
    /// Settings window rather than a crash report.
    private func coefficientURL(named name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "coch") {
            return u
        }
        let side = "Cochleagram_CochleagramApp.bundle"
        let bases = [Bundle.main.resourceURL,
                     Bundle.main.bundleURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
        for case let base? in bases {
            let b = base.appendingPathComponent(side)
            if let u = Bundle(url: b)?.url(forResource: name,
                                           withExtension: "coch") {
                return u
            }
            // Some layouts leave the files loose inside the side bundle
            // rather than under its own Resources directory.
            let flat = b.appendingPathComponent("\(name).coch")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }

    private func makeCochlea(inputRate: Double,
                             join: CochleagramView.MarkKind) -> Cochlea? {
        // One baked file per tuning: the bandwidth fit is twenty iterations
        // of pole-walking, which is a design step, not something to do while
        // somebody waits.
        let name = Settings.coefficientName(settings.erbScale)
        guard let url = coefficientURL(named: name) else {
            report("\(name).coch is missing from the application bundle.",
                   isProblem: true)
            return nil
        }
        // The one we are holding, if it is already the one being asked for.
        //
        // Building costs about half a second on the main thread -- two
        // calibration sweeps over all 599 taps -- and Replay paid it every
        // time, which is most of the gap between the Mac taking most of a
        // second to start a file and the browser taking a fifth of one. The
        // browser never rebuilds for a replay; it keeps the engine it opened
        // and simply plays the buffer again.
        //
        // The engine keeps its filter state across the reuse, exactly as the
        // browser's does. That is not a compromise for speed: a file's first
        // moments are genuinely preceded by whatever came before, and the seam
        // `adopt` marks below is what says so.
        let c: Cochlea
        if let existing = cochlea, existing.coefficientURL == url,
           existing.inputRate == inputRate {
            c = existing
            Log.say("COCHLEA reused (\(name), input \(Int(inputRate)) Hz)")
        } else {
            guard let built = Cochlea(coefficientURL: url, inputRate: inputRate)
            else {
                report("Could not load \(url.lastPathComponent).",
                       isProblem: true)
                return nil
            }
            c = built
        }
        cochlea = c
        view.adopt(c, join: join)
        applyToEngine()
        Log.say("COCHLEA \(c.tapCount) taps, "
                + "\(String(format: "%.1f", c.frequencies.last ?? 0))-"
                + "\(String(format: "%.0f", c.frequencies.first ?? 0)) Hz, "
                + "input \(Int(inputRate)) Hz, internal \(Int(c.internalRate)) Hz, "
                + "\(columnMS) ms/column, \(settings.erbScale) x ERB, "
                + "dmax \(String(format: "%.2f", c.maxDelayMS)) ms")
        return c
    }

    // MARK: - actions

    /// The only route to live input: used at launch with `nil`, meaning the
    /// system default, and by the device menu with a specific device.
    ///
    /// The permission check lives here rather than at one call site, which is
    /// the bug that came with having two ways in -- the button asked and the
    /// menu did not, so switching device before the grant existed gave you a
    /// running unit delivering silence and nothing on screen to say why.
    private func startLiveInput(deviceID: AudioDeviceID?,
                                join: CochleagramView.MarkKind = .seam) {
        requestMicrophoneIfNeeded { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.report("Microphone access denied.", isProblem: true)
                self.offerMicrophoneSettings()
                return
            }
            do {
                try self.audio.startInput(deviceID: deviceID) {
                    self.makeCochlea(inputRate: $0, join: join)
                }
                self.paused = false
                // Whatever brought us here -- the menu, or space after a file
                // ran out -- there is no finished file any more, so space goes
                // back to meaning pause.
                self.fileFinished = false
                // With it, everything that was waiting on the finished file.
                // `startInput` has already stopped that graph, so there is
                // nothing left to mark or to tear down, and a deadline left
                // armed across the change would be waiting on a tap that no
                // longer exists.
                self.fileEndMarked = false
                self.fileTornDown = false
                self.fileEndDeadline = nil
                self.view.isPaused = false
                // Live input is the only source RePlay offers, so this is
                // where keeping the audio starts. The recorder itself is
                // reset by `syncRecorder`, which notices that a new engine
                // has restarted the picture's numbering.
                self.stopReplay()
                self.recorder.reset(rate: self.cochlea?.inputRate ?? 0)
                self.recordedPerColumn = 0
                // A new engine counts its own drops from zero. Re-seeded here
                // as well as in `syncRecorder`, because the picture is kept
                // when the tap count is unchanged and neither the epoch nor the
                // rate need have moved -- an ERB change is exactly that.
                self.seenDroppedColumns = self.cochlea?.droppedColumns ?? 0
                self.seenDroppedInput = self.cochlea?.droppedInput ?? 0
                // And the input unit's own counter, for the same reason: a
                // new unit starts at zero, and whatever the last one lost is
                // not news about this one. Any hole still waiting for the
                // cascade belonged to the source that has just been replaced.
                self.seenDroppedInputFrames = self.audio.droppedInputFrames
                self.seenInputDropouts = self.audio.inputDropouts
                self.forgetDropouts()
                self.cochlea?.capturing = true
                self.showCurrentDevice()
                // The file is gone, but it is still what Replay would play,
                // so the name and the button stay as they were.
                self.showTransport()
                let name = self.devices.first {
                    $0.id == self.audio.currentDeviceID
                }?.name ?? "input"
                self.report("\(name) at \(Int(self.audio.sampleRate)) Hz")
            } catch {
                Log.say("LIVE INPUT failed: \(error.localizedDescription)")
                self.report(error.localizedDescription, isProblem: true)
            }
        }
    }

    /// Point the menu at whatever is actually being captured. At launch that
    /// is the system default, which need not be what the menu happened to
    /// select; leaving the two to disagree is exactly what removing the button
    /// was meant to stop.
    private func showCurrentDevice() {
        guard let id = audio.currentDeviceID,
              let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devicePopup.selectItem(at: i)
        deviceSummary.stringValue = devices[i].summary
    }

    @objc private func openFile(_ sender: Any) {
        // Pause first. The panel's modal loop stops the display either way;
        // doing it on purpose means the gap gets the red seam a pause always
        // leaves, so the picture accounts for it rather than looking stalled.
        let wasPaused = paused
        if !paused { setPaused(true) }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            // Cancelled: put it back the way it was. Pausing was this
            // method's doing, not the user's, so it should not outlive a
            // decision not to open anything. The seam stays -- time really
            // did jump while the panel was up, and that remains true whether
            // or not a file was chosen.
            if !wasPaused { setPaused(false) }
            return
        }
        play(url)
    }

    @objc private func replayFile(_ sender: Any) {
        guard let url = lastFileURL else { return }
        play(url)
    }

    private func play(_ url: URL, join: CochleagramView.MarkKind = .seam) {
        do {
            // Set before starting: a very short file can finish before this
            // line would otherwise be reached.
            audio.onFinish = { [weak self] in self?.fileDidFinish() }
            // RePlay and file playback are either/or. A file is already audible
            // and already on disk, so keeping a second copy of it would be
            // paying for something nobody can ask for.
            stopReplay()
            try audio.startFile(url: url) { makeCochlea(inputRate: $0, join: join) }
            // After the throw, not before: a file that fails to open should
            // cost nothing, and throwing the live recording away on the way to
            // an error message would lose the picture's sound for no reason.
            recorder.reset(rate: 0)
            cochlea?.capturing = false
            lastFileURL = url
            hasPlayedThrough = false
            paused = false
            fileFinished = false
            fileEndMarked = false
            fileTornDown = false
            fileEndDeadline = nil
            view.isPaused = false
            // After the three flags above, not before: the transport controls
            // are drawn from them, and this used to run first -- harmless
            // while it only governed Replay's visibility, wrong the moment
            // the pause glyph joined it. Opening a file while paused would
            // have left the button offering to resume something that was
            // already running.
            showTransport()
            // A file is genuinely paused, so nothing is lost and nothing needs
            // discarding. `fileDidFinish` turns this on to throw away the
            // silence a finished player renders; a new file turns it back off.
            view.discardWhilePaused = false
            report("Playing \(url.lastPathComponent)")
        } catch {
            audio.onFinish = nil
            report(error.localizedDescription, isProblem: true)
        }
    }

    /// The file's last *sample* has reached the cascade, which is when the
    /// picture of it is complete. Earlier than `fileDidFinish`, which waits
    /// for the output to have played that sample -- and the gap between the
    /// two is the 35 ms the green line used to be short by.
    ///
    /// Called from the frame tick rather than from the audio thread, and made
    /// idempotent, because `fileDidFinish` calls it too: a file that is
    /// stopped rather than finished never reaches its own last sample, and the
    /// completion is then the only thing that will say so.
    private func markFileEndOnce() {
        guard !fileEndMarked else { return }
        fileEndMarked = true

        // Draw what the engine has already produced *before* freezing, or the
        // final columns would sit undrawn in the ring and put the green line
        // short of the end.
        view.tick()

        // TEMPORARY DIAGNOSTIC. `fed` is how much of the file has reached the
        // cascade, `drew` is how much picture exists since the join, and the
        // frame is where the file's first non-silent sample landed in what was
        // fed. For `reference/pureimpulse.wav` that frame should now read
        // 4410; it read 5946 while the pre-roll was being drawn.
        let fedMS = audio.sampleRate > 0
            ? Double(audio.meters.samples - audio.samplesAtFileStart)
              / audio.sampleRate * 1000.0
            : 0
        let drewMS = Double(view.columnsSinceJoin) * engineColumnMS
        let firstNZ = audio.firstNonZeroFrame
        let nzFrame = firstNZ >= 0 ? firstNZ - audio.samplesAtFileStart : -1
        let nzMS = nzFrame >= 0 && audio.sampleRate > 0
            ? Double(nzFrame) / audio.sampleRate * 1000.0 : -1
        Log.say(String(format:
            "ENDMARK fed %.1f ms, drew %.1f ms, difference %.1f ms "
            + "(%d columns at %.3f ms); first non-zero sample at frame %d "
            + "= %.1f ms of stream", fedMS, drewMS, fedMS - drewMS,
            view.columnsSinceJoin, engineColumnMS, nzFrame, nzMS))

        view.markFileEnd()

        // Frozen here, with the sound still playing out: every sample of the
        // file has reached the cascade, and the remaining few milliseconds are
        // the output emptying its buffers.
        //
        // "Every sample has reached the cascade" is not quite "the picture is
        // complete", and the difference is De-skew. It holds each tap back by
        // its own travelling-wave delay, up to about 186 ms at the apex, so
        // the newest column's low frequencies are still that far behind the
        // newest sample. The tail of a de-skewed picture is therefore short at
        // the bottom however this is timed -- inherent to de-skew, not to the
        // boundary, but the boundary is 35 ms earlier than the completion it
        // replaced, so it is marginally more so.
        paused = true
        view.discardWhilePaused = true
        view.isPaused = true
        // The button has to say what the state is. This froze the display
        // without telling it, so when this ran against a source it had no
        // business running against the picture stopped while the button went on
        // claiming to be running -- which made the underlying fault look like a
        // button that needed pressing twice.
        showPauseButton()
    }

    /// The file has been *heard* to its end: the output reports it has played
    /// the last sample.
    ///
    /// Which is not the end of the picture, and is the earlier of the two.
    /// Rendering leads playback by the output's own latency, but the tap hands
    /// over a batch only once it is full -- 4410 frames here, 100 ms -- so the
    /// batch holding the file's tail arrives about 65 ms *after* this fires.
    /// Marking and tearing down here threw that batch away with the tap still
    /// holding it, which is why the picture stopped 35 ms short of the sound.
    private func fileDidFinish() {
        fileFinished = true
        hasPlayedThrough = true
        showTransport()
        report("Finished — space returns to live input.")
        // Comfortably more than the one tap batch being waited for, and short
        // enough that a boundary which never comes costs a fifth of a second
        // of the player's silence rather than half of one.
        fileEndDeadline = CACurrentMediaTime() + 0.2
        // The frame tick checks the deadline, and the frame tick is a display
        // link -- which AppKit stops when the window is minimised or fully
        // occluded. A file finishing behind a minimised window would then hold
        // the engine, the player and the output device until it was restored.
        // A timer that does not depend on anything being drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.endFileIfReady()
        }
        endFileIfReady()
    }

    /// Wind the file up, once both timelines agree it is over: the output has
    /// played the last sample, and the tap has delivered it.
    ///
    /// Called every frame, because the second of those arrives on its own
    /// schedule and nothing announces it.
    private func endFileIfReady() {
        guard fileFinished, !fileTornDown else { return }
        if !fileEndMarked {
            // `nil` means "not armed yet", so it must not read as "long since
            // expired". Unreachable today -- the deadline is set two lines
            // before the only call that can get here -- but one reordering
            // away from marking the moment a file ends.
            let timedOut = fileEndDeadline.map { CACurrentMediaTime() > $0 }
                ?? false
            // No boundary is coming for a file whose length was never known,
            // so there is nothing to wait for and the completion is the best
            // authority there is.
            let noBoundaryComing = !audio.knowsFileLength
            guard audio.fileSamplesEnded || timedOut || noBoundaryComing
            else { return }
            if timedOut || noBoundaryComing {
                // A file that was stopped rather than finished never reaches
                // its own last sample. Mark where the audio actually got to
                // and say so, rather than waiting for something that is not
                // coming.
                Log.say("FILE end: no sample boundary "
                        + (noBoundaryComing ? "(length unknown)" : "(timed out)")
                        + "; marking where the audio reached")
            }
            markFileEndOnce()
        }
        fileTornDown = true
        fileEndDeadline = nil
        // `markFileEndOnce` has already frozen the display. Asserted again
        // because the state is cheap and the cost of getting it wrong is a
        // wall of blank columns scrolling the end of the file away.
        paused = true
        view.discardWhilePaused = true
        view.isPaused = true
        audio.finishedPlayingFile()
        Log.say("FILE finished; green line at the end, engine winding down")
    }

    @objc private func toggleDiag(_ sender: NSButton) {
        settings.showReadout = readoutBox.state == .on
        settings.logToConsole = consoleBox.state == .on
        settings.logToLogStream = logStreamBox.state == .on
        applyDiagnostics()
        save()
    }

    /// Push the three switches at the two places that act on them. Called on
    /// launch as well as on change, or the stored values would be written but
    /// never obeyed.
    private func applyDiagnostics() {
        audio.outputDeviceUID = settings.outputDeviceUID
        audio.outputChannelPair = settings.outputChannelPair
        Log.toConsole = settings.logToConsole
        Log.toLogStream = settings.logToLogStream
        view.showDiagnostics = settings.showReadout
        if readoutBox != nil {
            readoutBox.state = settings.showReadout ? .on : .off
            consoleBox.state = settings.logToConsole ? .on : .off
            logStreamBox.state = settings.logToLogStream ? .on : .off
        }
    }

    // MARK: - About

    @objc func showAbout(_ sender: Any?) {
        // The standard panel already puts the name and version at the top, so
        // this is only what it does not know: who, and when. The date comes
        // from the executable's own modification time rather than from a
        // constant somebody has to remember to edit -- it is the build date by
        // construction, and cannot drift from the build it is printed in.
        var built = ""
        if let exe = Bundle.main.executableURL,
           let date = (try? exe.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate {
            let f = DateFormatter()
            f.dateStyle = .long
            f.timeStyle = .none
            built = "\n\n" + f.string(from: date)
        }

        let text = """
            Idea and direction: Stephen Malinowski

            Implementation: Claude (Anthropic).
            """ + built

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let credits = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - the Settings window

    @objc func showSettings(_ sender: Any?) {
        let w = settingsWindow ?? makeSettingsWindow()
        settingsWindow = w
        // The checkboxes are made here, so the `applyDiagnostics` call during
        // launch could not seed them -- they did not exist yet. Without this
        // they open unticked whatever is stored, and ticking one writes the
        // other two off.
        applyDiagnostics()
        refreshDeviceList()
        refreshOutputList()
        showCurrentDevice()
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow() -> NSWindow {
        let label = NSTextField(labelWithString: "Input device")
        deviceSummary.font = .monospacedDigitSystemFont(ofSize: 10,
                                                        weight: .regular)
        deviceSummary.textColor = .secondaryLabelColor
        deviceSummary.usesSingleLineMode = true
        (deviceSummary.cell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [label, devicePopup])
        row.orientation = .horizontal
        row.spacing = 8

        let outLabel = NSTextField(labelWithString: "Play files through")
        outputPopup.widthAnchor.constraint(
            lessThanOrEqualToConstant: 240).isActive = true
        let outRow = NSStackView(views: [outLabel, outputPopup, channelPopup])
        outRow.orientation = .horizontal
        outRow.spacing = 8

        // The status line, which used to sit in the toolbar under a hard
        // width cap so a long message could not widen the window and shove
        // the picture sideways. Here it can simply be as wide as it needs.
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.usesSingleLineMode = false
        status.maximumNumberOfLines = 2
        (status.cell as? NSTextFieldCell)?.lineBreakMode = .byWordWrapping
        status.preferredMaxLayoutWidth = 380
        status.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 380).isActive = true

        // Diagnostics. Three destinations rather than one switch, because
        // they are useful in different situations and none of them should be
        // on for somebody who just wants to look at sound.
        let diagLabel = NSTextField(labelWithString: "Diagnostics")
        readoutBox = NSButton(checkboxWithTitle: "Readout under the picture",
                              target: self, action: #selector(toggleDiag(_:)))
        readoutBox.toolTip = "Bitmap size, columns taken per frame, close-up "
                           + "geometry. Drawn along the bottom of the window."
        consoleBox = NSButton(checkboxWithTitle: "Print to stdout (Xcode console)",
                              target: self, action: #selector(toggleDiag(_:)))
        consoleBox.toolTip = "Where Xcode's console reads from, and where a "
                           + "shell shows it if you run the executable inside "
                           + "the bundle directly."
        logStreamBox = NSButton(checkboxWithTitle: "Write to the system log",
                                target: self, action: #selector(toggleDiag(_:)))
        logStreamBox.toolTip = "For Console.app, or:  log stream --style "
                             + "compact --predicate 'subsystem == "
                             + "\"org.malinowski.cochleagram\"'"

        let diagStack = NSStackView(views: [diagLabel, readoutBox,
                                            consoleBox, logStreamBox])
        diagStack.orientation = .vertical
        diagStack.alignment = .leading
        diagStack.spacing = 4

        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let reset = NSButton(title: "Reset Settings…", target: self,
                             action: #selector(resetSettings(_:)))
        reset.bezelStyle = .rounded

        let stack = NSStackView(views: [row, deviceSummary, outRow, separator,
                                        diagStack, separator2,
                                        status, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Settings"
        // Closing a window releases it by default, and this one is kept in a
        // property and reopened -- which would be a use-after-free.
        w.isReleasedWhenClosed = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        w.contentView = root
        return w
    }

    /// What the transport group shows, in one place.
    ///
    /// Nothing until a file has been chosen; then its name; and Replay only
    /// once that file has run to its end, because until then "again" refers
    /// to nothing. Pressing Replay therefore hides the button until the
    /// replay finishes -- deliberate, if slightly odd the first time you see
    /// it: the button means "I have heard this and want it again", and while
    /// it is playing that is not yet true.
    private func showTransport() {
        if let url = lastFileURL {
            fileNameLabel.stringValue = url.lastPathComponent
            fileNameLabel.toolTip = url.path
            fileNameLabel.isHidden = false
        } else {
            fileNameLabel.stringValue = ""
            fileNameLabel.isHidden = true
        }
        replayButton.isHidden = lastFileURL == nil || !hasPlayedThrough
        showPauseButton()
        // In the same place as the rest of the transport, so there is one
        // answer to "which buttons are on screen" rather than two.
        showReplayControls()
    }

    /// The transport convention: the button shows what pressing it will do,
    /// not what is happening. Running, it offers to pause; paused, it offers
    /// to resume.
    ///
    /// A file that has played to its end is the awkward case. It is stopped
    /// rather than paused, and what the button does there is what space does
    /// -- go back to live input -- so it shows play, which is honest about
    /// the direction if not about the destination. The tip says the rest.
    private func showPauseButton() {
        guard pauseButton != nil else { return }
        let willResume = paused || fileFinished
        let name = willResume ? "play.fill" : "pause.fill"
        let label = willResume ? "Resume" : "Pause"
        if let symbol = NSImage(systemSymbolName: name,
                                accessibilityDescription: label) {
            pauseButton.image = symbol
            pauseButton.title = ""
            pauseButton.imagePosition = .imageOnly
        } else {
            // If the symbol is ever missing. Not the single-character glyphs
            // U+23F8 and U+25B6, which font substitution renders at wildly
            // different sizes.
            pauseButton.image = nil
            pauseButton.title = willResume ? "\u{25B6}" : "\u{2016}"
            pauseButton.imagePosition = .noImage
        }
        pauseButton.toolTip = fileFinished
            ? "Back to live input (space)"
            : (paused ? "Resume (space)" : "Freeze the display (space)")
    }

    @objc private func pauseButtonPressed(_ sender: Any) { togglePause() }

    // MARK: - RePlay

    private var replayIdleTitle: String { "Play Selection" }

    /// On screen only while a live picture is frozen. See the note where the
    /// controls are built for why this is hidden rather than disabled.
    private func showReplayControls() {
        guard selectionButton != nil else { return }
        let live = !audio.isFilePlayback
        let show = live && paused && !recorder.isEmpty
        if !show { stopReplay() }
        selectionButton.isHidden = !show
        selectionSlider.isHidden = !show
        selectionDivider.isHidden = !show
        selectionButton.title = audio.isReplaying ? "Stop" : replayIdleTitle
    }

    @objc private func replayPressed(_ sender: Any) {
        if audio.isReplaying {
            stopReplay()
        } else {
            startReplay()
        }
    }

    @objc private func replayGainChanged(_ sender: NSSlider) {
        settings.replayGainDB = sender.doubleValue.rounded()
        // Live, unlike every other control's effect on a playback in progress.
        // The others change how the picture is drawn; this one is the sound
        // itself, and a volume that only took effect next time would be a
        // volume control nobody could set by ear.
        audio.setReplayGain(settings.replayGainDB)
        save()
    }

    private func startReplay() {
        guard let sel = view.selectionColumns, let c = cochlea else { return }
        // No refusal when the volume is at the bottom of its travel. It plays
        // silently, the line moves, and that is exactly what a volume control
        // at zero should do; refusing instead would be a second, invisible
        // rule about a control whose position already says what it does.
        //
        // `sel.end` is one past the last column, extended by that column's own
        // span, so a one-column selection is a column's worth of sound rather
        // than none. The samples are handed over where they lie and copied once,
        // into the playback buffer.
        let started = recorder.withSamples(from: sel.lo, to: sel.end) { frames in
            (frames.count,
             audio.startReplay(frames, rate: c.inputRate,
                               gainDB: settings.replayGainDB))
        }
        guard let (count, ok) = started else {
            report("That part of the picture is no longer in the recording.",
                   isProblem: true)
            return
        }
        guard ok else {
            report("Could not start playback.", isProblem: true)
            return
        }
        replayFromColumn = sel.lo
        replayToColumn = sel.end - 1
        // Where the sound starts, taken once. The recorder trims as the picture
        // scrolls, and asking again later can find the segment gone -- the
        // audio itself is safe, having been copied into the playback buffer
        // already.
        // Clamped the same way `withSamples` clamps it, so the line and the
        // sound agree about where the playback began. With De-skew on, the
        // start of a selection can point a fifth of a second before anything
        // that was recorded -- the picture is held back by that much, so its
        // leftmost columns were drawn from audio that predates the recording --
        // and the sound then starts at the oldest sample there is.
        replayFromSample = max(recorder.sample(forColumn: sel.lo)
                               ?? recorder.oldestSample,
                               recorder.oldestSample)
        view.playhead = sel.lo
        showReplayControls()
        let ms = Double(count) / c.inputRate * 1000
        report(String(format: "Playing %.0f mS of the picture.", ms))
    }

    /// Stop, not pause. Nothing remembers where the sound had got to, so the
    /// next press starts at the beginning of the selection again -- which is
    /// what the button says it will do.
    private func stopReplay() {
        guard audio.isReplaying || view.playhead != nil else { return }
        audio.stopReplay()
        view.playhead = nil
        showReplayControls()
    }

    /// Keep the recorder's arithmetic in step with the picture's.
    ///
    /// Two things break the correspondence without wiping anything: a change of
    /// Speed, which changes how much audio a column stands for, and a resume,
    /// which starts recording again after an interval that is in neither the
    /// picture nor the recording. Both open a new segment. A wipe is different
    /// in kind -- the numbering itself starts again -- so it starts the whole
    /// recording again.
    private func syncRecorder() {
        guard let c = cochlea else { return }
        // A change of input device keeps the picture when the tap count is
        // unchanged -- which is the ordinary case -- so the epoch alone would
        // not notice it, and everything already recorded is at the old device's
        // rate. Playing that back at the new one would pitch-shift the older
        // half of a selection. The rate is therefore part of what makes a
        // recording the same recording.
        if view.contentEpoch != recordedEpoch || c.inputRate != recorder.rate {
            stopReplay()
            recorder.reset(rate: c.inputRate)
            recordedEpoch = view.contentEpoch
            recordedPerColumn = 0
            // A replaced engine starts its own counters at zero, which would
            // otherwise read as a drop on the next tick.
            seenDroppedColumns = c.droppedColumns
            seenDroppedInput = c.droppedInput
            // The button's visibility depends on the recorder having something
            // in it, and a wipe while paused is reachable -- changing Speed, or
            // closing the close-up. Without this the button would sit there
            // over an empty recorder, doing nothing when pressed.
            showReplayControls()
        }
        let perColumn = c.inputRate * c.columnMilliseconds / 1000
        // How far behind the sound the picture is. De-skew moves this by nearly
        // two hundred milliseconds -- it holds every tap back to the slowest --
        // and it can be switched at any time without wiping what is drawn, so
        // the columns on either side of the seam it leaves stand for audio at
        // two different offsets. Noticed here, like a change of Speed, and for
        // the same reason: a new stretch, with the old terms kept for the
        // columns that were drawn under them.
        let lag = Int64((c.displayLagMS / 1000 * c.inputRate).rounded())
        if perColumn > 0, perColumn != recordedPerColumn || lag != recordedLag {
            recorder.beginSegment(atColumn: view.nextEngineColumn,
                                  perColumn: perColumn, lagSamples: lag)
            recordedPerColumn = perColumn
            recordedLag = lag
        }
    }

    /// Drops seen so far, so a gap in either stream can be noticed.
    private var seenDroppedColumns: UInt64 = 0
    private var seenDroppedInput: UInt64 = 0
    /// The third kind of loss, and the only one that happens before the
    /// cascade: audio the device never delivered at all. See
    /// `markInputDropouts`.
    private var seenDroppedInputFrames: UInt64 = 0
    /// Where a hole already noticed will reach the right-hand edge, as an
    /// engine column, with the epoch that number belongs to. Nil when nothing
    /// is waiting.
    private var pendingDropout: (column: Int64, epoch: Int)?
    /// The engine column the last dropout line was drawn on, so the next one
    /// can be kept away from it. Nil when none has been drawn.
    private var lastDropoutColumn: Int64?
    private var seenInputDropouts: UInt64 = 0
    private var dropLogFrames: UInt64 = 0
    private var dropLogHoles: UInt64 = 0
    private var lastDropLog = Date.distantPast

    /// Mark audio the device never delivered, where it went missing.
    ///
    /// The one-second meter in `reportAudioMeters` can say the last second was
    /// thin; it cannot say when, and a horizontal scale that quietly
    /// compresses time is the one lie this display must not tell.
    ///
    /// Two halves, because the news and the place it belongs arrive at
    /// different times. The render callback finds a hole the moment it opens,
    /// but the audio on either side of it has only just been handed to the
    /// cascade and will not reach the right-hand edge for another
    /// `displayLagMS` -- 186 ms with De-skew on, more than forty columns at 4
    /// ms each. Marking on notice would draw the line that far to the left of
    /// the join it names. `markFileEndOnce` exists because an error of
    /// thirty-five milliseconds of exactly this kind was not acceptable, and
    /// this is the same standard.
    ///
    /// RePlay is deliberately not re-anchored here, unlike the two losses
    /// `captureTick` handles. Those desynchronise the picture from the
    /// recording -- one drops columns, the other drops captured audio. This
    /// one happens upstream of both, in `feedMono`'s caller, so the missing
    /// frames are absent from the picture and the recording in equal measure
    /// and the correspondence between them survives intact. That stops being
    /// true the moment columns are *inserted* to span the gap, which is the
    /// next step: `recordedPerColumn = 0` at the join is what it will want.
    private func markInputDropouts() {
        noticeInputDrops()
        placeDropoutIfDue()
    }

    private func noticeInputDrops() {
        let frames = audio.droppedInputFrames
        // Greater than, not different from -- the same rule `reportAudioMeters`
        // states for render errors. The count goes back to zero when the input
        // unit is replaced, and opening a file replaces it with nothing. A
        // counter starting again is not a hole; and anything still waiting for
        // the cascade belonged to the source that has just gone, so it must go
        // too, or it would be drawn on the file that replaced it.
        guard frames > seenDroppedInputFrames else {
            if frames < seenDroppedInputFrames { forgetDropouts() }
            seenDroppedInputFrames = frames
            seenInputDropouts = audio.inputDropouts
            return
        }
        dropLogFrames &+= frames - seenDroppedInputFrames
        seenDroppedInputFrames = frames
        // Holes, not ticks. A failing device opens one per callback -- 172 a
        // second at 256 frames -- while this runs at the display rate, so
        // counting arrivals here would report sixty of a hundred and seventy.
        let holes = audio.inputDropouts
        if holes > seenInputDropouts { dropLogHoles &+= holes - seenInputDropouts }
        seenInputDropouts = holes
        flushDropLog()
        // Nothing is scrolling and nothing is being kept: the columns made
        // while the picture is frozen are discarded, so a hole among them has
        // no consequence the picture could show, and the seam the pause leaves
        // already says that time jumps here. The counters are read either way,
        // so the hole cannot surface later against an unrelated column.
        guard !paused, let c = cochlea, c.columnMilliseconds > 0 else { return }
        // Finite and bounded before it becomes an `Int64`: the delays come
        // straight from the engine with no finiteness check of their own, and
        // `Int64(Double.nan)` traps.
        let lagColumns = c.displayLagMS / c.columnMilliseconds
        guard lagColumns.isFinite else { return }
        let due = view.nextEngineColumn
                + Int64(min(max(lagColumns, 0), 1e6).rounded())
        // One pending line at a time, and the earliest join wins.
        if let p = pendingDropout, p.epoch == view.contentEpoch,
           p.column <= due { return }
        // And no closer than a quarter of a second to the last line drawn.
        // Coalescing alone is not enough: with De-skew off the wait above is a
        // fraction of a column, so a continuously failing device would arm and
        // place on the same tick, every tick, and the picture would become an
        // orange field saying no more than one line and a count do.
        let spacing = Int64((250 / c.columnMilliseconds).rounded())
        if let last = lastDropoutColumn, due < last + spacing { return }
        pendingDropout = (due, view.contentEpoch)
    }

    private func placeDropoutIfDue() {
        guard let p = pendingDropout else { return }
        // A wipe renumbers the columns, so a target from before one names
        // audio that no longer exists.
        guard p.epoch == view.contentEpoch else { pendingDropout = nil; return }
        // Freezing strands it. The column numbering stops where it is while
        // the picture is paused and the hole's own columns are discarded, so
        // on the resume this target would name audio arriving afterwards --
        // and the seam the pause leaves has already said that time jumps.
        guard !paused else { pendingDropout = nil; return }
        guard view.nextEngineColumn >= p.column else { return }
        pendingDropout = nil
        lastDropoutColumn = p.column
        view.markDropout()
    }

    /// Drop anything waiting, and the spacing it was measured against.
    /// The column numbers on both sides belong to a source or a picture that
    /// is being replaced.
    private func forgetDropouts() {
        pendingDropout = nil
        lastDropoutColumn = nil
    }

    /// At most one line a second, like every other repeating line in this
    /// file. Called from the meter report as well, so that the last hole of a
    /// burst is not left sitting in the accumulator unreported.
    private func flushDropLog() {
        guard dropLogHoles > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDropLog) >= 1 else { return }
        lastDropLog = now
        let ms = Double(dropLogFrames) * 1000 / max(audio.sampleRate, 1)
        Log.say("INPUT DROPPED \(dropLogFrames) frames "
                + String(format: "(%.1f ms)", ms)
                + " in \(dropLogHoles) hole(s); "
                + "\(audio.inputDropouts) hole(s) since launch")
        dropLogFrames = 0
        dropLogHoles = 0
    }

    /// Take what the engine captured, and let go of what has scrolled off.
    ///
    /// Before `view.tick()`, so the samples behind a column are already held by
    /// the time the column itself is drawn.
    private func captureTick() {
        guard let c = cochlea else { return }
        // Before the guard below, not after. A wipe or a change of Speed while
        // the picture is frozen has to be noticed even though nothing is being
        // recorded then, or the terms in force when recording resumes would be
        // the ones from before it stopped.
        syncRecorder()

        // The two streams drop independently and to different depths -- the
        // column ring holds a thousand columns, the capture ring four seconds
        // -- so anything that stalls the display link, a minimised window most
        // obviously, loses different amounts of each. The picture already marks
        // that as a seam; without the same notice here the recording would go
        // on being mapped by terms that no longer describe it, and the sound
        // would be confidently wrong by seconds with nothing to say so.
        let dc = c.droppedColumns, di = c.droppedInput
        if dc != seenDroppedColumns || di != seenDroppedInput {
            // Not the difference. These are the *engine's* counters, and a new
            // engine starts them again at zero while the picture is kept -- an
            // ERB change does exactly that -- so the new value can be smaller
            // than the remembered one, and an unsigned subtraction there is a
            // trap, not a negative number.
            Log.say("REPLAY re-anchoring: a gap in the picture or the "
                    + "recording (\(seenDroppedColumns)->\(dc) columns, "
                    + "\(seenDroppedInput)->\(di) samples)")
            seenDroppedColumns = dc
            seenDroppedInput = di
            stopReplay()
            c.drainInput { _ in }        // whatever survived is unplaceable
            recordedPerColumn = 0        // and the next arrival starts afresh
            return
        }

        // Kept empty while it is not wanted. Turning capture off does not flush
        // the ring, so whatever the audio thread pushed between the last drain
        // and the pause would otherwise sit there and be handed over on the
        // first tick after the resume -- audio from before the join, spliced
        // into the segment that begins after it, whose columns were thrown
        // away. The same residue would cross a live/file/live round trip.
        guard c.capturing else {
            c.drainInput { _ in }
            return
        }
        c.drainInput { recorder.take($0) }
    }

    /// Move the line, and notice the end of the sound.
    ///
    /// Polled rather than driven by a completion handler. An
    /// `AVAudioPlayerNode` fires pending completions when it is stopped, so a
    /// handler can arrive on behalf of a playback that has already been
    /// replaced; the link is running anyway to move the line.
    private func replayTick() {
        guard audio.isReplaying else {
            // The graph can also be taken down from underneath this -- opening
            // a file, or changing the input device, stops everything the audio
            // side owns. Catching it here rather than at each of those places
            // means a line cannot be left behind on the picture by a path
            // nobody thought to name.
            if view.playhead != nil { stopReplay() }
            return
        }
        // The clock, which cannot stop reporting, before the node's position,
        // which can once its buffer has drained.
        if audio.hasReplayFinished { stopReplay(); return }
        // The selection has to still be on the picture. Narrowing the window
        // right-aligns what is drawn, so the left of a selection can scroll off
        // while it is being played, and a line cannot follow columns that are
        // no longer there.
        if let drawn = view.drawnColumns, drawn.lo > replayFromColumn {
            stopReplay()
            return
        }
        guard let pos = audio.replayFramePosition else { return }
        // Running out is one of the ways playback ends, and it ends the same
        // way the button does: the line goes, and the next press starts at the
        // beginning of the selection again.
        if pos >= audio.replayLength {
            stopReplay()
            return
        }
        guard let g = recorder.column(forSample: replayFromSample + pos,
                                      from: replayFromColumn)
        else { return }
        // Never outside what was selected, however the arithmetic rounds at
        // either end.
        view.playhead = min(max(g, replayFromColumn), replayToColumn)
    }

    /// The device the menu is showing, which is the one the user last chose.
    private var selectedDeviceID: AudioDeviceID? {
        let i = devicePopup.indexOfSelectedItem
        guard i >= 0, i < devices.count else { return nil }
        return devices[i].id
    }

    @objc private func toggleDeskew(_ sender: NSButton) {
        settings.deskew = sender.state == .on
        // De-skew wins. Turning it on with the close-up open would leave the
        // right-hand strip claiming to show the last sixth of a second while
        // the engine holds every column back by the apex's travel time.
        if settings.deskew { settings.closeUpSpanMS = 0 }
        // A seam, before the engine is told: the columns either side of this
        // were never adjacent. De-skew holds each tap back by its own
        // travelling-wave delay -- up to about 186 ms at the apex at ERB 0.6,
        // rather more if the filters are sharpened further, nothing at the
        // base -- so switching it slides the bottom of the picture against the
        // top. Marking it costs one line and stops the picture claiming a
        // continuity across the join that it does not have.
        view.markSeam()
        // A dropout still waiting for the cascade was given its column under
        // the old lag, and this changes that lag by nearly two hundred
        // milliseconds -- forty columns and more. It would be drawn that far
        // from the join it names, so it is dropped rather than moved: the seam
        // just placed already says time is not continuous here.
        forgetDropouts()
        cochlea?.deskew = settings.deskew
        applyCloseUp()
        showSettingsInControls()
        save()
    }

    @objc private func closeUpSpanChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Settings.closeUpSpans.count else {
            showCloseUpSpan()
            return
        }
        settings.closeUpSpanMS = settings.deskew ? 0 : Settings.closeUpSpans[i]
        applyCloseUp()
        save()
    }

    /// Show which span is in force, and grey out the ones that cannot be
    /// drawn at this Speed and window size.
    ///
    /// A span is impossible when no whole divisor gives a strip that is both
    /// wide enough to read and narrow enough to leave the picture half the
    /// window -- 320 ms at 1 ms per column, for instance, would need more
    /// columns than there is room for. Greying it is the honest way to say so;
    /// the alternative is a menu entry that silently does something else.
    private func showCloseUpSpan() {
        guard closeUpPopup != nil else { return }
        closeUpPopup.menu?.autoenablesItems = false
        let maxCols = view.maxCloseUpColumns
        for (i, span) in Settings.closeUpSpans.enumerated() {
            let ok = span == 0 || Settings.closeUpDivisors(
                spanMS: span, columnMS: columnMS, maxColumns: maxCols) != nil
            closeUpPopup.item(at: i)?.isEnabled = ok
        }
        closeUpPopup.isEnabled = !settings.deskew
                              && Settings.closeUpAvailable(columnMS)
        let span = settings.closeUpSpanMS
        let i = Settings.closeUpSpans.firstIndex { abs($0 - span) < 0.5 } ?? 0
        closeUpPopup.selectItem(at: i)
    }

    /// Push the close-up at both halves of the system, in the order that
    /// matters: the view has to know the new geometry before the engine
    /// starts producing columns at the new rate, or the first frame's worth
    /// arrives to be filed under the old one.
    private func applyCloseUp() {
        if !Settings.closeUpAvailable(columnMS) { settings.closeUpSpanMS = 0 }
        let on = settings.closeUpSpanMS > 0 && !settings.deskew
        let fit = on ? Settings.closeUpFit(spanMS: settings.closeUpSpanMS,
                                           columnMS: columnMS,
                                           maxColumns: view.maxCloseUpColumns,
                                           desiredColumns: settings.closeUpColumns)
                     : nil
        if on, fit == nil { settings.closeUpSpanMS = 0 }
        closeUpK = fit?.k ?? 1
        if let f = fit { settings.closeUpColumns = f.columns }
        view.setCloseUp(columns: fit?.columns ?? 0, aggregate: closeUpK)
        // The view needs the main picture's column time to turn a distance
        // across the picture into a duration. It is set here because this is
        // the one place that runs on every change that can alter it: Speed,
        // the close-up span, the boundary, and launch.
        view.mainColumnMS = columnMS
        cochlea?.columnMilliseconds = engineColumnMS
        showCloseUpSpan()
        // The control's own state has to be refreshed here rather than left to
        // the callers. Changing Speed changes the divisor, and the first
        // version of this relied on a full `showSettingsInControls` that the
        // Speed handler did not in fact call -- so the checkbox kept whatever
        // enabled state it had at launch and could not be switched on at all.
    }



    /// What the engine is actually asked for, which is not what the Speed
    /// control says when the close-up is open: it runs `divisor` times faster
    /// and the view takes every `divisor`-th column for the main picture.
    /// The divisor the current span and width work out to, kept because the
    /// engine's rate and the view's aggregation both have to agree with it.
    private var closeUpK = 1

    private var engineColumnMS: Double {
        closeUpK > 1 ? columnMS / Double(closeUpK) : columnMS
    }

    @objc private func toggleInvert(_ sender: NSButton) {
        settings.invert = sender.state == .on
        applyLevels()
        save()
    }

    @objc private func toggleAuto(_ sender: NSButton) {
        let on = sender.state == .on
        if !on && settings.autoGain {
            // Hand the control back where the controller left it, not where
            // it was last put by hand. Switching to manual is what you do when
            // Auto gain is close but not right, and it would be no use at all
            // if the picture jumped at the moment you took over.
            //
            // Folding the reference into Sensitivity makes the correct
            // reference zero, which is why the view is then told to forget it
            // rather than keep it for next time.
            //
            // The picture does jump if the sum lands outside the control's own
            // limits -- which means the controller had gone somewhere manual
            // control cannot express, so there is nowhere honest to put the
            // knob. It needs a source more than two hundred decibels from
            // where Sensitivity was left.
            settings.sensDB = Self.clampSens(settings.sensDB
                                             - view.autoReferenceDB)
            view.resetAutoReference()
        }
        settings.autoGain = on
        showSettingsInControls()
        applyLevels()
        save()
    }

    @objc private func sensChanged(_ sender: NSSlider) {
        // Auto gain owns this control while it is on, and the frame tick has
        // been writing the reference-corrected *readout* into it. Reading that
        // back would subtract the reference a second time.
        guard !settings.autoGain else { return }
        // Rounded, because the browser's slider has an integer step and these
        // two numbers are meant to be transferable between the apps: "95 and
        // 170" has to name the same window in both, and an NSSlider left at
        // 94.7 would quietly make that false.
        settings.sensDB = sender.doubleValue.rounded()
        applyLevels()
        save()
    }

    @objc private func rangeChanged(_ sender: NSSlider) {
        settings.rangeDB = sender.doubleValue.rounded()
        applyLevels()
        save()
    }

    /// Changing tuning means loading a different coefficient file, so the
    /// engine has to be rebuilt -- and the audio thread is reading the old one
    /// while we do it. Rather than hand a new `Cochlea` across that boundary,
    /// restart the source: both paths already build the engine before any
    /// audio flows, which is the one moment the handoff is free.
    ///
    /// Unless nothing is running, in which case the rebuild is not needed yet
    /// and restarting would cost the picture. See below.
    @objc private func erbScaleChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Settings.erbScales.count else { return }
        let scale = Settings.erbScales[i]
        guard scale != settings.erbScale else { return }
        settings.erbScale = scale
        Log.say("ERB scale -> \(scale)")

        if fileFinished {
            // The file has played and the picture is frozen on its end, which
            // is when somebody is most likely to be reading it. Nothing is
            // arriving to be drawn with the new tuning, so there is nothing to
            // rebuild yet: Replay and the microphone each build an engine from
            // `settings` at the moment they start, and will pick this up then.
            // Restarting here would replay the file unasked and throw away the
            // picture the tuning was being chosen against.
            Log.say("ERB deferred: file has finished, nothing to rebuild until "
                    + "the next Replay or return to live input")
        } else if audio.isFilePlayback, let url = lastFileURL {
            play(url, join: .tuningChange)   // from the top, new tuning
        } else {
            startLiveInput(deviceID: selectedDeviceID, join: .tuningChange)
        }
        // Saved only now. Persisting before the rebuild meant a scale that
        // failed to load was still written, and came back at the next launch
        // to fail again with no way out.
        save()
    }

    /// Nothing to tell the engine and nothing to wipe: every column carries
    /// both quantities, so the view already holds what the other mode needs
    /// and re-renders the whole screen from what is on it. Switching while
    /// paused at the end of a file therefore shows the same moment two ways.
    @objc private func displayModeChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < DisplayMode.allCases.count else { return }
        let mode = DisplayMode.allCases[i]
        guard mode != settings.displayMode else { return }
        settings.displayMode = mode
        applyLevels()
        Log.say("display mode -> \(mode.title)")
        save()
    }

    @objc private func timeStepChosen(_ sender: NSButton) {
        guard let i = timeButtons.firstIndex(of: sender) else { return }
        setColumnStep(i)
    }

    private func stepTime(by delta: Int) {
        setColumnStep(Settings.nearestColumnStep(columnMS) + delta)
    }

    // MARK: - settings
    //
    // Three directions, kept apart deliberately: `showSettingsInControls`
    // pushes the stored state at the toolbar, `applyLevels` and
    // `applyToEngine` push it at the cochlea, and the action handlers above
    // pull it from the user. Nothing reads state back out of a control.

    /// Saving on every slider tick looks profligate, but `UserDefaults` is an
    /// in-memory dictionary with a coalesced flush -- a drag costs a few dozen
    /// dictionary writes and one file write, which is cheaper than the
    /// bookkeeping of debouncing it.
    private func save() { settings.save() }

    private func showSettingsInControls() {
        deskewBox.state = settings.deskew ? .on : .off
        spectrumButton.state = settings.showSpectrum ? .on : .off
        // The window is shown or hidden here as well as in the action, because
        // this runs at launch and after Defaults, where no action fires.
        updateSpectrum()
        // Without growing the window: at launch the saved frame already
        // accounts for the strip. `restoreDisplayDefaults` does its own resize
        // afterwards, because that one *is* somebody asking.
        setWaveform(settings.showWaveform, growingWindow: false)
        showCloseUpSpan()
        invertBox.state = settings.invert ? .on : .off
        autoBox.state = settings.autoGain ? .on : .off
        sensSlider.doubleValue = settings.sensDB
        rangeSlider.doubleValue = settings.rangeDB
        selectionSlider.doubleValue = settings.replayGainDB
        // Forget what the knob was last shown, having just overwritten it with
        // the raw setting. Without this, `showAutoSensitivity` recomputes the
        // same reference-corrected value it wrote before, finds it unchanged,
        // and leaves the uncorrected number on screen -- until the reference
        // happens to move, which on a paused or finished display is never.
        shownSens = nil
        // Auto gain owns Sensitivity while it is on: the control reports what
        // the controller is doing rather than accepting instructions. Wanting
        // it somewhere else is exactly what switching Auto gain off is for.
        sensSlider.isEnabled = !settings.autoGain
        showTimeStep()
        applyDiagnostics()
        if let i = Settings.erbScales.firstIndex(of: settings.erbScale) {
            erbPopup.selectItem(at: i)
        }
        if let i = DisplayMode.allCases.firstIndex(of: settings.displayMode) {
            modePopup.selectItem(at: i)
        }
    }

    /// Push the level mapping at the *view*, not the engine. The engine emits
    /// dB and knows nothing about Gain or Level, which is what lets a change
    /// re-expose the whole picture rather than only the columns still to come.
    private func applyLevels() {
        let w = settings.exposureWindow
        view.exposure = CochleagramView.Exposure(whiteDB: w.white,
                                                 blackDB: w.black,
                                                 autoGain: autoGain,
                                                 inverted: settings.invert,
                                                 mode: settings.displayMode)
    }

    /// Everything the toolbar owns, pushed into an engine that has just been
    /// built. Without this a restored setting would survive launch and then be
    /// silently dropped the moment a file was opened, because opening one
    /// makes a fresh `Cochlea` at the file's sample rate.
    private func applyToEngine() {
        cochlea?.deskew = settings.deskew
        applyCloseUp()                 // sets the engine's column rate too
        applyLevels()
    }

    /// Back to factory. Confirmed first: it throws away the window position
    /// as well, which is not obvious from the menu title.
    /// The display controls, and only those, back to their starting values.
    ///
    /// Deliberately narrower than `resetSettings`: the output device, the
    /// diagnostics, the window and its position are all left alone, because
    /// this is a button on the toolbar rather than a considered act in a
    /// settings panel, and pressing it should never cost you anything you
    /// would have to go and set up again.
    @objc private func restoreDisplayDefaults(_ sender: Any?) {
        // The stored defaults, minus ERB and Speed -- and so minus the reload
        // that restoring those used to need. What the button restores is not a
        // separate set of values, only a shorter list of settings; keeping a
        // second copy of the values would be a way for the two to drift.
        let d = Settings()
        let hadDeskew = settings.deskew
        settings.deskew         = d.deskew
        settings.invert         = d.invert
        settings.autoGain       = d.autoGain
        settings.sensDB         = d.sensDB
        settings.rangeDB        = d.rangeDB
        settings.displayMode    = d.displayMode
        settings.closeUpSpanMS  = d.closeUpSpanMS
        settings.closeUpColumns = d.closeUpColumns
        settings.showSpectrum   = d.showSpectrum
        // Volume is a display control in the sense that matters here: it is on
        // the toolbar and it is one of the values the two apps have to agree
        // on. Applied to any sound already running, so the button's effect is
        // audible rather than only stored.
        settings.replayGainDB   = d.replayGainDB
        audio.setReplayGain(settings.replayGainDB)

        // The waveform is restored through its own path, because it is the one
        // display setting whose change resizes the window -- and a press of
        // Defaults is somebody asking, so the window should follow. Taken
        // *before* `showSettingsInControls`, which applies the stored state
        // without resizing and would otherwise leave the two disagreeing.
        setWaveform(d.showWaveform, growingWindow: true)

        showSettingsInControls()
        applyToEngine()
        // The picture survives, where this used to wipe it. Nothing here
        // changes what a column *means* -- the tuning and the time scale are
        // exactly where they were, and everything that did move is a mapping
        // from level to grey, which `exposure`'s setter re-applies to what is
        // already drawn. Wiping was right when the button also restored ERB
        // and Speed; now it would throw away the thing somebody pressed the
        // button in order to see.
        //
        // With one exception that is not this method's to fix: closing an open
        // close-up retimes the bitmap, and `setCloseUp` wipes when it retimes.
        // Pressing Defaults with the strip open therefore still costs the
        // picture, exactly as switching the strip off by hand does.
        //
        // De-skew does change what a column means, so it gets the same seam
        // the checkbox draws -- after `applyToEngine`, not before, so that it
        // is not one of the things a retime would take with it. The browser
        // marks it at the same point.
        if settings.deskew != hadDeskew { view.markSeam() }
        // The reference goes too, and this is the point of the whole button.
        // Sensitivity is only reproducible if it means the same thing in both
        // apps, and while Auto gain is on it means "95 plus wherever the
        // controller has drifted" -- a number that depends on everything heard
        // since launch. Restoring 95 and leaving the drift in place would put
        // the two apps back where they were: agreeing on the control and
        // disagreeing about the picture.
        view.resetAutoReference()
        save()
        Log.say("SETTINGS display controls restored to defaults")
    }

    @objc func resetSettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset settings to their defaults?"
        alert.informativeText = "The display controls and the window size and "
            + "position go back to how they started. Nothing else is affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Settings.forgetEverything()
        let hadScale = settings.erbScale
        settings = Settings()
        showSettingsInControls()
        refreshOutputList()
        applyToEngine()
        // `applyToEngine` pushes levels and de-skew, but the tuning lives in
        // the coefficient file, so restoring its default means loading a
        // different one. Without this the menu would claim 1.0 while the
        // engine went on running whatever was there before.
        if settings.erbScale != hadScale {
            if audio.isFilePlayback || fileFinished, let url = lastFileURL {
                play(url, join: .tuningChange)
            } else {
                startLiveInput(deviceID: selectedDeviceID, join: .tuningChange)
            }
        }
        // Wiped here, unlike an ordinary scale change: a reset is not an
        // adjustment you are watching the effect of, and several settings
        // moved at once.
        view.clear()
        // Including what Auto gain had drifted to. Restoring the default
        // Sensitivity while the reference still holds the last room's
        // correction is not back to factory, it is back to factory plus a
        // hidden offset.
        view.resetAutoReference()

        // The frame is still named, so this position is what gets saved from
        // here on; clearing the key alone would leave the current frame in
        // place and write it straight back.
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()

        reportTimeScale()
        Log.say("SETTINGS reset to defaults")
    }

    private func requestMicrophoneIfNeeded(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default: done(false)
        }
    }

    /// macOS grants microphone access to a *code signature*, not to a path.
    /// An ad-hoc signature (`codesign -s -`) has no stable identity, so every
    /// rebuild looks like a brand new application and the grant is asked for
    /// again. Signing with a real certificate fixes it permanently -- see
    /// make_app.sh. Until then, offer the shortcut.
    private func offerMicrophoneSettings() {
        let alert = NSAlert()
        alert.messageText = "Cochleagram needs microphone access"
        alert.informativeText = [
            "Turn on Cochleagram under Privacy & Security, Microphone.",
            "",
            "If you are asked every time you rebuild, it is because the app is",
            "ad-hoc signed and macOS treats each build as a different",
            "application. Signing with an Apple Development certificate makes",
            "the permission stick -- make_app.sh will use one automatically if",
            "you have one.",
        ].joined(separator: "\n")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:"
                         + "com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func report(_ text: String, isProblem: Bool = false) {
        status.stringValue = text
        status.textColor = isProblem ? .systemRed : .secondaryLabelColor
        status.toolTip = text          // truncated messages stay readable
    }
}

/// A button that works out its tool tip at the moment it is asked for it.
///
/// The Speed buttons have to say something that is not known when they are
/// made and does not stay true afterwards: how much time the window holds
/// depends on the window's width and on where the close-up divider sits, both
/// of which the user moves.
///
/// Through `addToolTipRect` and `NSViewToolTipOwner` rather than by assigning
/// `toolTip` on `mouseEntered`, which is what this did first and why the tip
/// took several seconds to appear. `toolTip` is a stored string whose setter
/// removes and reinstalls the view's tooltip rect; doing that while the
/// pointer is already inside the rect restarts the machinery that was already
/// counting down, so the tip arrived late or waited for the pointer to move
/// again. `NSViewToolTipOwner` is the API meant for a value that has to be
/// computed: the rect is installed once and the string is asked for when the
/// tip is about to be shown.
final class LiveTipButton: NSButton, NSViewToolTipOwner {

    var tip: (() -> String)?
    private var tipTag: NSView.ToolTipTag?

    /// Reinstalled on every layout, because the rect is in the view's own
    /// coordinates and a button that has not been laid out yet has none worth
    /// having.
    private func installTip() {
        if let t = tipTag { removeToolTip(t) }
        tipTag = bounds.isEmpty ? nil
                                : addToolTip(bounds, owner: self,
                                             userData: nil)
    }

    override func layout() {
        super.layout()
        installTip()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTip()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        tip?() ?? ""
    }
}
