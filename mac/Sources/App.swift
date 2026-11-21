import AppKit
import AVFoundation
import ServiceManagement

struct Preferences {
    private static let store = UserDefaults.standard
    static let delayChoices = [60, 100, 140, 180, 240, 300, 400, 500]

    var microphoneUID: String?
    var delayMs: Int
    var paused: Bool
    var reduceNoise: Bool

    static func load() -> Preferences {
        let saved = store.object(forKey: "DelayMs") as? Int ?? 180
        return Preferences(microphoneUID: store.string(forKey: "MicrophoneUID"),
                           delayMs: min(500, max(60, saved)),
                           paused: store.bool(forKey: "Paused"),
                           reduceNoise: store.object(forKey: "ReduceNoise") as? Bool ?? false)
    }

    func save() {
        Preferences.store.set(microphoneUID, forKey: "MicrophoneUID")
        Preferences.store.set(delayMs, forKey: "DelayMs")
        Preferences.store.set(paused, forKey: "Paused")
        Preferences.store.set(reduceNoise, forKey: "ReduceNoise")
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let stateLock = NSLock()
    private var preferences = Preferences.load()
    private var vowen = VowenState.unavailable
    private var route: AudioRoute?
    private var audioStatus = "Starting audio…"
    private var nextAttempt = Date.distantPast
    private var stopping = false
    private var permissionAsked = false

    private let monitor = VowenMonitor()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusDivider = NSMenuItem.separator()
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
    private let microphoneMenu = NSMenu()
    private let delayMenu = NSMenu()
    private let noiseItem = NSMenuItem(title: "Reduce background hiss", action: #selector(toggleNoise), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    private var timer: Timer?
    private var lastIcon: String?
    private var lastLoggedVowen: VowenState?
    private var lastAudioStatus = ""
    private var quitRequestedFromMenu = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "Stop Yapping"
        buildMenu()
        statusItem.menu = menu

        Thread.detachNewThread { [weak self, monitor] in
            monitor.run(publish: { self?.updateVowen($0) },
                        shouldStop: { self?.isStopping ?? true })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)   // keep running while the menu is open
        refresh()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Log.write("Mac going to sleep")
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("Mac woke up, rebuilding the audio route")
            self?.restartRoute()
        }
        workspace.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            Log.write("Logging out or shutting down")
        }
        LoginService.setUpOnFirstLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.write(quitRequestedFromMenu ? "Quit from the menu" : "Asked to quit by macOS or another app")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateLock.lock(); stopping = true; stateLock.unlock()
        stopRoute()
        Log.write("Stopped")
    }

    func prepareForHandOff() {
        stateLock.lock(); stopping = true; stateLock.unlock()
        stopRoute()
    }

    @objc private func quitFromMenu() {
        quitRequestedFromMenu = true
        NSApp.terminate(nil)
    }

    private var isStopping: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopping }

    // MARK: State

    private var shouldMute: Bool { !preferences.paused && vowen == .recording }

    private func updateVowen(_ state: VowenState) {
        stateLock.lock(); defer { stateLock.unlock() }
        vowen = state
        route?.buffer.setBlocked(shouldMute)
        if state != lastLoggedVowen {
            lastLoggedVowen = state
            Log.write("Vowen \(state)")
        }
    }

    private func refresh() {
        if let failure = route?.failure {
            routeError(failure)
            stopRoute()
        }
        if route == nil, Date() >= nextAttempt { startRoute() }

        stateLock.lock()
        let label: String
        if route == nil { label = audioStatus }
        else if preferences.paused { label = "Automatic muting paused" }
        else if shouldMute { label = "Call mic muted while you dictate" }
        else if vowen == .unavailable { label = "Vowen unavailable" }
        else { label = "" }
        let muted = route != nil && shouldMute
        let paused = preferences.paused
        stateLock.unlock()

        if route == nil, audioStatus != lastAudioStatus {
            lastAudioStatus = audioStatus
            Log.write("Status: \(audioStatus)")
        }

        statusLine.title = label
        statusLine.isHidden = label.isEmpty
        statusDivider.isHidden = label.isEmpty
        pauseItem.title = paused ? "Resume automatic muting" : "Pause automatic muting"
        statusItem.button?.toolTip = label.isEmpty ? "Stop Yapping" : "Stop Yapping · \(label)"

        let icon = route == nil ? "mic.badge.xmark" : muted ? "mic.slash.fill" : paused ? "pause.circle" : "mic"
        if icon != lastIcon {
            lastIcon = icon
            let image = NSImage(systemSymbolName: icon, accessibilityDescription: "Stop Yapping")
            image?.isTemplate = true
            statusItem.button?.image = image
        }
    }

    private func startRoute() {
        nextAttempt = Date().addingTimeInterval(2)

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            audioStatus = "Waiting for microphone permission"
            if !permissionAsked {
                permissionAsked = true
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    DispatchQueue.main.async { self?.nextAttempt = .distantPast }
                }
            }
            return
        default:
            audioStatus = "Allow microphone access in System Settings"
            return
        }

        guard CoreAudio.device(uid: CoreAudio.virtualFeedUID) != nil else {
            audioStatus = "Stop Yapping Mic driver is missing"
            return
        }
        guard let input = currentInput() else {
            audioStatus = "Select an available microphone"
            return
        }
        do {
            let candidate = try AudioRoute(input: input, delayMs: preferences.delayMs, initiallyMuted: true,
                                           reduceNoise: preferences.reduceNoise)
            stateLock.lock()
            candidate.buffer.setBlocked(shouldMute)
            route = candidate
            stateLock.unlock()
            try candidate.start()
            lastAudioStatus = ""
            Log.write("Audio route started: \(input.name) at \(Int(candidate.inputRate)) Hz → Stop Yapping Mic at \(Int(candidate.outputRate)) Hz, \(preferences.delayMs) ms delay, hiss reduction \(preferences.reduceNoise ? "on" : "off")")
        } catch {
            routeError(error.localizedDescription)
            stopRoute()
        }
    }

    private func routeError(_ message: String) {
        audioStatus = "Audio unavailable · Retrying"
        Log.write("Audio error: \(message)")
        nextAttempt = Date().addingTimeInterval(2)
    }

    private func stopRoute() {
        stateLock.lock()
        let current = route
        route = nil
        current?.buffer.setBlocked(true)
        stateLock.unlock()
        current?.stop()
    }

    private func currentInput() -> AudioEndpoint? {
        CoreAudio.chooseInput(CoreAudio.inputs(), selectedUID: preferences.microphoneUID,
                              defaultUID: preferences.microphoneUID == nil ? CoreAudio.defaultInputUID() : nil)
    }

    private func restartRoute() {
        stopRoute()
        nextAttempt = .distantPast
        refresh()
    }

    // MARK: Menu

    private func buildMenu() {
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(statusDivider)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = microphoneMenu
        menu.addItem(micItem)
        let delayItem = NSMenuItem(title: "First-word protection", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)
        noiseItem.target = self
        menu.addItem(noiseItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let help = NSMenuItem(title: "How to set up your call apps…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let uninstall = NSMenuItem(title: "Uninstall Stop Yapping…", action: #selector(uninstall), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
        let logs = NSMenuItem(title: "Show log", action: #selector(showLog), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stop Yapping", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        microphoneMenu.removeAllItems()
        let inputs = CoreAudio.inputs()
        let systemDefault = NSMenuItem(title: "Same as System Settings", action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
        systemDefault.target = self
        systemDefault.state = preferences.microphoneUID == nil ? .on : .off
        microphoneMenu.addItem(systemDefault)
        microphoneMenu.addItem(.separator())
        for input in inputs {
            let item = NSMenuItem(title: input.name, action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = input.uid
            item.state = preferences.microphoneUID == input.uid ? .on : .off
            microphoneMenu.addItem(item)
        }
        if let saved = preferences.microphoneUID, !inputs.contains(where: { $0.uid == saved }) {
            let missing = NSMenuItem(title: "Saved microphone (disconnected)", action: nil, keyEquivalent: "")
            missing.state = .on
            missing.isEnabled = false
            microphoneMenu.addItem(missing)
        }

        delayMenu.removeAllItems()
        let note = NSMenuItem(title: "Raise this if your first word slips through", action: nil, keyEquivalent: "")
        note.isEnabled = false
        delayMenu.addItem(note)
        for value in Set(Preferences.delayChoices + [preferences.delayMs]).sorted() {
            let item = NSMenuItem(title: "\(value) ms", action: #selector(chooseDelay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = value == preferences.delayMs ? .on : .off
            delayMenu.addItem(item)
        }

        loginItem.state = LoginService.isEnabled ? .on : .off
        noiseItem.state = preferences.reduceNoise ? .on : .off
    }

    @objc private func togglePause() {
        stateLock.lock()
        preferences.paused.toggle()
        route?.buffer.setBlocked(shouldMute)
        let paused = preferences.paused
        stateLock.unlock()
        Log.write(paused ? "Automatic muting paused" : "Automatic muting resumed")
        preferences.save()
        refresh()
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        stateLock.lock(); preferences.microphoneUID = sender.representedObject as? String; stateLock.unlock()
        preferences.save()
        restartRoute()
    }

    @objc private func toggleNoise() {
        stateLock.lock(); preferences.reduceNoise.toggle(); stateLock.unlock()
        preferences.save()
        restartRoute()
    }

    @objc private func chooseDelay(_ sender: NSMenuItem) {
        stateLock.lock(); preferences.delayMs = sender.tag; stateLock.unlock()
        preferences.save()
        restartRoute()
    }

    @objc private func toggleLogin() {
        do {
            try LoginService.setEnabled(!LoginService.isEnabled)
        } catch {
            Log.write("Login setting failed: \(error.localizedDescription)")
            showAlert("Could not change the login setting", error.localizedDescription)
        }
    }

    @objc private func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.file])
    }

    @objc private func showHelp() {
        showAlert("Pick “Stop Yapping Mic” in your call apps",
                  """
                  In Zoom, Meet, Discord, Teams and other call apps, choose Stop Yapping Mic as the microphone. \
                  It carries your voice and goes quiet while Vowen is recording.

                  Keep your regular microphone selected in Vowen. Stop Yapping uses the microphone chosen \
                  in its Microphone menu, which follows System Settings by default.
                  """)
    }

    @objc private func uninstall() {
        let confirm = NSAlert()
        confirm.messageText = "Uninstall Stop Yapping?"
        confirm.informativeText = "This removes the app and the Stop Yapping Mic driver. Switch your call apps back to your regular microphone first. macOS will ask for your password."
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        Log.write("Uninstalling")
        let appPath = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let shell = """
        rm -rf '/Library/Audio/Plug-Ins/HAL/StopYapping.driver' '\(appPath)'; \
        pkgutil --forget com.stopyapping.app >/dev/null 2>&1; \
        pkgutil --forget com.stopyapping.driver >/dev/null 2>&1; \
        (launchctl kickstart -k system/com.apple.audio.coreaudiod >/dev/null 2>&1 || killall coreaudiod); \
        launchctl bootout gui/\(getuid())/\(LoginService.label) >/dev/null 2>&1; true
        """
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            showAlert("Uninstall failed", error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
            return
        }
        if error == nil {
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.stopyapping.app")
            NSApp.terminate(nil)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
