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
        node.installTap(onBus: 0, bufferSize: 512,
                        format: format) { [weak self] buf, _ in
            self?.feed(buf)
        }
        tappedNode = node
        e.prepare()
        applyChannelMap(e, quiet: true)
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
        let node = player, engineToStop = engine, tapped = tappedNode
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
            tapped?.removeTap(onBus: 0)
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
    private func feed(_ buf: AVAudioPCMBuffer) {
        guard let channels = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return }
        let ch = Int(buf.format.channelCount)

        if ch == 1 {
            feedMono(channels[0], frames: frames)
            return
        }
        if monoScratch.count < frames {
            // Only grows on a format change, not per buffer.
            monoScratch = [Float](repeating: 0, count: frames)
        }
        monoScratch.withUnsafeMutableBufferPointer { mono in
            guard let base = mono.baseAddress else { return }
            let scale = 1.0 / Float(ch)
            for i in 0..<frames { base[i] = channels[0][i] }
            for k in 1..<ch {
                let src = channels[k]
                for i in 0..<frames { base[i] += src[i] }
            }
            for i in 0..<frames { base[i] *= scale }
            feedMono(base, frames: frames)
        }
    }

    /// Where both paths meet. Audio thread: no allocation, no locks, no
    /// syscalls -- counting and the cascade, nothing else.
    private func feedMono(_ samples: UnsafePointer<Float>, frames: Int) {
        guard let c = cochlea else { return }
        let t0 = CACurrentMediaTime()
        c.process(samples, count: frames)
        meters.dspSeconds += CACurrentMediaTime() - t0
        meters.samples += frames
        meters.buffers += 1
        meters.lastFrames = frames
    }
}
