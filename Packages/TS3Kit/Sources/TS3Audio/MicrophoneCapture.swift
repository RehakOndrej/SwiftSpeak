@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures from one specific input device with a Core Audio unit of its own.
///
/// `AVAudioEngine.inputNode` always opens the system default microphone first, even when another
/// device is chosen right after. With AirPods as the default that alone switches them to call mode
/// (24 kHz, mono) and sets off a storm of device changes that can leave AVAudioEngine stuck. This
/// unit is bound to its device before it is initialised, so no other device is ever touched.
final class MicrophoneCapture: @unchecked Sendable {
    private let unit: AudioUnit
    private let format: AVAudioFormat
    /// Filled by the audio thread on every callback.
    private let scratch: AVAudioPCMBuffer
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    /// Buffers are handed over here, off the real-time thread, in order.
    private let delivery = DispatchQueue(label: "ts3.audio.capture", qos: .userInteractive)
    private var started = false

    /// `onBuffer` gets the device's own sample rate and channel count as non-interleaved floats.
    init(device: AudioDeviceID, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw Self.error(-1, "No audio input unit") }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "Could not create the audio input unit")
        guard let instance else { throw Self.error(-1, "No audio input unit") }

        do {
            let size32 = UInt32(MemoryLayout<UInt32>.size)
            var on: UInt32 = 1, off: UInt32 = 0
            try Self.check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, size32),
                           "Could not enable audio input")
            try Self.check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, size32),
                           "Could not disable audio output on the input unit")
            var id = device
            try Self.check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                                UInt32(MemoryLayout<AudioDeviceID>.size)),
                           "Could not select the microphone")

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size),
                           "Could not read the microphone's format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let client = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                             channels: hardware.mChannelsPerFrame, interleaved: false),
                  let scratch = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: 16_384) else {
                throw Self.error(-1, "No usable input device")
            }
            var clientDescription = client.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientDescription, size),
                           "Could not use the microphone's format")
            unit = instance
            format = client
            self.scratch = scratch
            self.onBuffer = onBuffer
        } catch {
            AudioComponentInstanceDispose(instance)
            throw error
        }
    }

    deinit {
        stop()
        AudioComponentInstanceDispose(unit)
    }

    func start() throws {
        guard !started else { return }
        var callback = AURenderCallbackStruct(inputProc: { context, flags, timestamp, bus, frames, _ in
            Unmanaged<MicrophoneCapture>.fromOpaque(context).takeUnretainedValue()
                .render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                            UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                       "Could not listen to the microphone")
        try Self.check(AudioUnitInitialize(unit), "Could not open the microphone")
        let status = AudioOutputUnitStart(unit)
        if status != noErr {
            AudioUnitUninitialize(unit)
            throw Self.error(status, "Could not start the microphone")
        }
        started = true
    }

    /// No callbacks arrive after this returns.
    func stop() {
        guard started else { return }
        started = false
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
    }

    /// Audio thread. Copies what the device delivered and passes it on; the copy and the hand-over
    /// allocate, which is acceptable for capture (a late buffer is absorbed further on).
    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32) -> OSStatus {
        guard frames <= scratch.frameCapacity else { return noErr }
        scratch.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, scratch.mutableAudioBufferList)
        guard status == noErr, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let from = scratch.floatChannelData, let to = copy.floatChannelData else { return status }
        copy.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            to[channel].update(from: from[channel], count: Int(frames))
        }
        let onBuffer = self.onBuffer
        delivery.async { onBuffer(copy) }
        return noErr
    }

    private static func check(_ status: OSStatus, _ message: String) throws {
        if status != noErr { throw error(status, message) }
    }

    private static func error(_ status: OSStatus, _ message: String) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(message) (\(status))"])
    }
}
