import AppKit
import ServiceManagement

/// Runs Stop Yapping as a launchd agent: it opens at login and comes back on its own after a crash.
/// Quitting from the menu exits cleanly, so launchd leaves it closed until the next login.
enum LoginService {
    static let label = "com.stopyapping.app.agent"
    private static let service = SMAppService.agent(plistName: "\(label).plist")
    private static let setUpKey = "LoginServiceSetUp"

    /// True when this process was started by launchd for our agent.
    static var isAgentInstance: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    static var isEnabled: Bool { service.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
            Log.write("Open at login turned on (\(describe(service.status)))")
            handOffToAgent()
        } else {
            Log.write("Open at login turned off")
            if isAgentInstance {
                // Unregistering stops this agent process, so start a plain copy to take over.
                relaunchPlainCopy()
            }
            try service.unregister()
        }
    }

    /// Turn on login + crash recovery the first time the app runs.
    static func setUpOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: setUpKey) else { return }
        defaults.set(true, forKey: setUpKey)
        // The earlier login item style is replaced by the agent.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        do { try setEnabled(true) } catch { Log.write("Could not turn on open at login: \(error.localizedDescription)") }
    }

    /// Called at launch. Returns false when this copy should exit and let another one run.
    static func shouldKeepRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.stopyapping.app"
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me && !$0.isTerminated }
        }

        if isAgentInstance {
            // A plain copy may be handing over to us: give it a moment to quit.
            let deadline = Date().addingTimeInterval(5)
            while !others().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if !others().isEmpty {
                Log.write("Another copy is already running; this agent copy steps aside")
                return false
            }
            return true
        }

        if !others().isEmpty { return false }
        if isEnabled, kickstartAgent() {
            Log.write("Handing over to the login agent")
            return false
        }
        return true
    }

    /// When a plain copy is running and the agent is on, let the agent copy take over
    /// so that launchd watches the running app.
    private static func handOffToAgent() {
        guard !isAgentInstance, isEnabled, kickstartAgent() else { return }
        Log.write("Handing over to the login agent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            (NSApp.delegate as? AppController)?.prepareForHandOff()
            exit(0)
        }
    }

    @discardableResult
    private static func kickstartAgent() -> Bool {
        run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"])
    }

    private static func relaunchPlainCopy() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n '\(path)'"]
        try? task.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "needs approval in System Settings › Login Items"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
