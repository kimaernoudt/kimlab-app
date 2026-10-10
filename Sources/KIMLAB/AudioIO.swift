import Foundation
import CoreAudio
import AudioToolbox

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let outs: Int
    let ins: Int
}

enum CA {
    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func devices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map {
            AudioDevice(id: $0, name: string($0, kAudioObjectPropertyName), uid: string($0, kAudioDevicePropertyDeviceUID),
                        outs: channels($0, input: false), ins: channels($0, input: true))
        }
    }
    static func string(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
        var addr = address(sel)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var s: Unmanaged<CFString>? = nil
        let err = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        if err != noErr { return "" }
        if let u = s { return u.takeRetainedValue() as String }
        return ""
    }
    static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var n = 0
        for b in abl { n += Int(b.mNumberChannels) }
        return n
    }
    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var sr: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &sr)
        return sr > 0 ? sr : 48000
    }
    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
    static func device(uid: String, input: Bool) -> AudioDeviceID {
        if !uid.isEmpty, let d = devices().first(where: { $0.uid == uid && (input ? $0.ins : $0.outs) > 0 }) { return d.id }
        return defaultDevice(input: input)
    }
    static func floatFormat(_ sr: Double, _ ch: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 32, mReserved: 0)
    }
    static func makeHAL() -> AudioUnit? {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var u: AudioUnit? = nil
        guard AudioComponentInstanceNew(comp, &u) == noErr else { return nil }
        return u
    }
}

typealias AudioBlock = (_ bufs: UnsafeMutableAudioBufferListPointer, _ frames: Int, _ hostTime: UInt64) -> Void

/// Output to one audio device. The render block is called on the audio thread with zeroed, non-interleaved float buffers.
final class HALOutput {
    private var unit: AudioUnit? = nil
    private(set) var sampleRate = 48000.0
    private(set) var channels = 2
    private(set) var deviceID: AudioDeviceID = 0
    var render: AudioBlock? = nil
    var running: Bool { unit != nil }

    func start(device: AudioDeviceID) -> Bool {
        stop()
        guard let au = CA.makeHAL() else { return false }
        var dev = device
        let sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sz) == noErr else {
            AudioComponentInstanceDispose(au); return false
        }
        let sr = CA.sampleRate(device)
        let ch = max(1, CA.channels(device, input: false))
        var fmt = CA.floatFormat(sr, ch)
        _ = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var cb = AURenderCallbackStruct(inputProc: halRenderProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        _ = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        sampleRate = sr; channels = ch; deviceID = device
        guard AudioUnitInitialize(au) == noErr, AudioOutputUnitStart(au) == noErr else {
            AudioComponentInstanceDispose(au); return false
        }
        unit = au
        return true
    }
    func stop() {
        if let au = unit {
            AudioOutputUnitStop(au); AudioUnitUninitialize(au); AudioComponentInstanceDispose(au)
            unit = nil
        }
    }
}

private let halRenderProc: AURenderCallback = { refCon, _, ts, _, frames, ioData in
    let me = Unmanaged<HALOutput>.fromOpaque(refCon).takeUnretainedValue()
    guard let io = ioData else { return noErr }
    let bufs = UnsafeMutableAudioBufferListPointer(io)
    for b in bufs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    if let r = me.render { r(bufs, Int(frames), ts.pointee.mHostTime) }
    return noErr
}

/// Input from one audio device (used for LTC in).
final class HALInput {
    static let maxFrames = 8192
    private var unit: AudioUnit? = nil
    private var bufList: UnsafeMutableAudioBufferListPointer? = nil
    private(set) var sampleRate = 48000.0
    private(set) var channels = 0
    var onAudio: AudioBlock? = nil
    var running: Bool { unit != nil }

    func start(device: AudioDeviceID) -> Bool {
        stop()
        let ch = CA.channels(device, input: true)
        guard ch > 0, let au = CA.makeHAL() else { return false }
        var one: UInt32 = 1, zero: UInt32 = 0
        _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
        _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4)
        var dev = device
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            AudioComponentInstanceDispose(au); return false
        }
        let sr = CA.sampleRate(device)
        var fmt = CA.floatFormat(sr, ch)
        _ = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var cb = AURenderCallbackStruct(inputProc: halInputProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        let bl = AudioBufferList.allocate(maximumBuffers: ch)
        for i in 0..<ch {
            let bytes = HALInput.maxFrames * 4
            bl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: malloc(bytes))
        }
        bufList = bl; sampleRate = sr; channels = ch
        guard AudioUnitInitialize(au) == noErr, AudioOutputUnitStart(au) == noErr else {
            AudioComponentInstanceDispose(au); freeBuffers(); return false
        }
        unit = au
        return true
    }
    func stop() {
        if let au = unit {
            AudioOutputUnitStop(au); AudioUnitUninitialize(au); AudioComponentInstanceDispose(au)
            unit = nil
        }
        freeBuffers()
    }
    private func freeBuffers() {
        if let bl = bufList {
            for b in bl { free(b.mData) }
            free(bl.unsafeMutablePointer)
            bufList = nil
        }
    }
    fileprivate func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) {
        guard let au = unit, let bl = bufList, Int(frames) <= HALInput.maxFrames else { return }
        for i in 0..<bl.count { bl[i].mDataByteSize = frames * 4 }
        if AudioUnitRender(au, flags, ts, bus, frames, bl.unsafeMutablePointer) == noErr, let f = onAudio {
            f(bl, Int(frames), ts.pointee.mHostTime)
        }
    }
}

private let halInputProc: AURenderCallback = { refCon, flags, ts, bus, frames, _ in
    let me = Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue()
    me.pull(flags, ts, bus, frames)
    return noErr
}
