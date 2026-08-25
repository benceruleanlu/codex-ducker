import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var enabledMenuItem: NSMenuItem!
    private var gainMenuItems = [NSMenuItem]()
    private var engine: DuckingEngine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        defaults.register(defaults: [
            "enabled": true,
            "duckGain": 0.2,
        ])
        engine = DuckingEngine(
            enabled: defaults.bool(forKey: "enabled"),
            duckGain: Float(defaults.double(forKey: "duckGain"))
        )
        engine.onStateChange = { [weak self] state in
            self?.updateUI(state)
        }

        buildMenu()
        updateUI(engine.state)
        if !defaults.bool(forKey: "introShown") {
            defaults.set(true, forKey: "introShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showIntroduction()
            }
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic.and.signal.meter",
            accessibilityDescription: "Codex Ducker"
        )

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Preparing…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        enabledMenuItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enabledMenuItem.target = self
        menu.addItem(enabledMenuItem)

        let gainItem = NSMenuItem(title: "Duck other audio to", action: nil, keyEquivalent: "")
        let gainMenu = NSMenu()
        for percentage in [10, 20, 35, 50] {
            let item = NSMenuItem(
                title: "\(percentage)%",
                action: #selector(selectGain(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = percentage
            gainMenu.addItem(item)
            gainMenuItems.append(item)
        }
        gainItem.submenu = gainMenu
        menu.addItem(gainItem)

        let testItem = NSMenuItem(
            title: "Run 3-second test",
            action: #selector(runTest),
            keyEquivalent: ""
        )
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(.separator())
        let privacyItem = NSMenuItem(
            title: "Open Privacy & Security…",
            action: #selector(openPrivacySettings),
            keyEquivalent: ""
        )
        privacyItem.target = self
        menu.addItem(privacyItem)

        let quitItem = NSMenuItem(
            title: "Quit Codex Ducker",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func updateUI(_ state: DuckerState) {
        guard statusItem != nil else { return }
        statusMenuItem.title = state.menuText
        enabledMenuItem.state = engine.enabled ? .on : .off
        for item in gainMenuItems {
            item.state = abs(engine.duckGain - Float(item.tag) / 100.0) < 0.001 ? .on : .off
        }

        let symbol: String
        switch state {
        case .ducking:
            symbol = "speaker.wave.1.fill"
        case .bypassed:
            symbol = "headphones"
        case .warming:
            symbol = "waveform.badge.mic"
        case .error:
            symbol = "exclamationmark.triangle.fill"
        case .disabled:
            symbol = "speaker.slash"
        default:
            symbol = "mic.and.signal.meter"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: state.menuText
        )
        statusItem.button?.toolTip = "Codex Ducker — \(state.menuText)"
    }

    private func showIntroduction() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Codex Ducker is ready"
        alert.informativeText = "It watches the default microphone's actual running state. While you are dictating through speakers, it safely verifies a private Core Audio tap, routes other app audio through it at \(Int(engine.duckGain * 100))% volume, then restores direct playback. Headphone and headset outputs are bypassed. The first test asks macOS for System Audio Recording permission; no audio is saved."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable & Test")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            engine.runTest(duration: 3.0)
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        engine.enabled.toggle()
        defaults.set(engine.enabled, forKey: "enabled")
        updateUI(engine.state)
    }

    @objc private func selectGain(_ sender: NSMenuItem) {
        engine.duckGain = Float(sender.tag) / 100.0
        defaults.set(Double(engine.duckGain), forKey: "duckGain")
        updateUI(engine.state)
    }

    @objc private func runTest() {
        engine.runTest(duration: 3.0)
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }
}
