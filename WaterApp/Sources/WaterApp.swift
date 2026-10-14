import AppKit
import SwiftUI

@MainActor
final class WaterAppDelegate: NSObject, NSApplicationDelegate {
    let reminders = HourlyReminder()
    let health = GoogleHealthSync()
    let store = WaterStore()

    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var hasShownWindow = false
    private var windowAnimationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay in the menu bar even when the movable window is closed.
        NSApplication.shared.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Water tracker")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.setAccessibilityLabel("Water tracker")
        item.button?.target = self
        item.button?.action = #selector(toggleWindow)
        statusItem = item

        reminders.start()
        health.start()
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func toggleWindow() {
        guard !windowAnimationInProgress else { return }
        if let mainWindow, mainWindow.isVisible {
            snapToStatusItem(mainWindow)
        } else {
            showWindow()
        }
    }

    private func statusIconFrame() -> NSRect? {
        guard let button = statusItem?.button, let barWindow = button.window else { return nil }
        let rect = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return NSRect(x: rect.midX - 16, y: rect.midY - 16, width: 32, height: 32)
    }

    private func snapToStatusItem(_ window: NSWindow) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let target = statusIconFrame() else {
            window.orderOut(nil)
            return
        }
        let savedFrame = window.frame
        let savedMinimum = window.minSize
        windowAnimationInProgress = true
        window.minSize = .zero
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let window else { return }
                window.orderOut(nil)
                window.setFrame(savedFrame, display: false)
                window.alphaValue = 1
                window.minSize = savedMinimum
                self?.windowAnimationInProgress = false
            }
        }
    }

    private func showWindow() {
        if mainWindow == nil {
            let content = ScrollView {
                VStack(spacing: 0) {
                    ContentView(store: store, reminders: reminders, health: health)
                        .frame(maxWidth: .infinity)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Quit Water") { NSApplication.shared.terminate(nil) }
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Water"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 500, height: 480)
            window.contentView = NSHostingView(rootView: content)
            window.setFrameAutosaveName("WaterMainWindow")
            if !window.setFrameUsingName("WaterMainWindow") { window.center() }
            mainWindow = window
        }
        guard let mainWindow else { return }
        if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if hasShownWindow && !mainWindow.isVisible &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let origin = statusIconFrame() {
            let destination = mainWindow.frame
            let savedMinimum = mainWindow.minSize
            windowAnimationInProgress = true
            mainWindow.minSize = .zero
            mainWindow.setFrame(origin, display: false)
            mainWindow.alphaValue = 0
            mainWindow.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                mainWindow.animator().setFrame(destination, display: true)
                mainWindow.animator().alphaValue = 1
            } completionHandler: { [weak self, weak mainWindow] in
                Task { @MainActor in
                    mainWindow?.minSize = savedMinimum
                    self?.windowAnimationInProgress = false
                }
            }
        } else {
            mainWindow.makeKeyAndOrderFront(nil)
        }
        hasShownWindow = true
    }
}

@main
struct WaterApp: App {
    @NSApplicationDelegateAdaptor(WaterAppDelegate.self) private var appDelegate

    var body: some Scene {
        // The status item and main window are owned by the delegate; no Dock window is created.
        Settings { EmptyView() }
    }
}
