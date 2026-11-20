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
            print("Audio buffer, microphone selection and Vowen disconnect tests passed.")
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

// Only one copy runs at a time.
let bundleID = Bundle.main.bundleIdentifier ?? "com.stopyapping.app"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty { exit(0) }

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
