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
    private var exposureSlider: RangeSlider!
    private var timeButtons: [NSButton] = []
    private var erbPopup: NSPopUpButton!
    private var modePopup: NSPopUpButton!
    private var pauseButton: NSButton!

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
        view.tick()
        reportAudioMeters()
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

        showPauseButton()
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

        // Pause, in its own compartment between the display controls and the
        // file controls -- it belongs to neither. Space has always done this;
        // the button exists because space does not reach a Mac being used
        // over screen sharing with the keyboard somewhere else, and because
        // nothing in the window said the key existed.
        pauseButton = button("", #selector(pauseButtonPressed(_:)))
        pauseButton.imagePosition = .imageOnly
        topRow.addArrangedSubview(pauseButton)

        topRow.addArrangedSubview(divider())

        // No "Live Input" button. The device menu in Settings starts live
        // input on whatever you choose, and two controls doing the same job
        // is how they came to disagree: the button ignored the menu and
        // reopened the *system default*, leaving the menu showing a device
        // that was not the one being captured.
        let playButton = button("Play File", #selector(openFile(_:)))
        topRow.addArrangedSubview(playButton)

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
        // whatever the spacer would otherwise have given up, which is the
        // one thing keeping Replay at the right-hand end of the row.
        fileNameLabel.widthAnchor.constraint(
            lessThanOrEqualToConstant: 220).isActive = true
        fileNameLabel.isHidden = true
        topRow.addArrangedSubview(fileNameLabel)

        topRow.addArrangedSubview(spacer())

        // Replay, at the right-hand end of the row -- which the spacer above
        // and the equal-width constraint below put directly over the last
        // Speed detent.
        replayButton = button("", #selector(replayFile(_:)))
        if let symbol = NSImage(systemSymbolName: "arrow.clockwise",
                                accessibilityDescription: "Replay") {
            replayButton.image = symbol
            replayButton.imagePosition = .imageOnly
        } else {
            replayButton.title = "↻"        // if the symbol is ever missing
        }
        replayButton.toolTip = "Replay the last file"
        replayButton.isHidden = true
        topRow.addArrangedSubview(replayButton)

        // ---- lower row -------------------------------------------------

        invertBox = NSButton(checkboxWithTitle: "Invert",
                             target: self, action: #selector(toggleInvert(_:)))
        bottomRow.addArrangedSubview(invertBox)

        autoBox = NSButton(checkboxWithTitle: "AGC",
                           target: self, action: #selector(toggleAuto(_:)))
        autoBox.toolTip = "Automatic gain control: measure the Range against "
                        + "a reference that follows the loudest tap, rather "
                        + "than against full scale."
        bottomRow.addArrangedSubview(autoBox)

        // De-skew sits next to Close-up rather than up in the top row,
        // because it is the control that greys Close-up out. A switch that
        // disables another one has to be within sight of it, or the other one
        // simply appears to have stopped working.
        deskewBox = NSButton(checkboxWithTitle: "De-skew",
                             target: self, action: #selector(toggleDeskew(_:)))
        deskewBox.toolTip = "Compensate the travelling-wave delay so a click "
                          + "stands vertical. Costs about 186 ms of display "
                          + "latency, and more at sharper tunings. Close-up is "
                          + "unavailable while this is on."
        bottomRow.addArrangedSubview(deskewBox)

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
        bottomRow.addArrangedSubview(closeUpPopup)

        // Invert, AGC, De-skew and Close-up are switches; the range is a
        // measurement. Without a line the slider reads as a fifth thing in the
        // same group, and the eye goes looking for the checkbox that belongs
        // to it.
        bottomRow.addArrangedSubview(divider())

        // One slider, two knobs: the ends of the level-to-grey mapping. The
        // left knob is where the picture reaches white, the right where it
        // reaches black. Sliding both together is a gain change; sliding them
        // apart is a contrast change.
        //
        // No label and no numeric readout: the knobs are the reading, and the
        // tooltip carries the units for anyone who wants them.
        exposureSlider = RangeSlider()
        exposureSlider.range = Settings.exposureRange
        exposureSlider.minimumSeparation = Settings.minimumExposureSpan
        exposureSlider.target = self
        exposureSlider.action = #selector(exposureChanged(_:))
        exposureSlider.toolTip = "Left knob: the level that renders white. "
                               + "Right knob: the level that renders black. "
                               + "dB, relative to the AGC reference when AGC "
                               + "is on and to full scale when it is off."
        exposureSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        exposureSlider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        bottomRow.addArrangedSubview(exposureSlider)

        bottomRow.addArrangedSubview(divider())

        // Horizontal scale. Detents rather than a slider: the useful settings
        // are a handful of ratios apart, and a slider makes you hunt for them
        // and lands you between them. Radio buttons in a shared superview
        // group themselves, so only the selection needs managing.
        //
        // "Speed", not "Time": the detents run widest-column first, so the
        // scroll gets faster to the right, which the label has to agree with.
        // Unlike ERB this one keeps its label -- the dials carry no text at
        // all, so without it the row would end in fifteen anonymous circles.
        bottomRow.addArrangedSubview(NSTextField(labelWithString: "Speed"))
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
        bottomRow.addArrangedSubview(times)

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

        // Replay's right edge sits exactly over the rightmost Speed detent.
        //
        // Said as a constraint against `times` rather than by making the two
        // rows equal width. Equal widths would land in the same place today
        // only because Speed happens to be last in the lower row, and would
        // quietly stop meaning this the moment anything was added after it.
        // Nothing here is tied to the window's edge: the row is as wide as it
        // needs to be to reach that point, and the spacer takes up the slack.
        topRow.trailingAnchor.constraint(equalTo: times.trailingAnchor).isActive = true

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
        guard let c = Cochlea(coefficientURL: url, inputRate: inputRate) else {
            report("Could not load \(url.lastPathComponent).", isProblem: true)
            return nil
        }
        cochlea = c
        view.adopt(c, join: join)
        applyToEngine()
        Log.say("COCHLEA \(c.tapCount) taps, "
                + "\(String(format: "%.1f", c.frequencies.last ?? 0))-"
                + "\(String(format: "%.0f", c.frequencies.first ?? 0)) Hz, "
                + "input \(Int(inputRate)) Hz, internal \(Int(c.internalRate)) Hz, "
                + "\(columnMS) ms/column, \(settings.erbScale) x ERB")
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
                self.view.isPaused = false
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
            try audio.startFile(url: url) { makeCochlea(inputRate: $0, join: join) }
            lastFileURL = url
            hasPlayedThrough = false
            paused = false
            fileFinished = false
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

    /// The file has played its last sample.
    private func fileDidFinish() {
        fileFinished = true
        hasPlayedThrough = true
        showTransport()

        // Draw what the engine has already produced *before* freezing. The
        // completion fires once the last sample has been played, so the final
        // columns are sitting in the ring; pausing first would leave them
        // undrawn and put the green line short of the actual end.
        view.tick()
        view.markFileEnd()

        paused = true
        // Anything arriving from here on is the player rendering silence into
        // the tap. Discard it rather than queue it, or it would scroll the end
        // of the file away behind a wall of blank columns the moment the
        // display resumed.
        view.discardWhilePaused = true
        view.isPaused = true
        audio.finishedPlayingFile()

        report("Finished — space returns to live input.")
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
        settings.autoGain = sender.state == .on
        applyLevels()
        save()
    }

    @objc private func exposureChanged(_ sender: RangeSlider) {
        settings.whiteDB = sender.lowValue
        settings.blackDB = sender.highValue
        applyLevels()
        save()
    }

    /// Changing tuning means loading a different coefficient file, so the
    /// engine has to be rebuilt -- and the audio thread is reading the old one
    /// while we do it. Rather than hand a new `Cochlea` across that boundary,
    /// restart the source: both paths already build the engine before any
    /// audio flows, which is the one moment the handoff is free.
    @objc private func erbScaleChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Settings.erbScales.count else { return }
        let scale = Settings.erbScales[i]
        guard scale != settings.erbScale else { return }
        settings.erbScale = scale
        Log.say("ERB scale -> \(scale)")

        if audio.isFilePlayback || fileFinished, let url = lastFileURL {
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
        showCloseUpSpan()
        invertBox.state = settings.invert ? .on : .off
        autoBox.state = settings.autoGain ? .on : .off
        exposureSlider.lowValue = settings.whiteDB
        exposureSlider.highValue = settings.blackDB
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
        view.exposure = CochleagramView.Exposure(whiteDB: settings.whiteDB,
                                                 blackDB: settings.blackDB,
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
