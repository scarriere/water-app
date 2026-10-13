import AppKit
import SwiftUI

@MainActor
final class WaterAppDelegate: NSObject, NSApplicationDelegate {
    let reminders = HourlyReminder()
    let health = GoogleHealthSync()

    func applicationDidFinishLaunching(_ notification: Notification) {
        reminders.start()
        health.start()
    }
}

@main
struct WaterApp: App {
    @NSApplicationDelegateAdaptor(WaterAppDelegate.self) private var appDelegate
    @StateObject private var store = WaterStore()

    var body: some Scene {
        MenuBarExtra {
            VStack(spacing: 0) {
                ContentView(store: store, reminders: appDelegate.reminders, health: appDelegate.health)
                Divider()
                Button("Quit Water") {
                    NSApplication.shared.terminate(nil)
                }
                .padding(.vertical, 10)
            }
        } label: {
            Image(systemName: "drop.fill")
                .accessibilityLabel("Water tracker")
        }
        .menuBarExtraStyle(.window)
    }
}
