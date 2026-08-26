import AudioToolbox
import CoreAudio
import Foundation

/// Live capture straight from a HAL input unit.
///
/// This replaced an `AVAudioEngine` graph that was measured delivering **0.29x
/// real time** -- three callbacks a second carrying 4410 frames each. Seventy
/// percent of the audio never arrived, which made the time axis wrong by a
/// factor of three, the scrolling lurch three times a second, and the latency
/// wander between half a second and a second. An earlier attempt to fix that
/// by giving the input node a downstream connection moved the figure from
/// 0.32x to 0.29x, which is to say not at all.
///
/// The trouble is structural rather than a misconfiguration. `AVAudioEngine`
/// drives its graph from the *output* device, so captured audio has to cross
/// the boundary between two independently clocked devices before a tap can see
/// it, and the engine chooses the buffer size. Neither is negotiable through
/// its API.
///
/// AUHAL has none of that. It is bound to one device, driven by that device's
/// own clock, with no output side at all -- which suits a display that never
/// wanted to make a sound. The buffer size is ours to ask for, and 256 frames
/// is 5.8 ms at 44.1 kHz.
final class InputUnit {

    private var unit: AudioUnit?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var listCapacityFrames = 0

    /// Mono downmix, preallocated. The render callback must not allocate.
    private var mono: UnsafeMutablePointer<Float>?
    private var monoCapacity = 0

    private(set) var sampleRate: Double = 0
    private(set) var channels = 0
    private(set) var deviceID: AudioDeviceID = 0
    /// What the device actually agreed to, which need not be what was asked.
    private(set) var bufferFrames: UInt32 = 0

    /// Called on the audio thread with mono samples. Must not allocate, lock,
    /// or touch the display.
    ///
    /// A Swift closure on a real-time thread is a considered risk: the call
    /// itself is a function pointer plus a context, but ARC may retain and
    /// release captured references around it. Those are lock-free atomics
    /// rather than allocations, so the cost is bounded and small. Capture
    /// `unowned` and keep the body allocation-free and it behaves.
    var onAudio: ((UnsafePointer<Float>, Int) -> Void)?

    /// Render failures, for the log. Should stay at zero.
    private(set) var renderErrors: UInt64 = 0

    /// Audio that never arrived: how many frames are missing, and how many
    /// separate holes they are missing from.
    ///
    /// Not the same fault as slow delivery, and not measurable the same way.
    /// `Meters.samples` falling short of the sample rate says the last second
    /// was thin and cannot say when; this is found at the join itself, which
    /// is the only form of the news the picture can act on.
    ///
    /// Monotonic, and meant to be read by comparison rather than subtraction:
    /// a replaced unit starts again at zero, so a remembered value can be
    /// larger than the current one.
    private(set) var droppedFrames: UInt64 = 0
    private(set) var dropouts: UInt64 = 0

    /// Where the next buffer should begin on the device's own sample clock.
    ///
    /// NaN when there is no expectation to hold the next buffer to: before the
    /// first buffer of a run, and after any buffer that arrived without a
    /// valid sample time. A sentinel rather than a negative number because a
    /// sample clock is not required to start at zero, and "no run yet" and
    /// "the clock is below zero" are different claims.
    ///
    /// Written on the audio thread, and on the main thread only in `start`,
    /// where the IO thread is not yet running.
    private var expectedSampleTime: Double = .nan

    deinit { close() }

    // MARK: - setup

    /// Build and configure the unit, and find out what format the device
    /// actually speaks. Kept separate from `start` so the caller can build a
    /// cochlea for the real sample rate before any audio arrives -- the
    /// callback fires almost immediately once started.
    func open(deviceID id: AudioDeviceID, preferredFrames: UInt32 = 256) throws {
        close()

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioUnitError("No HAL output component. This is a system "
                                 + "component; its absence means something is "
                                 + "very wrong.", noErr)
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(component, &au), "create the unit")
        guard let au else { throw AudioUnitError("Unit was not created.", noErr) }
        unit = au
        deviceID = id

        // Bus 1 is input, bus 0 is output. Turning the output off is the point:
        // there is no sound to make, and an output would drag a second device
        // and a second clock into the path.
        var on: UInt32 = 1
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &on,
                                       UInt32(MemoryLayout<UInt32>.size)),
                  "enable input")
        var off: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &off,
                                       UInt32(MemoryLayout<UInt32>.size)),
                  "disable output")

        // The device must be bound before any format is read: until then the
        // unit reports the default device's format, not this one's.
        var dev = id
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "select the device")

        requestBufferFrames(au, id, preferredFrames)

        // What the hardware is really producing.
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 1, &hw, &size),
                  "read the hardware format")
        guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0 else {
            throw AudioUnitError("The device reports no input format.", noErr)
        }
        sampleRate = hw.mSampleRate
        channels = Int(hw.mChannelsPerFrame)

        // Client format: float32, non-interleaved, at the hardware's own rate
        // and channel count. Asking for a different sample rate here would put
        // a converter in the path for nothing -- the cascade resamples anyway,
        // and it knows what it is doing to the phase.
        var client = AudioStreamBasicDescription(
            mSampleRate: hw.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                        | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &client,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "set the client format")

        // Ceiling on frames per callback. Set it high and allocate for it: a
        // device handing over more frames than we have room for would
        // otherwise be discovered on the audio thread, where there is nothing
        // useful to be done about it. 8192 is two seconds of slack at any
        // buffer size a device will agree to.
        var slice: UInt32 = 8192
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
                                       kAudioUnitScope_Global, 0, &slice,
                                       UInt32(MemoryLayout<UInt32>.size)),
                  "set the maximum slice")
        allocateBuffers(frames: Int(slice), channels: channels)

        var callback = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "install the input callback")

        try check(AudioUnitInitialize(au), "initialise the unit")

        // Read the buffer size only now. The HAL renegotiates when a new IO
        // client appears, so anything read before initialising describes the
        // device as it was without us in it.
        var actual: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioUnitGetProperty(au, kAudioDevicePropertyBufferFrameSize,
                                kAudioUnitScope_Global, 0, &actual,
                                &size) == noErr, actual > 0 {
            bufferFrames = actual
        }

        let ms = String(format: "%.1f",
                        Double(bufferFrames) * 1000 / sampleRate)
        Log.say("AUHAL open: device \(id), \(Int(sampleRate)) Hz, "
                + "\(channels) ch, buffer \(bufferFrames) frames (\(ms) ms), "
                + "slice ceiling \(slice)")
    }

    func start() throws {
        guard let au = unit else {
            throw AudioUnitError("Start before open.", noErr)
        }
        // A stopped unit's clock is not the running one's, so the first buffer
        // after a start begins a run rather than continuing the last. Safe to
        // write here: the IO thread is not running until the line below.
        expectedSampleTime = .nan
        try check(AudioOutputUnitStart(au), "start the unit")
        Log.say("AUHAL started")
    }

    /// Stops and tears down. `AudioOutputUnitStop` does not return until the
    /// device's IO thread has finished, so it is safe to free afterwards.
    func close() {
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            unit = nil
        }
        onAudio = nil
        freeBuffers()
        sampleRate = 0
        channels = 0
        bufferFrames = 0
    }

    // MARK: - buffers

    private func allocateBuffers(frames: Int, channels: Int) {
        freeBuffers()
        let list = AudioBufferList.allocate(maximumBuffers: max(channels, 1))
        for i in 0..<list.count {
            let bytes = frames * MemoryLayout<Float>.size
            list[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytes),
                mData: UnsafeMutableRawPointer.allocate(
                    byteCount: bytes, alignment: MemoryLayout<Float>.alignment))
        }
        bufferList = list
        listCapacityFrames = frames

        mono = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        mono?.initialize(repeating: 0, count: frames)
        monoCapacity = frames
    }

    private func freeBuffers() {
        if let list = bufferList {
            for i in 0..<list.count { list[i].mData?.deallocate() }
            free(list.unsafeMutablePointer)
            bufferList = nil
        }
        listCapacityFrames = 0
        if let m = mono {
            m.deinitialize(count: monoCapacity)
            m.deallocate()
            mono = nil
        }
        monoCapacity = 0
    }

    // MARK: - audio thread

    /// Audio thread. Plain increments, for the reason `AudioSource.Meters`
    /// gives at length: naturally aligned words, read on the main thread for a
    /// log line and a mark on the picture, and a lock here would be a real bug
    /// bought with a cosmetic one.
    private func noteDrop(_ frames: UInt64) {
        guard frames > 0 else { return }
        droppedFrames &+= frames
        dropouts &+= 1
    }

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ timeStamp: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32,
                            _ frames: UInt32) -> OSStatus {
        guard let au = unit, let list = bufferList, let mono else { return noErr }
        let n = Int(frames)

        // Audio that never arrived, found by asking the device's own clock
        // whether this buffer continues the last one. A few comparisons and a
        // store, which is what this thread can afford, and the only witness
        // there is: samples lost before the callback are not thin, they are
        // absent, and nothing downstream will ever see them.
        let ts = timeStamp.pointee
        if ts.mFlags.contains(.sampleTimeValid) {
            if !expectedSampleTime.isNaN {
                let gap = ts.mSampleTime - expectedSampleTime
                // Forwards, at least a whole frame, and bounded. Sample times
                // are integral on a HAL device, so a whole frame is the
                // smallest step there is; the floor absorbs sub-frame creep on
                // a clock that is not integral, and a clock that stepped
                // backwards is not reporting a hole.
                //
                // The ceiling is not fussiness. `mSampleTime` is a Float64
                // from a driver, and a driver that re-bases its clock hands
                // back a difference that is not a hole but a number -- and a
                // Double past `UInt64.max` traps the conversion, which on this
                // thread is an abort. 1e12 frames is about 250 days of audio.
                if gap >= 1, gap < 1e12 { noteDrop(UInt64(gap)) }
            }
            expectedSampleTime = ts.mSampleTime + Double(n)
        } else {
            // No clock, no expectation. Left as it was, the next buffer that
            // does carry a timestamp would show a gap the width of everything
            // skipped here and report audio that in fact arrived.
            expectedSampleTime = .nan
        }

        guard n > 0, n <= listCapacityFrames else {
            renderErrors &+= 1
            // A buffer bigger than the one allocated for it is audio lost as
            // surely as a hole in the device's clock, and this is the only
            // place it can be counted: the expectation above has already been
            // advanced past these frames, or invalidated, so no later buffer
            // will report them.
            noteDrop(UInt64(n))
            return noErr
        }

        // AudioUnitRender overwrites mDataByteSize with what it delivered, so
        // the advertised capacity has to be restored before every call or the
        // second render is told there is room for nothing.
        let bytes = UInt32(n * MemoryLayout<Float>.size)
        for i in 0..<list.count { list[i].mDataByteSize = bytes }

        let err = AudioUnitRender(au, flags, timeStamp, bus, frames,
                                  list.unsafeMutablePointer)
        guard err == noErr else {
            renderErrors &+= 1
            noteDrop(UInt64(n))
            return err
        }

        guard let first = list[0].mData?.assumingMemoryBound(to: Float.self)
        else { return noErr }

        if list.count == 1 {
            onAudio?(first, n)             // already mono; no copy
            return noErr
        }
        let scale = 1.0 / Float(list.count)
        for i in 0..<n { mono[i] = first[i] }
        for k in 1..<list.count {
            guard let src = list[k].mData?.assumingMemoryBound(to: Float.self)
            else { continue }
            for i in 0..<n { mono[i] += src[i] }
        }
        for i in 0..<n { mono[i] *= scale }
        onAudio?(mono, n)
        return noErr
    }

    // MARK: - device buffer size

    /// Ask for a small IO buffer. Latency starts here: whatever the device
    /// agrees to, the display cannot beat it.
    ///
    /// Set through the *unit* rather than on the device object. The buffer
    /// size is a property of the device, shared with every other process using
    /// it, so setting it directly would impose our interrupt rate on everyone
    /// else and never give it back. Going through the unit registers the
    /// request as this client's preference and lets the HAL arbitrate.
    ///
    /// What comes back is read after `AudioUnitInitialize`, not here, because
    /// adding an IO client is itself what triggers the renegotiation.
    private func requestBufferFrames(_ au: AudioUnit,
                                     _ id: AudioDeviceID,
                                     _ want: UInt32) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var target = want
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &range) == noErr {
            target = min(max(want, UInt32(range.mMinimum)),
                         UInt32(range.mMaximum))
            if target != want {
                Log.say("AUHAL device allows \(UInt32(range.mMinimum))-"
                        + "\(UInt32(range.mMaximum)) frames; asking for "
                        + "\(target) rather than \(want)")
            }
        }
        bufferFrames = target

        var value = target
        let err = AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize,
                                       kAudioUnitScope_Global, 0, &value,
                                       UInt32(MemoryLayout<UInt32>.size))
        if err != noErr {
            Log.say("AUHAL could not ask for a \(target)-frame buffer "
                    + "(\(fourCC(err))); taking whatever the device prefers")
        }
    }

    // MARK: - errors

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        close()
        throw AudioUnitError("Could not \(what).", status)
    }
}

/// Non-capturing, so it converts to a C function pointer. The instance comes
/// back through the refCon rather than being captured, which is the only way a
/// `@convention(c)` callback can reach an object at all.
private let inputRenderCallback: AURenderCallback = {
    refCon, flags, timeStamp, bus, frames, _ in
    let me = Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue()
    return me.render(flags, timeStamp, bus, frames)
}

struct AudioUnitError: LocalizedError {
    let message: String
    let status: OSStatus
    init(_ message: String, _ status: OSStatus) {
        self.message = message
        self.status = status
    }
    var errorDescription: String? {
        status == noErr ? message : "\(message) (\(fourCC(status)))"
    }
}

/// CoreAudio reports most failures as four packed characters, which are far
/// easier to look up than the signed integer they arrive as.
func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF),
                 UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return "OSStatus \(status)"
}
