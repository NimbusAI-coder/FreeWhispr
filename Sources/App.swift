import AppKit
import Foundation

@main
enum FreeWhispr {
    static func main() {
        Settings.registerDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@available(macOS 26.0, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let hotkeys = HotkeyManager()
    private lazy var controller = DictationController()
    private var ollamaReachable = false
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Trace.rotateIfLarge()
        buildStatusItem()
        wireController()
        wireHotkeys()

        Trace.write("launch: accessibilityTrusted=\(self.hotkeys.isTrusted)")

        if hotkeys.isTrusted {
            hotkeys.start()
            Trace.write("launch: hotkey tap installed")
        } else {
            Trace.write("launch: NOT trusted for Accessibility — hotkey will not fire")
            promptForAccessibility()
        }

        // Pull the speech model down now so the first dictation is not slow.
        Task { await Transcriber.prewarm() }
        refreshOllamaStatus()

        // Keep the model alive after launch. macOS can unload the speech asset
        // at any time; re-check periodically and after every wake from sleep so
        // it is repaired before the next dictation instead of during it.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { await Transcriber.healthCheck(trigger: "timer") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await Transcriber.healthCheck(trigger: "wake") }
        }

        // Last-resort self-heal. Observed in the wild: after long uptime the
        // process's connection to the macOS speech service goes stale — every
        // in-process restore reports the model missing while a fresh process
        // sees it installed. Nothing inside the process can repair that, so
        // once restores fail repeatedly, restart the app. Rate-limited so a
        // genuine outage (no network for hours) cannot cause a relaunch loop.
        Transcriber.onRestoreFailureStreak = { [weak self] streak in
            Task { @MainActor in self?.recoverFromStuckSpeechService(streak: streak) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
    }

    // MARK: - Wiring

    private func wireController() {
        controller.onStateChange = { [weak self] recording in
            self?.updateIcon(recording: recording)
        }
        controller.onError = { [weak self] message in
            self?.presentError(message)
        }
    }

    private func wireHotkeys() {
        hotkeys.onHoldStart = { [weak self] in self?.controller.start() }
        hotkeys.onHoldStop = { [weak self] in self?.controller.stopAndPaste() }
        hotkeys.onLatch = { [weak self] in self?.controller.setLatched(true) }
        hotkeys.onCancel = { [weak self] in
            self?.controller.cancel()
            self?.hotkeys.noteRecordingEnded()
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "FreeWhispr"
        )
        item.menu = buildMenu()
        statusItem = item
    }

    private func updateIcon(recording: Bool) {
        let symbol = recording ? "waveform.circle.fill" : "waveform"
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "FreeWhispr"
        )
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: controller.isRecording ? "Stop Dictating" : "Start Dictating",
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let hint = NSMenuItem(title: "Hold fn to talk · ⌘ to latch · esc to cancel", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        if !hotkeys.isTrusted {
            let warn = NSMenuItem(
                title: "⚠ Grant Accessibility permission",
                action: #selector(promptForAccessibility),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
        }

        // A background model restore that keeps failing must be visible
        // somewhere the user can find it, not only in the trace log.
        if let health = Transcriber.healthWarning() {
            let item = NSMenuItem(title: health, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let cleanup = NSMenuItem(
            title: "Clean up with Ollama",
            action: #selector(toggleCleanup),
            keyEquivalent: ""
        )
        cleanup.target = self
        cleanup.state = Settings.cleanupEnabled ? .on : .off
        menu.addItem(cleanup)

        let status = NSMenuItem(
            title: ollamaReachable
                ? "Ollama: connected (\(Settings.ollamaModel))"
                : "Ollama: not running — using raw transcript",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        let recheck = NSMenuItem(
            title: "Re-check Ollama",
            action: #selector(refreshOllamaStatusAction),
            keyEquivalent: ""
        )
        recheck.target = self
        menu.addItem(recheck)

        menu.addItem(.separator())

        let privacy = NSMenuItem(
            title: "Privacy: audio never leaves this Mac",
            action: nil,
            keyEquivalent: ""
        )
        privacy.isEnabled = false
        menu.addItem(privacy)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit FreeWhispr", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        controller.toggle()
    }

    @objc private func toggleCleanup() {
        Settings.cleanupEnabled.toggle()
        refreshOllamaStatus()
    }

    @objc private func refreshOllamaStatusAction() {
        refreshOllamaStatus()
    }

    private func refreshOllamaStatus() {
        Task { @MainActor in
            self.ollamaReachable = await OllamaCleanup.isAvailable()
            self.statusItem?.menu = self.buildMenu()
        }
    }

    @objc private func promptForAccessibility() {
        let granted = hotkeys.requestAccessibility()
        if granted {
            hotkeys.start()
            statusItem?.menu = buildMenu()
            return
        }

        // The tap can only be created once the user flips the switch, so poll
        // briefly rather than making them relaunch.
        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.hotkeys.isTrusted {
                    self.hotkeys.start()
                    self.statusItem?.menu = self.buildMenu()
                    return
                }
            }
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "FreeWhispr"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func recoverFromStuckSpeechService(streak: Int) {
        guard streak >= 3, !controller.isRecording else { return }

        let key = "last_auto_relaunch"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last > 3600 else { return }
        UserDefaults.standard.set(now, forKey: key)

        Trace.write("relaunch: restore failed \(streak)× in-process — speech service connection presumed stale, restarting")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
