import AVFoundation
import AudioToolbox
import CoreAudio

/// Feeds the cochlea from either the input device or a file.
///
/// The two paths are deliberately different machinery. **Live input** goes
/// through `InputUnit`, a HAL unit bound to one device and driven by that
/// device's clock -- see the note there for why `AVAudioEngine` could not do
/// this job. **File playback** stays on `AVAudioEngine`, which is the right
/// tool for it: the file has to be audible, latency does not matter when the
/// sound and the picture are both derived from the same player, and the engine
/// handles decoding and scheduling.
///
/// Both converge on `feedMono`, which is where the metering lives.
final class AudioSource {

    // MARK: - live input

    private var input: InputUnit?

    // MARK: - file playback
    //
    // Built per file rather than kept alive: a half-torn-down graph is harder
    // to reason about than a fresh one, and live input no longer needs an
    // engine at all, so there is no reason for one to exist while a microphone
    // is being listened to.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    /// Removing a tap from a node that has none throws; remember which.
    private var tappedNode: AVAudioNode?

    private var cochlea: Cochlea?
    private var monoScratch = [Float]()

    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0
    /// Which device we are actually listening to, so the UI can avoid
    /// restarting for a selection that has not changed.
    private(set) var currentDeviceID: AudioDeviceID?

    /// Running totals, so somebody else can work out the rates.
    ///
    /// These used to be turned into a log line on the audio thread once a
    /// second. That was survivable at 4410 frames -- 100 ms of slack -- but at
    /// 256 frames the deadline is 5.8 ms and `Log.say` allocates a string,
    /// takes a lock and writes to stdout. Overrunning the deadline once a
    /// second to report how well we are meeting the deadline is not a trade
    /// worth making, so the audio thread now only counts, and `AppDelegate`
    /// turns counts into sentences where it is safe to do so.
    struct Meters {
        /// How much audio actually arrived, as opposed to how much the format
        /// claimed. This is the number that caught the old input path
        /// delivering 0.29x real time; it earns its keep.
        var samples = 0
        var buffers = 0
        var lastFrames = 0
        /// Seconds of CPU spent in the cascade. Against the seconds of audio
        /// it covers this gives a load figure; at 1.0 the audio thread is not
        /// real time and buffers get dropped -- which looks exactly like a
        /// device delivering slowly, so the two have to be read side by side
        /// to tell them apart.
        var dspSeconds = 0.0
    }

    /// Written only on the audio thread, read only on the main one, with no
    /// synchronisation. Deliberate: every field is a naturally aligned word,
    /// nothing but a log line is derived from them, and the worst a torn read
    /// can do is misreport one second. A lock here would be a real bug in
    /// exchange for a cosmetic one.
    private(set) var meters = Meters()

    /// `meters.samples` as it stood when the current file started, so the
    /// samples belonging to *this* file can be counted without resetting a
    /// meter that spans every source since launch. Subtract to get the length
    /// of file the tap has actually delivered so far.
    private(set) var samplesAtFileStart = 0

    /// How long the file is, in frames, and how many of those have actually
    /// reached the cascade.
    ///
    /// The end of a recording is a fact about the audio. Dating it by the
    /// `.dataPlayedBack` completion instead measures the *output's* timeline,
    /// which the tap runs behind -- so the mark landed while the last 35 ms of
    /// the file had still not been drawn, and the picture stopped short of the
    /// sound. Counting what has been fed puts the boundary where the audio is.
    private var fileFrames = 0
    private var fileFramesFed = 0

    /// Whether the length is known, and so whether a sample boundary is coming
    /// at all. `AVAudioFile.length` can be zero or an estimate -- some
    /// compressed formats only know once decoded -- and waiting for a boundary
    /// that cannot arrive would leave the display running on the player's
    /// silence until the wait gave up.
    var knowsFileLength: Bool { fileFrames > 0 }

    /// Set on the audio thread when the last frame of the file has been fed,
    /// read by the main thread's frame tick. A single store and a single load
    /// of a `Bool`: no lock, because a lock here would be a real bug traded
    /// for a cosmetic one, and the worst a missed read can do is mark on the
    /// next frame instead of this one.
    private(set) var fileSamplesEnded = false

    /// TEMPORARY DIAGNOSTIC. Where the first non-silent sample of this file
    /// landed in the stream the tap actually delivered. An *absolute* position
    /// in that stream: subtract `samplesAtFileStart` for the file-relative
    /// frame. `reference/pureimpulse.wav` has exactly one non-zero sample, at
    /// 4410, so anything larger is silence the tap captured before the file
    /// began playing. -1 until one is seen.
    private(set) var firstNonZeroFrame = -1

    /// Renders the input unit could not complete. Should stay at zero.
    var renderErrors: UInt64 { input?.renderErrors ?? 0 }

    /// Called when a file finishes playing.
    var onFinish: (() -> Void)?

    // MARK: - live input

    func startInput(deviceID: AudioDeviceID? = nil,
                    makeCochlea: (Double) -> Cochlea?) throws {
        stop()
        AudioDevices.logAll()

        guard let id = deviceID ?? AudioDevices.defaultInputID else {
            throw NSError(domain: "Cochleagram", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No audio input device is available."])
        }
        if let chosen = AudioDevices.inputs().first(where: { $0.id == id }) {
            Log.say("DEVICE in use: \(chosen.summary)")
        }

        // Open before building the cochlea: the device decides the sample
        // rate, and the cascade has to be designed for the rate it will
        // actually be fed.
        let unit = InputUnit()
        try unit.open(deviceID: id)
        sampleRate = unit.sampleRate

        guard let c = makeCochlea(unit.sampleRate) else {
            unit.close()
            throw NSError(domain: "Cochleagram", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not load the cochlea coefficients."])
        }
        cochlea = c

        // `unowned` rather than `weak`: a weak reference costs a lock on every
        // access, on the one thread that must never take one. The unit is
        // closed before this object goes away, and closing waits for the IO
        // thread, so the reference cannot outlive its target.
        unit.onAudio = { [unowned self] samples, frames in
            self.feedMono(samples, frames: frames)
        }
        try unit.start()

        input = unit
        currentDeviceID = id
        isRunning = true
    }

    // MARK: - file playback

    /// Where playback goes, by device UID; empty means the system default.
    ///
    /// `AVAudioEngine` opens the default output and offers no API to change it,
    /// so this is set on the output node's underlying audio unit before the
    /// engine starts. Someone whose speakers are not the system default -- an
    /// external DAC, an aggregate device -- otherwise gets a picture and
    /// silence, with nothing in the interface to suggest why.
    var outputDeviceUID = ""

    /// 0 = every channel, 1 = channels 1-2, 2 = channels 3-4, ...
    var outputChannelPair = 0

    /// Point the engine's output at `outputDeviceUID`.
    ///
    /// Must happen before `start()`: the device cannot be changed on a running
    /// unit. Failure is deliberately not fatal -- a device that has been
    /// unplugged since it was chosen should mean the default speaker and a note
    /// in the log, not a dead Play button.
    private func routeOutput(_ engine: AVAudioEngine) {
        outputChannels = 0
        guard let au = engine.outputNode.audioUnit else { return }

        // --- which device -------------------------------------------------
        var device: AudioDevice?
        if !outputDeviceUID.isEmpty {
            device = AudioDevices.device(uid: outputDeviceUID, outputs: true)
            if let d = device {
                var id = d.id
                let err = AudioUnitSetProperty(au,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                if err == noErr {
                    Log.say("OUTPUT \(d.summary)")
                } else {
                    Log.say("OUTPUT could not select \(d.name) (error \(err)); "
                            + "using the default")
                    device = nil
                }
            } else {
                Log.say("OUTPUT device \(outputDeviceUID) is gone; "
                        + "using the default")
            }
        }
        // The channel map needs the channel count of whatever is actually in
        // use, which for the default is not known until we look it up.
        if device == nil, let id = AudioDevices.defaultOutputID {
            device = AudioDevices.outputs().first { $0.id == id }
        }

        outputChannels = device?.channels ?? 0
        applyChannelMap(engine, quiet: false)
    }

    /// How many channels the device in use has; 0 until playback is set up.
    private var outputChannels = 0

    /// Send the file's two channels to the chosen pair, or to all of them.
    ///
    /// `kAudioOutputUnitProperty_ChannelMap` has one entry per *device*
    /// channel, holding the index of the source channel that feeds it, or -1
    /// for silence. Stereo into a four-channel aggregate defaults to
    /// [0, 1, -1, -1] -- and if the listener's DAC is the second pair, that is
    /// silence, with no error raised anywhere.
    ///
    /// On a two-channel device every setting produces [0, 1], which is what
    /// would have happened anyway, so this cannot make ordinary hardware worse.
    ///
    /// Applied twice -- once when the device is chosen and again after
    /// `prepare()` -- because the engine may reconfigure the output node when
    /// the graph is connected, and which side of that the map survives is not
    /// documented. Setting it a second time costs nothing if the first held.
    private func applyChannelMap(_ engine: AVAudioEngine, quiet: Bool) {
        guard let au = engine.outputNode.audioUnit else { return }
        guard outputChannels > 0 else {
            if !quiet {
                Log.say("OUTPUT channel count unknown; "
                        + "using the device's own routing")
            }
            return
        }
        var map = [Int32](repeating: -1, count: outputChannels)
        let first = (outputChannelPair - 1) * 2
        if outputChannelPair <= 0 || first >= outputChannels {
            // All channels -- and also the fallback when the stored pair is
            // past the end of the device now in use, which the menu cannot
            // always prevent: the chosen device may have been unplugged
            // between opening Settings and pressing Play. Leaving the map all
            // -1 in that case would be silence reported as success.
            for i in 0..<outputChannels { map[i] = Int32(i % 2) }
        } else {
            map[first] = 0
            if first + 1 < outputChannels { map[first + 1] = 1 }
        }
        let err = AudioUnitSetProperty(au,
            kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0,
            map, UInt32(MemoryLayout<Int32>.size * map.count))
        if err != noErr {
            // Not fatal: without a map the unit does what it did before, which
            // is right for everybody whose speakers are the first pair. Logged
            // even on the quiet pass -- that is the pass whose result is in
            // doubt, and a silent failure here looks exactly like the problem
            // the map was added to solve.
            Log.say("OUTPUT channel map rejected (\(fourCC(err))); "
                    + "using the device's own routing")
        } else if !quiet {
            Log.say("OUTPUT channel map \(map)")
        }
    }

    func startFile(url: URL, makeCochlea: (Double) -> Cochlea?) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        sampleRate = format.sampleRate
        guard let c = makeCochlea(format.sampleRate) else {
            throw NSError(domain: "Cochleagram", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not load the cochlea coefficients."])
        }
        cochlea = c
        monoScratch = [Float](repeating: 0, count: 8192)

        let e = AVAudioEngine()
        engine = e
        // Before anything is attached or connected: asking for the output
        // node's audio unit is what instantiates it, and the device has to be
        // chosen while it is still stopped.
        routeOutput(e)
        let node = AVAudioPlayerNode()
        player = node
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: format)

        // Tap the player rather than the main mixer: it is one node earlier,
        // and the mixer's format can differ from the file's.
        // 512 rather than something larger, but the size does not matter as
        // much as it looks like it should: the 35 ms by which both marks miss
        // the audio was measured at 512 and again at 2048, unchanged. Tap
        // buffers in flight are not where that time goes.
        // The time is no longer discarded. It is what says which part of a
        // buffer is the file and which part is the silence the engine renders
        // before the player starts.
        node.installTap(onBus: 0, bufferSize: 512,
                        format: format) { [weak self] buf, when in
            self?.feed(buf, when: when)
        }
        tappedNode = node
        e.prepare()
        applyChannelMap(e, quiet: true)
        // Before the engine runs, and so before the tap can fire.
        samplesAtFileStart = meters.samples
        firstNonZeroFrame = -1
        fileFrames = Int(file.length)
        fileFramesFed = 0
        fileSamplesEnded = false
        try e.start()
        // `.dataPlayedBack`, not the default. The plain `scheduleFile`
        // completion fires when the player has *consumed* the file, which on
        // a short file is almost immediately and always well before the last
        // sample is heard -- so "Finished" arrived while the picture still had
        // most of the file to draw.
        node.scheduleFile(file, at: nil,
                          completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            DispatchQueue.main.async { self?.onFinish?() }
        }
        node.play()
        isRunning = true
    }

    /// The `unowned self` in the input unit's callback is only sound because
    /// this runs first and `close()` waits for the device's IO thread.
    deinit { stop() }

    func stop() {
        // Its own graph, so it survives everything below unless it is named.
        // Nothing else here would take it down, and a playback left running
        // over a source change would be audible over a picture it no longer
        // belongs to.
        stopReplay()
        input?.close()
        input = nil

        tappedNode?.removeTap(onBus: 0)
        tappedNode = nil
        player?.stop()
        player = nil
        engine?.stop()
        engine = nil
        isRunning = false
        currentDeviceID = nil
    }

    /// Wind the file graph down after playback has finished.
    ///
    /// Deliberately not `stop()`. This is called on the main thread from the
    /// player's own completion callback, and `AVAudioPlayerNode.stop()` and
    /// `AVAudioEngine.stop()` both block until the render thread quiesces.
    /// That is a user-interactive thread waiting on a default-QoS one -- the
    /// priority inversion the "Hang Risk" diagnostic reports -- and doing it
    /// from inside the completion path is a documented way to deadlock.
    ///
    /// So the references are cleared synchronously, leaving this object's
    /// state consistent the instant this returns, and only the blocking part
    /// is handed to another queue. The captured nodes keep themselves alive
    /// until it has finished with them.
    func finishedPlayingFile() {
        let node = player, engineToStop = engine
        // The tap comes off *here*, synchronously, and not with the rest.
        //
        // It is the cheap call -- unlike `stop()` it does not wait on the
        // render thread -- and it is the one that decides when this graph
        // stops feeding the cascade. Deferred with the others, the old tap
        // went on delivering the finished player's silence into whatever
        // engine came next, while that engine's own tap was also running: two
        // producers on a structure whose contract (`cochlea.h`) is one.
        //
        // That window was survivable only by accident. Building a `Cochlea`
        // took about half a second, and the next `startFile` spent it before
        // starting any audio, which was long enough for the utility queue to
        // have finished. The engine is reused now, that half second is gone,
        // and with it the thing that was serialising these.
        tappedNode?.removeTap(onBus: 0)
        player = nil
        engine = nil
        tappedNode = nil
        isRunning = false
        // `.utility`, not `.userInitiated`. The point is not merely to get off
        // the main thread -- it is to wait from a thread that is not more
        // important than the one being waited on. AVAudioEngine's workers run
        // at default QoS, so a user-initiated queue blocking on them is the
        // same priority inversion one step down, and the diagnostic says so.
        // Nothing is waiting for this teardown, so the lowest useful band is
        // the correct one.
        DispatchQueue.global(qos: .utility).async {
            node?.stop()
            engineToStop?.stop()
            Log.say("FILE graph torn down off the main thread")
        }
    }

    var currentCochlea: Cochlea? { cochlea }

    /// True when playing a file, as opposed to listening to a device. Only a
    /// file can genuinely be paused; live input carries on regardless.
    var isFilePlayback: Bool { player != nil }

    func setPaused(_ paused: Bool) {
        guard let node = player else { return }
        if paused { node.pause() } else { node.play() }
    }

    // MARK: - audio thread

    /// File path: downmix an engine buffer and hand it on.
    private func feed(_ buf: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let channels = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return }

        // Which part of this buffer is the file. For live input the answer is
        // always "all of it": there is no player, and no length to run out of.
        var skip = 0
        var take = frames
        var ended = false
        if let node = player {
            // Nil until the player is really playing. That covers the silence
            // the engine renders between `start()` and `play()` -- three
            // render quanta of it, 1536 frames, which used to be fed to the
            // cascade as though it were the opening of the file and put
            // everything in the picture 34.8 ms late.
            guard let played = node.playerTime(forNodeTime: when),
                  played.isSampleTimeValid else { return }
            // And a buffer that straddles the start is part silence too. The
            // frames before zero are measured, not assumed.
            if played.sampleTime < 0 {
                skip = min(frames, Int(-played.sampleTime))
            }
            // Never past the end either. What follows the last frame is the
            // player rendering silence, and drawing it would push the end of
            // the file away from the mark exactly as the pre-roll pushed the
            // beginning.
            let remaining = fileFrames > 0 ? fileFrames - fileFramesFed
                                           : frames - skip
            take = min(frames - skip, max(0, remaining))
            guard take > 0 else { return }
            fileFramesFed += take
            ended = fileFrames > 0 && fileFramesFed >= fileFrames
        }

        let ch = Int(buf.format.channelCount)
        if ch == 1 {
            feedMono(channels[0] + skip, frames: take)
        } else {
            if monoScratch.count < take {
                // Only grows on a format change, not per buffer.
                monoScratch = [Float](repeating: 0, count: take)
            }
            monoScratch.withUnsafeMutableBufferPointer { mono in
                guard let base = mono.baseAddress else { return }
                let scale = 1.0 / Float(ch)
                for i in 0..<take { base[i] = channels[0][skip + i] }
                for k in 1..<ch {
                    let src = channels[k]
                    for i in 0..<take { base[i] += src[skip + i] }
                }
                for i in 0..<take { base[i] *= scale }
                feedMono(base, frames: take)
            }
        }

        // Published last, and that ordering is the point of it. Set before the
        // cascade ran, the main thread could see the boundary, mark and freeze
        // while the columns for this final chunk were still being made -- and
        // a frozen view drains and discards them, putting the green line short
        // by a buffer. Intermittently, which is worse than the constant error
        // this method exists to remove.
        //
        // Program order, not a barrier: the ring's own release store sits
        // inside `process`, and a plain store after it is not formally ordered
        // against a plain load on the other side. It is the same latitude the
        // meters already take, and the cost of the theoretical reordering is
        // one dropped column rather than anything unsafe -- but it is latitude
        // and not a guarantee, and the difference is worth writing down.
        if ended { fileSamplesEnded = true }
    }

    /// Where both paths meet. Audio thread: no allocation, no locks, no
    /// syscalls -- counting and the cascade, nothing else.
    private func feedMono(_ samples: UnsafePointer<Float>, frames: Int) {
        guard let c = cochlea else { return }
        // Before the cascade, and before `meters.samples` moves: the answer is
        // an offset into the stream as it stood when this buffer arrived. A
        // comparison and a store, so the audio thread stays as it was.
        if firstNonZeroFrame < 0 {
            for i in 0..<frames where samples[i] != 0 {
                firstNonZeroFrame = meters.samples + i
                break
            }
        }
        let t0 = CACurrentMediaTime()
        c.process(samples, count: frames)
        meters.dspSeconds += CACurrentMediaTime() - t0
        meters.samples += frames
        meters.buffers += 1
        meters.lastFrames = frames
    }

    // MARK: - RePlay
    //
    // A second, much simpler graph: one buffer, scheduled whole, through a gain
    // stage to the same output device a file would use. It never coexists with
    // file playback -- the button that starts it is only on screen while live
    // input is frozen -- so the two cannot fight over the device, and the
    // channel map and device selection can be reused as they stand.

    private var replayEngine: AVAudioEngine?
    private var replayNode: AVAudioPlayerNode?
    private var replayGain: AVAudioUnitEQ?
    /// How long the scheduled buffer is, so the caller can tell when the
    /// position has run off the end of it.
    private(set) var replayLength: AVAudioFramePosition = 0

    var isReplaying: Bool { replayNode?.isPlaying ?? false }

    /// Start playing `frames` at `rate`. Returns false if the graph would not
    /// start, in which case nothing is left running.
    func startReplay(_ frames: UnsafeBufferPointer<Float>, rate: Double,
                     gainDB: Double) -> Bool {
        stopReplay()
        guard !frames.isEmpty, rate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                         channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames.count)),
              let dst = buffer.floatChannelData
        else {
            Log.say("REPLAY could not make a \(frames.count)-frame buffer "
                    + "at \(Int(rate)) Hz")
            return false
        }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        guard let src = frames.baseAddress else { return false }
        memcpy(dst[0], src, frames.count * MemoryLayout<Float>.size)

        let e = AVAudioEngine()
        // Before anything is attached or connected, exactly as `startFile`
        // does and for the reason written there: asking for the output node's
        // audio unit is what instantiates it, and the device has to be chosen
        // while it is still stopped. Touching `mainMixerNode` first would
        // connect the mixer to the *default* device's format and then have the
        // device changed underneath it.
        routeOutput(e)

        let node = AVAudioPlayerNode()
        // One band, bypassed. The EQ is here for `globalGain` alone, which is
        // in decibels and can be moved while the sound is running;
        // `AVAudioPlayerNode.volume` would not do, being linear and stopping at
        // unity, and a microphone recording often sits far enough below full
        // scale that the only useful settings are above it. A band count of
        // zero looks tidier and is nowhere documented as legal, and an
        // Objective-C exception out of an initialiser cannot be caught in
        // Swift -- so it is one band that does nothing.
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].bypass = true
        eq.globalGain = Self.replayGainClamp(gainDB)
        e.attach(node)
        e.attach(eq)
        e.connect(node, to: eq, format: format)
        e.connect(eq, to: e.mainMixerNode, format: format)

        e.prepare()
        applyChannelMap(e, quiet: true)
        do {
            try e.start()
        } catch {
            Log.say("REPLAY engine would not start: \(error)")
            return false
        }

        // No completion handler. An `AVAudioPlayerNode` fires pending
        // completions when it is stopped, so a handler is a message from a
        // playback that may already have been replaced -- the same trap the
        // file path is still carrying. The display link is polling the position
        // every frame anyway to move the line, so it can see the end for
        // itself.
        node.scheduleBuffer(buffer, at: nil, options: [])
        node.play()

        replayEngine = e
        replayNode = node
        replayGain = eq
        replayLength = AVAudioFramePosition(frames.count)
        replayStarted = CACurrentMediaTime()
        replaySeconds = Double(frames.count) / rate
        Log.say("REPLAY \(frames.count) frames at \(Int(rate)) Hz, "
                + String(format: "%.1f dB", gainDB))
        return true
    }

    /// When it started and how long it is, so the end can be recognised without
    /// asking the node. See `hasReplayFinished`.
    private var replayStarted: CFTimeInterval = 0
    private var replaySeconds: Double = 0

    func stopReplay() {
        // No early return on `replayEngine`: `isReplaying` is answered by
        // `replayNode`, and a caller that trusted one field while this trusted
        // the other could bounce between here and the delegate's own
        // `stopReplay` without terminating. Idempotent instead.
        let node = replayNode, engineToStop = replayEngine
        // Silence it *now*, synchronously. Taking the graph down blocks, and is
        // therefore deferred below -- but until it has gone the old buffer is
        // still being rendered, and two things depend on the sound stopping
        // when the caller says so rather than when the teardown gets round to
        // it: resuming turns the microphone's recording back on within
        // microseconds of this call, and pressing Play again builds a second
        // graph on the same device. A gain parameter takes effect at the next
        // render quantum, which is a fraction of what either of those would
        // otherwise overlap by.
        replayGain?.globalGain = -96
        replayEngine = nil
        replayNode = nil
        replayGain = nil
        replayLength = 0
        replaySeconds = 0
        guard node != nil || engineToStop != nil else { return }
        // Both of these block until the render thread quiesces, and this is
        // called from the display link -- a user-interactive thread waiting on
        // a default-QoS one, which is the priority inversion the "Hang Risk"
        // diagnostic reports. The references above are cleared synchronously so
        // this object's state is consistent the instant this returns; only the
        // blocking part is handed away, and the captured nodes keep themselves
        // alive until it has finished with them. Same shape as
        // `finishedPlayingFile`, and for the same reason.
        DispatchQueue.global(qos: .utility).async {
            node?.stop()
            engineToStop?.stop()
        }
    }

    /// Move the gain while the sound is running.
    func setReplayGain(_ dB: Double) {
        replayGain?.globalGain = Self.replayGainClamp(dB)
    }

    /// The bottom of the slider's travel is silence, not the quietest audible
    /// setting: a volume control that cannot reach zero is not a volume
    /// control. Written once so the live path and the starting path cannot
    /// disagree about where that point is.
    private static func replayGainClamp(_ dB: Double) -> Float {
        if dB <= Settings.replayGainRange.lowerBound + 0.001 { return -96 }
        return Float(min(max(dB, -96), 24))
    }

    /// How many frames of the buffer have been played, or nil when there is
    /// nothing playing or the node has not yet rendered.
    var replayFramePosition: AVAudioFramePosition? {
        guard let node = replayNode, node.isPlaying,
              let t = node.lastRenderTime,
              let p = node.playerTime(forNodeTime: t),
              p.isSampleTimeValid
        else { return nil }
        return max(0, p.sampleTime)
    }

    /// Whether the sound has run out.
    ///
    /// Wall clock, not the node. `AVAudioPlayerNode` can stop vending a player
    /// time once its last scheduled buffer has drained, and the position is the
    /// only other thing that would say the playback was over -- so a playback
    /// left to finish by itself could hang with the line parked on the picture
    /// and the button still saying Stop. The clock cannot fail that way. The
    /// margin covers the output device's own buffering.
    var hasReplayFinished: Bool {
        guard replayEngine != nil, replaySeconds > 0 else { return false }
        return CACurrentMediaTime() - replayStarted > replaySeconds + 0.25
    }
}

/// The audio behind the picture.
///
/// Holds the samples the display was drawn from, and the arithmetic that turns
/// a column of the picture into a position in them. Filled on the display
/// link, from the engine's capture ring, so nothing here runs on the audio
/// thread and nothing here has to be real-time safe.
///
/// See REPLAY-DESIGN.md for why the mapping is by engine column rather than by
/// elapsed time.
final class ReplayRecorder {

    /// One stretch of recording at one column rate.
    ///
    /// A list of these rather than a single anchor, because two ordinary
    /// actions break the correspondence without wiping the picture. Changing
    /// the Speed detent changes how much audio a column stands for, and the
    /// picture deliberately keeps what is already drawn at the old scale.
    /// Resuming after a pause starts recording again after an interval that is
    /// in neither the picture nor the ring. Either way, everything drawn before
    /// the change still has to map correctly, so the old terms are kept rather
    /// than replaced.
    private struct Segment {
        /// First engine column this segment describes.
        var column: Int64
        /// Where in the recording that column begins.
        var sample: Int64
        /// Input samples per engine column while it was in force.
        var perColumn: Double
    }

    private var segments: [Segment] = []
    private var samples: [Float] = []
    /// Stream position of `samples[0]`: everything older has been trimmed.
    private var base: Int64 = 0
    /// Total samples ever taken, so a position means the same thing forever.
    private(set) var written: Int64 = 0
    private(set) var rate: Double = 0

    var isEmpty: Bool { samples.isEmpty || segments.isEmpty }

    /// Where the oldest sample still held sits in the stream. What a selection
    /// reaching back further than the recording is clamped to.
    var oldestSample: Int64 { base }

    /// Throw everything away and start again -- a new input device, a new
    /// engine, or a wiped picture.
    func reset(rate: Double) {
        segments.removeAll()
        samples.removeAll()
        base = 0
        written = 0
        self.rate = rate
    }

    /// Begin a new stretch: engine column `column` is the next one that will be
    /// drawn, and it stands for audio that arrived `lagSamples` ago.
    ///
    /// Called when recording starts, when it resumes after a pause, when the
    /// column rate changes, and when the display's lag changes -- which is what
    /// De-skew does, by nearly two hundred milliseconds.
    ///
    /// The lag is folded into the segment's own origin rather than kept as a
    /// term of its own, so every mapping downstream is the same arithmetic it
    /// always was. It can put the origin before the start of the recording,
    /// which is not an error: at the beginning of a stretch the first columns
    /// really were drawn from audio nobody was keeping yet, and the callers
    /// clamp.
    func beginSegment(atColumn column: Int64, perColumn: Double,
                      lagSamples: Int64) {
        guard perColumn > 0 else { return }
        let origin = written - lagSamples
        // A segment that describes no columns yet is replaced rather than
        // stacked: two of them at the same place would only be one, and Speed
        // or De-skew can be changed twice while paused.
        if let last = segments.last, last.column == column {
            segments[segments.count - 1] =
                Segment(column: column, sample: origin, perColumn: perColumn)
            return
        }
        segments.append(Segment(column: column, sample: origin,
                                perColumn: perColumn))
    }

    /// Take what the engine has captured.
    func take(_ buf: UnsafeBufferPointer<Float>) {
        guard !buf.isEmpty else { return }
        samples.append(contentsOf: buf)
        written += Int64(buf.count)
    }

    /// Where an engine column begins, in the recording.
    func sample(forColumn g: Int64) -> Int64? {
        guard let i = segments.lastIndex(where: { $0.column <= g })
        else { return nil }
        let s = segments[i]
        let at = s.sample
            + Int64((Double(g - s.column) * s.perColumn).rounded())
        return at
    }

    /// Drop everything older than engine column `oldest`, which is the
    /// left-hand edge of the picture.
    ///
    /// This is the whole of the memory policy. The recording is as long as the
    /// picture is wide and no longer, so it grows with the Speed setting and
    /// the window and needs no ceiling of its own: the worst case is the
    /// coarsest Speed across the widest window, which is a couple of minutes.
    func trim(olderThan oldest: Int64) {
        guard let cut = sample(forColumn: oldest), cut > base else { return }
        // Amortised. `removeFirst` on an array is a memmove of everything that
        // survives, and this is called on every frame: at the coarsest Speed on
        // a wide window that is tens of megabytes sixty times a second to let
        // go of a few hundred samples. Waiting until a second's worth is dead
        // makes it a hundredth as often for the same ceiling plus one second.
        guard cut - base > Int64(max(rate, 1)) else { return }
        let drop = Int(min(cut - base, Int64(samples.count)))
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        base += Int64(drop)
        // The segment covering the new left edge has to stay; the ones entirely
        // behind it describe audio nobody can reach any more.
        if let keep = segments.lastIndex(where: { $0.column <= oldest }),
           keep > 0 {
            segments.removeFirst(keep)
        }
    }

    /// The audio between two engine columns, exclusive of the last, handed to
    /// `body` where it lies.
    ///
    /// A closure rather than an array: the caller copies straight into whatever
    /// it will play from, where returning `[Float]` meant the selection was
    /// copied twice on one display-link tick -- at the widest window and
    /// coarsest Speed, tens of megabytes each way.
    ///
    /// Returns what `body` returns, or nil when none of the span is still held.
    func withSamples<T>(from lo: Int64, to end: Int64,
                        _ body: (UnsafeBufferPointer<Float>) -> T) -> T? {
        guard end > lo, var b = sample(forColumn: end) else { return nil }
        // The left-hand end is clamped up to the oldest sample still held
        // rather than refused. The picture is deliberately kept across some of
        // the things that restart the recording -- a change of input device, or
        // of ERB -- so for one screen width afterwards the left of the picture
        // is older than anything recorded. Playing what there is of it is the
        // useful answer; refusing the whole selection because its first column
        // predates the recording is not. A span lying *entirely* before the
        // recording still fails, at the guard above.
        let a = sample(forColumn: lo) ?? base

        // A span across a De-skew seam can run backwards. Turning it on holds
        // the picture back, so the stretch after the seam starts from audio the
        // stretch before it already used, and for a selection narrower than the
        // lag the right-hand end names an *earlier* sample than the left. There
        // is no honest span between them. What there is, is the sound the left
        // end names, for as long as the selection is wide on that side of the
        // seam -- which is what a listener reading the left of the picture
        // expects, and is never empty.
        if b <= a, let s = segments.last(where: { $0.column <= lo }) {
            b = a + Int64((Double(end - lo) * s.perColumn).rounded())
        }
        let from = Int(max(0, a - base))
        let to = Int(min(Int64(samples.count), b - base))
        guard to > from else { return nil }
        return samples.withUnsafeBufferPointer { p in
            body(UnsafeBufferPointer(rebasing: p[from..<to]))
        }
    }

    /// The engine column a position in the recording belongs to -- the inverse
    /// of `sample(forColumn:)`, for putting the playback line on the picture.
    ///
    /// Not a search on `sample`, which would be the obvious thing and is wrong.
    /// Segments are ordered by column and monotone in column, but they are
    /// **not** monotone in sample: turning De-skew on holds the picture back by
    /// the apex's travel time, so the stretch that begins at the toggle starts
    /// from audio that the stretch before it has already used. The two really
    /// do overlap -- that is what the seam at the toggle is saying -- and a
    /// search for the last segment starting at or before `at` would jump
    /// forward the instant the new one began.
    ///
    /// So the walk is forward, from the stretch that `from` lies in, and it
    /// steps only when `at` has passed the boundary *expressed in the current
    /// stretch's own terms*. Columns are contiguous across a boundary even when
    /// samples are not, which is what makes that well defined.
    func column(forSample at: Int64, from: Int64) -> Int64? {
        guard let start = segments.lastIndex(where: { $0.column <= from })
        else { return nil }
        var i = start
        while i + 1 < segments.count {
            let s = segments[i], next = segments[i + 1]
            let boundary = s.sample
                + Int64((Double(next.column - s.column) * s.perColumn).rounded())
            guard at >= boundary else { break }
            i += 1
        }
        let s = segments[i]
        let g = s.column
            + Int64((Double(at - s.sample) / s.perColumn).rounded())
        // The line only ever moves forward, and `from` alone does not ensure
        // it. Turning De-skew *off* is the mirror of turning it on: the picture
        // stops being held back, so the audio between the boundary and the new
        // stretch's origin belongs to no column at all, and extrapolating the
        // new stretch's formula backwards over that gap lands inside the
        // previous stretch's columns. Clamping to the stretch's own first
        // column costs nothing in the overlap direction, where the answer is
        // already past it.
        return max(g, s.column, from)
    }
}
