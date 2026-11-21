import CoreAudio
import Foundation
import os

/// Mono delay line between the real microphone and the virtual one.
/// While blocked it drops everything, and it clears the backlog whenever the mute state flips,
/// so nothing said before or during dictation can leak out afterwards.
final class DelayedMicrophone: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private var head = 0   // index of the oldest sample
    private var count = 0
    private let delayFrames: Int
    private let maximumLead: Int
    private var blocked: Bool

    init(sampleRate: Double, delayMilliseconds: Int, initiallyBlocked: Bool) {
        capacity = max(1024, Int(sampleRate * 2))
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        delayFrames = Int(sampleRate * Double(delayMilliseconds) / 1000)
        maximumLead = delayFrames + Int(sampleRate * 0.12)
        blocked = initiallyBlocked
    }

    deinit { samples.deallocate() }

    func setBlocked(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard blocked != value else { return }
        head = 0; count = 0
        blocked = value
    }

    func write(_ source: UnsafePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !blocked else { return }
        var offset = 0
        var remaining = frames
        if remaining > capacity { offset = remaining - capacity; remaining = capacity }
        // Overflow: drop the oldest samples.
        let overflow = count + remaining - capacity
        if overflow > 0 { head = (head + overflow) % capacity; count -= overflow }
        var tail = (head + count) % capacity
        while remaining > 0 {
            let chunk = min(remaining, capacity - tail)
            (samples + tail).update(from: source + offset, count: chunk)
            offset += chunk; remaining -= chunk; count += chunk
            tail = (tail + chunk) % capacity
        }
    }

    /// Always fills `frames` samples, padding with silence.
    func read(into destination: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        // Drop an old backlog after a clock stall or when the input runs faster than the output.
        if count > maximumLead {
            let excess = count - delayFrames - frames
            if excess > 0 { head = (head + excess) % capacity; count -= excess }
        }
        let ready = blocked ? 0 : min(max(0, count - delayFrames), frames)
        var copied = 0
        while copied < ready {
            let chunk = min(ready - copied, capacity - head)
            (destination + copied).update(from: samples + head, count: chunk)
            copied += chunk
            head = (head + chunk) % capacity
            count -= chunk
        }
        if copied < frames { (destination + copied).update(repeating: 0, count: frames - copied) }
    }
}

/// Downward expander that pushes steady background hiss down while you are silent.
/// It learns the noise floor on its own and opens within a couple of milliseconds when you speak.
final class NoiseGate {
    private let sampleRate: Double
    private let closedGain: Float = 0.1            // -20 dB while silent
    private var noiseFloor: Float = 0.001          // running estimate of background RMS
    private var gain: Float = 1
    private var holdFrames = 0
    private let attack: Float
    private let release: Float
    private let holdLength: Int

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        attack = 1 - exp(-1 / Float(sampleRate * 0.002))
        release = 1 - exp(-1 / Float(sampleRate * 0.12))
        holdLength = Int(sampleRate * 0.25)
    }

    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in 0..<frames { sum += samples[i] * samples[i] }
        let level = (sum / Float(frames)).squareRoot()

        // The floor falls quickly to quiet blocks and creeps up slowly (about 1 dB/s),
        // so speech never gets mistaken for background noise.
        let seconds = Float(Double(frames) / sampleRate)
        if level < noiseFloor { noiseFloor += (level - noiseFloor) * min(1, seconds * 20) }
        else { noiseFloor *= 1 + 0.12 * seconds }
        noiseFloor = min(max(noiseFloor, 0.00001), 0.05)

        let threshold = max(noiseFloor * 3.2, 0.0003)   // about 10 dB above the floor
        if level > threshold { holdFrames = holdLength } else { holdFrames = max(0, holdFrames - frames) }
        let target: Float = holdFrames > 0 ? 1 : closedGain
        let speed = target > gain ? attack : release
        for i in 0..<frames {
            gain += (target - gain) * speed
            samples[i] *= gain
        }
    }
}

struct AudioEndpoint: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

enum CoreAudio {
    /// The visible, input-only "Stop Yapping Mic" device that call apps listen to.
    static let virtualMicUID = "StopYapping_UID"
    /// The hidden, output-only twin that Stop Yapping writes into.
    static let virtualFeedUID = "StopYapping_2_UID"

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func allDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func channels(_ id: AudioObjectID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func inputs() -> [AudioEndpoint] {
        allDevices().compactMap { id in
            guard channels(id, input: true) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("StopYapping") else { return nil }
            return AudioEndpoint(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func device(uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func defaultInputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    static func sampleRate(_ id: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    @discardableResult
    static func setSampleRate(_ id: AudioObjectID, _ rate: Double) -> Bool {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    static func isAlive(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func isRunning(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsRunning)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr && running != 0
    }

    /// Prefers the saved microphone, then the system default, then the only microphone available.
    static func chooseInput(_ inputs: [AudioEndpoint], selectedUID: String?, defaultUID: String?) -> AudioEndpoint? {
        if let match = inputs.first(where: { $0.uid == (selectedUID ?? defaultUID) }) { return match }
        return selectedUID == nil && inputs.count == 1 ? inputs[0] : nil
    }
}

struct AudioRouteError: LocalizedError {
    let message: String
    init(_ message: String, _ status: OSStatus = noErr) {
        self.message = status == noErr ? message : "\(message) (\(status))"
    }
    var errorDescription: String? { message }
}

/// Copies the real microphone into the hidden feed device, through the delay line.
final class AudioRoute: @unchecked Sendable {
    let buffer: DelayedMicrophone
    let inputID: AudioObjectID
    let outputID: AudioObjectID
    let inputRate: Double
    let outputRate: Double

    private var inputProc: AudioDeviceIOProcID?
    private var outputProc: AudioDeviceIOProcID?
    private let scratchFrames = 16384
    private let inputScratch: UnsafeMutablePointer<Float>
    private let resampled: UnsafeMutablePointer<Float>
    private let outputScratch: UnsafeMutablePointer<Float>
    private var resamplePosition: Double = 0   // fractional read position, relative to `lastSample`
    private var lastSample: Float = 0
    private var startedAt = Date()
    private let gate: NoiseGate?

    init(input: AudioEndpoint, delayMs: Int, initiallyMuted: Bool, reduceNoise: Bool) throws {
        guard let feed = CoreAudio.device(uid: CoreAudio.virtualFeedUID) else {
            throw AudioRouteError("The Stop Yapping Mic driver is missing")
        }
        inputID = input.id
        outputID = feed
        inputRate = CoreAudio.sampleRate(input.id)
        guard inputRate > 0 else { throw AudioRouteError("The microphone is unavailable") }
        // Match the virtual device to the microphone so no resampling is needed when possible.
        if CoreAudio.sampleRate(feed) != inputRate { CoreAudio.setSampleRate(feed, inputRate) }
        if let mic = CoreAudio.device(uid: CoreAudio.virtualMicUID), CoreAudio.sampleRate(mic) != inputRate {
            CoreAudio.setSampleRate(mic, inputRate)
        }
        outputRate = CoreAudio.sampleRate(feed)
        guard outputRate > 0 else { throw AudioRouteError("The Stop Yapping Mic driver is unavailable") }

        buffer = DelayedMicrophone(sampleRate: outputRate, delayMilliseconds: delayMs, initiallyBlocked: initiallyMuted)
        gate = reduceNoise ? NoiseGate(sampleRate: inputRate) : nil
        inputScratch = .allocate(capacity: scratchFrames)
        resampled = .allocate(capacity: scratchFrames * 4)
        outputScratch = .allocate(capacity: scratchFrames)
    }

    deinit {
        stop()
        inputScratch.deallocate()
        resampled.deallocate()
        outputScratch.deallocate()
    }

    func start() throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&outputProc, outputID, nil) { [unowned self] _, _, _, output, _ in
            self.render(output)
        }
        guard status == noErr else { throw AudioRouteError("Could not open Stop Yapping Mic", status) }
        status = AudioDeviceCreateIOProcIDWithBlock(&inputProc, inputID, nil) { [unowned self] _, input, _, _, _ in
            self.capture(input)
        }
        guard status == noErr else { throw AudioRouteError("Could not open the microphone", status) }
        status = AudioDeviceStart(outputID, outputProc)
        guard status == noErr else { throw AudioRouteError("Could not start Stop Yapping Mic", status) }
        status = AudioDeviceStart(inputID, inputProc)
        guard status == noErr else { throw AudioRouteError("Could not start the microphone", status) }
        startedAt = Date()
    }

    func stop() {
        if let inputProc {
            AudioDeviceStop(inputID, inputProc)
            AudioDeviceDestroyIOProcID(inputID, inputProc)
            self.inputProc = nil
        }
        if let outputProc {
            AudioDeviceStop(outputID, outputProc)
            AudioDeviceDestroyIOProcID(outputID, outputProc)
            self.outputProc = nil
        }
    }

    /// Reports why the route should be rebuilt, if it should.
    var failure: String? {
        if !CoreAudio.isAlive(inputID) { return "The microphone disconnected" }
        if !CoreAudio.isAlive(outputID) { return "Stop Yapping Mic disappeared" }
        if CoreAudio.sampleRate(inputID) != inputRate { return "The microphone changed format" }
        if CoreAudio.sampleRate(outputID) != outputRate { return "Stop Yapping Mic changed format" }
        if Date().timeIntervalSince(startedAt) > 2,
           !CoreAudio.isRunning(inputID) || !CoreAudio.isRunning(outputID) { return "The audio device stopped" }
        return nil
    }

    // MARK: Realtime callbacks

    private func capture(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = min(scratchFrames, Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels)))
        guard frames > 0 else { return }

        // Mix every channel of every stream down to mono.
        inputScratch.update(repeating: 0, count: frames)
        var totalChannels = 0
        for audio in buffers {
            guard let data = audio.mData?.assumingMemoryBound(to: Float.self), audio.mNumberChannels > 0 else { continue }
            let channels = Int(audio.mNumberChannels)
            let available = min(frames, Int(audio.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            for frame in 0..<available {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                inputScratch[frame] += sum
            }
            totalChannels += channels
        }
        guard totalChannels > 0 else { return }
        if totalChannels > 1 {
            let scale = 1 / Float(totalChannels)
            for frame in 0..<frames { inputScratch[frame] *= scale }
        }
        gate?.process(inputScratch, frames: frames)

        if inputRate == outputRate {
            buffer.write(inputScratch, frames: frames)
            return
        }
        // Linear resampling, continuous across callbacks.
        let step = inputRate / outputRate
        var produced = 0
        var position = resamplePosition
        while position < Double(frames) - 1, produced < scratchFrames * 4 {
            let index = Int(position.rounded(.down))
            let fraction = Float(position - Double(index))
            let a = index < 0 ? lastSample : inputScratch[index]
            let b = inputScratch[index + 1]
            resampled[produced] = a + (b - a) * fraction
            produced += 1
            position += step
        }
        resamplePosition = position - Double(frames)
        lastSample = inputScratch[frames - 1]
        buffer.write(resampled, frames: produced)
    }

    private func render(_ list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = min(scratchFrames, Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels)))
        buffer.read(into: outputScratch, frames: frames)
        for audio in buffers {
            guard let data = audio.mData?.assumingMemoryBound(to: Float.self), audio.mNumberChannels > 0 else { continue }
            let channels = Int(audio.mNumberChannels)
            let available = min(frames, Int(audio.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            for frame in 0..<available {
                let sample = outputScratch[frame]
                for channel in 0..<channels { data[frame * channels + channel] = sample }
            }
        }
    }
}
