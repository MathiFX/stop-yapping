import AppKit

enum SelfTest {
    static func run() -> Int32 {
        do {
            // 8 kHz, 100 ms delay = 800 frames.
            let gate = DelayedMicrophone(sampleRate: 8000, delayMilliseconds: 100, initiallyBlocked: false)
            let normal = [Float](repeating: 0.12, count: 800)
            let protectedSpeech = [Float](repeating: 0.42, count: 800)
            var read = [Float](repeating: 1, count: 800)

            gate.write(normal, frames: 800)
            gate.read(into: &read, frames: 800)
            try require(read.allSatisfy { $0 == 0 }, "Audio escaped the initial delay.")

            gate.write(protectedSpeech, frames: 800)
            gate.read(into: &read, frames: 800)
            try require(read == normal, "Normal audio did not arrive after the configured delay.")

            gate.setBlocked(true)
            gate.write(protectedSpeech, frames: 800)
            gate.read(into: &read, frames: 800)
            try require(read.allSatisfy { $0 == 0 }, "Audio escaped while muted.")

            gate.setBlocked(false)
            gate.write(normal, frames: 800)
            gate.read(into: &read, frames: 800)
            try require(read.allSatisfy { $0 == 0 }, "Audio queued before or during mute survived.")
            gate.write(normal, frames: 800)
            gate.read(into: &read, frames: 800)
            try require(read == normal, "Normal audio did not resume after mute.")

            // Steady hiss gets pushed down; speech passes at full level.
            let hissGate = NoiseGate(sampleRate: 48000)
            var block = [Float](repeating: 0, count: 480)
            var hissOut: Float = 0
            for _ in 0..<300 {   // 3 s of hiss
                for i in 0..<480 { block[i] = Float.random(in: -0.0015...0.0015) }
                block.withUnsafeMutableBufferPointer { hissGate.process($0.baseAddress!, frames: 480) }
                hissOut = block.map { abs($0) }.max() ?? 0
            }
            try require(hissOut < 0.0004, "Background hiss was not reduced (\(hissOut)).")
            var speechOut: Float = 0
            for n in 0..<20 {   // 200 ms of speech
                for i in 0..<480 { block[i] = 0.2 * sin(Float(n * 480 + i) * 2 * .pi * 220 / 48000) }
                block.withUnsafeMutableBufferPointer { hissGate.process($0.baseAddress!, frames: 480) }
                if n > 0 { speechOut = max(speechOut, block.map { abs($0) }.max() ?? 0) }
            }
            try require(speechOut > 0.19, "Speech was attenuated (\(speechOut)).")

            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathComponent("server.json")
            try require(VowenMonitor(discoveryURL: missing).read() == .unavailable,
                        "A missing Vowen endpoint must release the mute.")

            let usb = AudioEndpoint(id: 1, uid: "usb", name: "USB microphone")
            let headset = AudioEndpoint(id: 2, uid: "headset", name: "Headset microphone")
            try require(CoreAudio.chooseInput([usb, headset], selectedUID: nil, defaultUID: "headset") == headset,
                        "The system default was ignored.")
            try require(CoreAudio.chooseInput([usb, headset], selectedUID: "usb", defaultUID: "headset") == usb,
                        "The selected microphone was ignored.")
            try require(CoreAudio.chooseInput([usb], selectedUID: nil, defaultUID: "cable") == usb,
                        "The only available input was ignored.")
            try require(CoreAudio.chooseInput([usb, headset], selectedUID: nil, defaultUID: "cable") == nil,
                        "An ambiguous source was selected.")
            try require(CoreAudio.chooseInput([headset], selectedUID: "usb", defaultUID: "headset") == nil,
                        "A disconnected source was silently switched.")
            print("Audio buffer, hiss reduction, microphone selection and Vowen disconnect tests passed.")
            return 0
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AudioRouteError(message) }
    }
}

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

Log.start()
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
Log.write("Starting Stop Yapping \(version)\(LoginService.isAgentInstance ? " (login agent)" : "")")

// Only one copy runs at a time.
if !LoginService.shouldKeepRunning() { exit(0) }

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
