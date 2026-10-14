import AppKit
import SwiftUI

@MainActor
final class WaterAppDelegate: NSObject, NSApplicationDelegate {
    let reminders = HourlyReminder()
    let health = GoogleHealthSync()
    let store = WaterStore()

    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?

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
        if let mainWindow, mainWindow.isVisible && mainWindow.isKeyWindow {
            mainWindow.orderOut(nil)
        } else {
            showWindow()
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
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
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
