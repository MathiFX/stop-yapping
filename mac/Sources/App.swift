import AppKit
import AVFoundation
import ServiceManagement

struct Preferences {
    private static let store = UserDefaults.standard
    static let delayChoices = [60, 100, 140, 180, 240, 300, 400, 500]

    var microphoneUID: String?
    var delayMs: Int
    var paused: Bool

    static func load() -> Preferences {
        let saved = store.object(forKey: "DelayMs") as? Int ?? 180
        return Preferences(microphoneUID: store.string(forKey: "MicrophoneUID"),
                           delayMs: min(500, max(60, saved)),
                           paused: store.bool(forKey: "Paused"))
    }

    func save() {
        Preferences.store.set(microphoneUID, forKey: "MicrophoneUID")
        Preferences.store.set(delayMs, forKey: "DelayMs")
        Preferences.store.set(paused, forKey: "Paused")
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
    private let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    private var timer: Timer?
    private var lastIcon: String?

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
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateLock.lock(); stopping = true; stateLock.unlock()
        stopRoute()
    }

    private var isStopping: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopping }

    // MARK: State

    private var shouldMute: Bool { !preferences.paused && vowen == .recording }

    private func updateVowen(_ state: VowenState) {
        stateLock.lock(); defer { stateLock.unlock() }
        vowen = state
        route?.buffer.setBlocked(shouldMute)
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
            let candidate = try AudioRoute(input: input, delayMs: preferences.delayMs, initiallyMuted: true)
            stateLock.lock()
            candidate.buffer.setBlocked(shouldMute)
            route = candidate
            stateLock.unlock()
            try candidate.start()
        } catch {
            routeError(error.localizedDescription)
            stopRoute()
        }
    }

    private func routeError(_ message: String) {
        audioStatus = "Audio unavailable · Retrying"
        NSLog("Stop Yapping: %@", message)
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
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let help = NSMenuItem(title: "How to set up your call apps…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let uninstall = NSMenuItem(title: "Uninstall Stop Yapping…", action: #selector(uninstall), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Stop Yapping", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func togglePause() {
        stateLock.lock()
        preferences.paused.toggle()
        route?.buffer.setBlocked(shouldMute)
        stateLock.unlock()
        preferences.save()
        refresh()
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        stateLock.lock(); preferences.microphoneUID = sender.representedObject as? String; stateLock.unlock()
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
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            showAlert("Could not change the login setting", error.localizedDescription)
        }
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

        try? SMAppService.mainApp.unregister()
        let appPath = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let shell = """
        rm -rf '/Library/Audio/Plug-Ins/HAL/StopYapping.driver' '\(appPath)'; \
        pkgutil --forget com.stopyapping.app >/dev/null 2>&1; \
        pkgutil --forget com.stopyapping.driver >/dev/null 2>&1; \
        launchctl kickstart -k system/com.apple.audio.coreaudiod >/dev/null 2>&1 || killall coreaudiod
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
