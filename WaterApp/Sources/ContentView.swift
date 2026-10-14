import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: WaterStore
    @ObservedObject var reminders: HourlyReminder
    @ObservedObject var health: GoogleHealthSync
    @State private var displayedML = 0.0
    @State private var pouring = false
    @State private var animating = false
    @State private var confirmBackfill = false
    @State private var confirmRetry = false
    @State private var changingClientSecret = false
    @State private var clientSecret = ""

    var body: some View {
        VStack(spacing: 10) {
            Text("Water • \(store.dayKey)")
                .font(.title2.bold())

            BottleView(milliliters: displayedML, pouring: pouring)

            Text("\(store.totalML.formatted()) / \(WaterRepository.goalML.formatted()) ml")
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .accessibilityLabel("Today: \(store.totalML) of \(WaterRepository.goalML) milliliters")

            if store.totalML >= WaterRepository.goalML {
                Text("Daily goal reached!").foregroundStyle(.green)
            } else {
                Text("\((WaterRepository.goalML - store.totalML).formatted()) ml to go")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(action: addGlass) {
                    Label("Add glass (+355 ml)", systemImage: "drop.fill")
                        .frame(minWidth: 185)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Saves one 355 milliliter glass for today")

                Button(action: removeGlass) {
                    Label("Remove glass (-355 ml)", systemImage: "minus.circle")
                        .frame(minWidth: 185)
                }
                .buttonStyle(.bordered)
                .disabled(store.totalML < WaterRepository.glassML)
                .accessibilityHint("Undoes the most recent 355 milliliter glass")
            }
            .controlSize(.large)
            .disabled(animating)

            Divider()
            HStack {
                Text("Google Health").font(.headline)
                Spacer()
                if health.account == nil {
                    if health.hasClientSecret && !changingClientSecret {
                        Button("Connect") { Task { await health.connect() } }
                    }
                } else {
                    Button("Sync now") { Task { await health.sync() } }
                        .disabled(health.syncing)
                    Button("Disconnect") { health.disconnect() }
                        .disabled(health.syncing)
                }
            }
            if !health.hasClientSecret || changingClientSecret {
                SecureField("Desktop OAuth client secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                HStack {
                    Text("Paste the Desktop client secret from Google Cloud. Stored in macOS Keychain, not in this app build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if changingClientSecret && health.hasClientSecret {
                        Button("Cancel") {
                            clientSecret = ""
                            changingClientSecret = false
                        }
                    }
                    Button(health.account == nil ? "Save & Connect" : "Save secret") {
                        let value = clientSecret
                        clientSecret = ""
                        if health.saveClientSecret(value) {
                            changingClientSecret = false
                            Task {
                                if health.account == nil { await health.connect() }
                                else { await health.sync() }
                            }
                        }
                    }
                    .disabled(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if health.account == nil {
                Button("Change client secret…") { changingClientSecret = true }
                    .font(.caption)
            }
            if let account = health.account {
                Text("Connected: \(account)").font(.caption).foregroundStyle(.secondary)
            }
            Text(health.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if health.account != nil {
                HStack {
                    Button("Export earlier timed drinks…") { confirmBackfill = true }
                    if health.needsReview {
                        Button("Review and retry…") { confirmRetry = true }
                    }
                }
                .font(.caption)
                .disabled(health.syncing)
            }

            Text("Hourly reminder if less than 250 ml was logged in 60 minutes")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Full-screen reminders (instead of banners)", isOn: $reminders.fullScreenEnabled)
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
            if reminders.fullScreenEnabled {
                Text("In-app overlay; works without macOS notification permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview full-screen reminder") { reminders.previewFullScreen() }
                    .font(.caption)
            } else {
                if let message = reminders.permissionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if reminders.permissionEnabled {
                    HStack {
                        Button("Send test notification") { reminders.sendTestNotification() }
                        Button("Notification Settings") { reminders.openNotificationSettings() }
                    }
                    .font(.caption)
                } else {
                    Button(reminders.canRequestPermission ? "Enable notifications" : "Open Notification Settings") {
                        if reminders.canRequestPermission {
                            reminders.requestPermission()
                        } else {
                            reminders.openNotificationSettings()
                        }
                    }
                    .font(.caption)
                }
            }

            if store.totalML > WaterRepository.bottleML {
                Text("Bottle display capped at 3 L; your total is still saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 480)
        .confirmationDialog("Upload earlier timed drinks? Existing Google entries may be duplicated.",
                            isPresented: $confirmBackfill) {
            Button("Upload historical drinks") { Task { await health.backfill() } }
        }
        .confirmationDialog("Have you checked Google Health for duplicates? A timed-out upload may have succeeded; retrying can duplicate it.",
                            isPresented: $confirmRetry) {
            Button("I checked; retry unresolved uploads") { Task { await health.retryReviewed() } }
        }
        .onAppear {
            refresh()
            reminders.refreshPermission()
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            if !animating { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !animating { refresh() }
        }
    }

    private func refresh() {
        store.refresh()
        if store.errorMessage == nil {
            displayedML = Double(store.totalML)
        }
    }

    private func addGlass() {
        guard !animating else { return }
        // Pick up changes from the CLI before starting the next 355 ml animation.
        refresh()
        guard store.errorMessage == nil else { return }
        let start = store.totalML
        guard let end = store.addGlass() else { return }

        displayedML = Double(start)
        animating = true
        pouring = true
        withAnimation(.easeInOut(duration: 0.75)) {
            displayedML = Double(end)
        }
        Task { await health.sync() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            pouring = false
            animating = false
        }
    }

    private func removeGlass() {
        guard !animating else { return }
        refresh()
        guard store.errorMessage == nil else { return }
        let start = store.totalML
        guard let end = store.removeGlass() else { return }

        displayedML = Double(start)
        animating = true
        withAnimation(.easeOut(duration: 0.5)) {
            displayedML = Double(end)
        }
        Task { await health.sync() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            animating = false
        }
    }
}
