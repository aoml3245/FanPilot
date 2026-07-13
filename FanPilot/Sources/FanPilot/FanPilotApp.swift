import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class FanPilotApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var state: AppState!
    private var cancellables: Set<AnyCancellable> = []
    private var terminationApproved = false

    static func main() {
        if CommandLine.arguments.contains("--probe") {
            ProbeCommand.run()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            SelfTestCommand.run()
            return
        }
        if CommandLine.arguments.contains("--write-test") {
            WriteTestCommand.run()
            return
        }

        let app = NSApplication.shared
        let delegate = FanPilotApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusButtonTitle(state.menuBarText)
        statusItem.button?.toolTip = "FanPilot"
        rebuildMenu()
        state.$menuBarText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.updateStatusButtonTitle(text)
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
        state.$configuredSensorMenuLines
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        let content = ContentView(state: state)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FanPilot"
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        window.center()

        state.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationApproved else { return .terminateNow }
        state.shutdown { [weak self, weak sender] in
            self?.terminationApproved = true
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: state.menuBarText.replacingOccurrences(of: "\n", with: "  "), action: nil, keyEquivalent: ""))
        if !state.configuredSensorMenuLines.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let sensorsTitle = NSMenuItem(title: "Configured Sensors", action: nil, keyEquivalent: "")
            sensorsTitle.isEnabled = false
            menu.addItem(sensorsTitle)
            for line in state.configuredSensorMenuLines {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: window?.isVisible == true ? "Hide FanPilot" : "Open FanPilot", action: #selector(toggleWindowFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLoginFromMenu), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = state.configuration.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit FanPilot", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateStatusButtonTitle(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 0
        paragraph.minimumLineHeight = 9
        paragraph.maximumLineHeight = 9

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                .paragraphStyle: paragraph,
                .baselineOffset: -4,
                .foregroundColor: NSColor.labelColor
            ]
        )
        if let newline = text.firstIndex(of: "\n") {
            let lowerStart = text.distance(from: text.startIndex, to: text.index(after: newline))
            let lowerLength = text.count - lowerStart
            attributed.addAttribute(
                .font,
                value: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                range: NSRange(location: lowerStart, length: lowerLength)
            )
        }
        statusItem.button?.attributedTitle = attributed
    }

    @objc private func toggleWindowFromMenu() {
        toggleWindow()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLoginFromMenu() {
        state.setLaunchAtLogin(!state.configuration.launchAtLogin)
        rebuildMenu()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension FanPilotApp: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        rebuildMenu()
        return false
    }
}
