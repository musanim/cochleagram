import CoreAudio

/// Enumerating CoreAudio devices, for capture and for playback.
///
/// Which device is captured matters more than it looks. A virtual or aggregate
/// device can accept the connection, report a plausible format, and then
/// deliver audio at a fraction of real time -- which shows up not as an error
/// but as a cochleagram whose time axis is silently wrong. Hence `summary`,
/// and hence logging every candidate before choosing one.
///
/// Playback needs the list for a different reason. `AVAudioEngine` always opens
/// the *system default* output unless told otherwise, so a listener whose
/// speakers are not the default hears nothing at all and has no way to say so.
struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let sampleRate: Double
    /// Channels in whichever direction this device was listed for.
    let channels: Int
    let bufferFrames: UInt32
    let isDefault: Bool

    var summary: String {
        "\(name) [id \(id)] \(Int(sampleRate)) Hz, \(channels) ch, "
        + "buffer \(bufferFrames) frames"
        + (isDefault ? " (system default)" : "")
    }
}

enum AudioDevices {

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope
                                    = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // Concrete accessors rather than one generic helper. Taking `&out` on an
    // unconstrained T is rejected: the compiler cannot know the type is plain
    // old data rather than something containing an object reference, and
    // handing CoreAudio a pointer to a reference-holding value would be a real
    // bug. Spelling out the two POD types we actually read avoids the question.

    private static func uint32Value(_ id: AudioObjectID,
                                    _ addr: AudioObjectPropertyAddress)
    -> UInt32? {
        var addr = addr
        var out: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = withUnsafeMutablePointer(to: &out) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? out : nil
    }

    private static func doubleValue(_ id: AudioObjectID,
                                    _ addr: AudioObjectPropertyAddress)
    -> Double? {
        var addr = addr
        var out: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let err = withUnsafeMutablePointer(to: &out) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? out : nil
    }

    private static func string(_ id: AudioObjectID,
                               _ selector: AudioObjectPropertySelector)
    -> String? {
        var addr = address(selector)
        var out: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &out) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? (out as String?) : nil
    }

    private static func channelCount(_ id: AudioDeviceID,
                                     _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static var defaultInputID: AudioDeviceID? {
        uint32Value(AudioObjectID(kAudioObjectSystemObject),
                    address(kAudioHardwarePropertyDefaultInputDevice))
    }

    static var defaultOutputID: AudioDeviceID? {
        uint32Value(AudioObjectID(kAudioObjectSystemObject),
                    address(kAudioHardwarePropertyDefaultOutputDevice))
    }

    /// Every device that can capture.
    static func inputs() -> [AudioDevice] {
        devices(scope: kAudioDevicePropertyScopeInput, defaultID: defaultInputID)
    }

    /// Every device that can play.
    static func outputs() -> [AudioDevice] {
        devices(scope: kAudioDevicePropertyScopeOutput, defaultID: defaultOutputID)
    }

    /// The device with this UID, or nil if it has been unplugged.
    ///
    /// UIDs rather than `AudioDeviceID`s are what get remembered between
    /// launches: an ID is assigned when a device appears and is not the same
    /// number after a reboot or a replug, so a stored one would eventually
    /// name whatever happened to inherit it.
    static func device(uid: String, outputs wantOutputs: Bool) -> AudioDevice? {
        guard !uid.isEmpty else { return nil }
        return (wantOutputs ? outputs() : inputs()).first { $0.uid == uid }
    }

    private static func devices(scope: AudioObjectPropertyScope,
                                defaultID: AudioDeviceID?) -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            let channels = channelCount(id, scope)
            guard channels > 0 else { return nil }
            // Global scope for these two: unlike the stream configuration,
            // they are properties of the device rather than of a direction,
            // and a driver that checks the scope answers
            // `kAudioHardwareUnknownPropertyError` to a scoped request -- which
            // the `?? 0` would then turn into a summary reading "0 Hz, buffer
            // 0 frames" instead of an error.
            let rate = doubleValue(id,
                address(kAudioDevicePropertyNominalSampleRate)) ?? 0
            let frames = uint32Value(id,
                address(kAudioDevicePropertyBufferFrameSize)) ?? 0
            return AudioDevice(
                id: id,
                name: string(id, kAudioObjectPropertyName) ?? "Device \(id)",
                uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                sampleRate: rate,
                channels: channels,
                bufferFrames: frames,
                isDefault: id == defaultID)
        }
    }

    static func logAll() {
        let ins = inputs()
        Log.say("DEVICES \(ins.count) input device(s):")
        for d in ins { Log.say("   \(d.summary)") }
        let outs = outputs()
        Log.say("DEVICES \(outs.count) output device(s):")
        for d in outs { Log.say("   \(d.summary)") }
    }
}
