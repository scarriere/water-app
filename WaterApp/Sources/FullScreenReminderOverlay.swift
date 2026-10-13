import AppKit
import SwiftUI

/// A Water-owned window, not a macOS notification. It works without notification permission.
@MainActor
final class FullScreenReminderOverlay {
    private var panel: ReminderPanel?
    private var autoDismiss: DispatchWorkItem?

    func show(consumedML: Int) {
        dismiss()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = ReminderPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = true
        panel.backgroundColor = NSColor(red: 0.02, green: 0.07, blue: 0.15, alpha: 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onEscape = { [weak self] in self?.dismiss() }
        panel.contentView = NSHostingView(rootView: ReminderOverlayView(consumedML: consumedML) { [weak self] in
            self?.dismiss()
        })
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)

        // An inaccessible overlay should never trap the desktop indefinitely.
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, self.panel === panel else { return }
            self.dismiss()
        }
        autoDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    func dismiss() {
        autoDismiss?.cancel()
        autoDismiss = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ReminderPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct ReminderOverlayView: View {
    let consumedML: Int
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.07, blue: 0.15).ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(.cyan)
                Text("Time for water")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                Text("You logged \(consumedML) ml in the last hour.\nAim for at least 250 ml.")
                    .font(.title)
                    .multilineTextAlignment(.center)
                Button("Dismiss reminder", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.escape, modifiers: [])
                Text("Press Esc to dismiss • Closes automatically after 45 seconds")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(50)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Full-screen water reminder")
    }
}
