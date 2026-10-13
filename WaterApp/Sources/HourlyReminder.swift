import AppKit
import Combine
import Foundation
import UserNotifications

/// Checks the previous 60 minutes once per hour while the menu-bar app is running.
@MainActor
final class HourlyReminder: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var permissionMessage: String? = "Checking notification permission…"
    @Published private(set) var permissionEnabled = false
    @Published private(set) var canRequestPermission = true
    @Published var fullScreenEnabled = UserDefaults.standard.bool(forKey: "WaterFullScreenReminders") {
        didSet {
            UserDefaults.standard.set(fullScreenEnabled, forKey: "WaterFullScreenReminders")
            if !fullScreenEnabled { overlay.dismiss() }
        }
    }

    private let overlay = FullScreenReminderOverlay()
    private let repository = WaterRepository()
    private let center = UNUserNotificationCenter.current()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        center.delegate = self
        if fullScreenEnabled { refreshPermission() } else { requestPermission() }
        // The first check is after a complete hour of tracking; legacy totals have no
        // timestamps, so checking sooner could incorrectly report that no water was drunk.
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.permissionMessage = "Notification request failed: \(error.localizedDescription)"
                } else {
                    self.refreshPermission()
                }
            }
        }
    }

    func refreshPermission() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.permissionEnabled = true
                    self.canRequestPermission = false
                    self.permissionMessage = settings.alertSetting == .disabled
                        ? "Water is allowed, but notification alerts are turned off in System Settings."
                        : nil
                case .denied:
                    self.permissionEnabled = false
                    self.canRequestPermission = false
                    self.permissionMessage = "Water notifications are off. Enable them in System Settings."
                case .notDetermined:
                    self.permissionEnabled = false
                    self.canRequestPermission = true
                    self.permissionMessage = "Water has not received notification permission yet."
                @unknown default:
                    self.permissionEnabled = false
                    self.canRequestPermission = true
                    self.permissionMessage = "Unknown notification permission status."
                }
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func sendTestNotification() {
        guard permissionEnabled else { return }
        sendNotification(
            id: "water-test-\(UUID().uuidString)",
            title: "Water notifications are working",
            body: "Hourly reminders will appear when you log less than 250 ml."
        )
    }

    func previewFullScreen() {
        overlay.show(consumedML: 0)
    }

    private func check() {
        if fullScreenEnabled {
            notifyIfNeeded(at: Date())
            return
        }
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard settings.authorizationStatus == .authorized ||
                        settings.authorizationStatus == .provisional else {
                    self.refreshPermission()
                    return
                }
                self.notifyIfNeeded(at: Date())
            }
        }
    }

    private func notifyIfNeeded(at now: Date) {
        do {
            let start = now.addingTimeInterval(-3_600)
            let consumed = try repository.consumed(from: start, to: now)
            guard consumed < WaterRepository.hourlyMinimumML else { return }

            if fullScreenEnabled {
                overlay.show(consumedML: consumed)
            } else {
                sendNotification(
                    id: "water-hour-\(Int(now.timeIntervalSince1970 / 3_600))",
                    title: "Time for some water",
                    body: "You logged \(consumed) ml in the last hour. Aim for at least 250 ml."
                )
            }
        } catch {
            permissionMessage = "Reminders paused: \(error.localizedDescription)"
        }
    }

    private func sendNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.permissionMessage = "Could not send notification: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
