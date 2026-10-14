import SwiftUI

/// Optional integration controls live outside the main tracker until expanded.
struct GoogleHealthSection: View {
    @ObservedObject var health: GoogleHealthSync
    @State private var changingClientSecret = false
    @State private var clientSecret = ""
    @State private var confirmBackfill = false
    @State private var confirmRetry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
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
                    Text("Drinks on Google").font(.subheadline.bold())
                    Spacer()
                    if health.hasReadPermission {
                        Button("Refresh list") { Task { await health.refreshGoogleDrinks() } }
                            .disabled(health.isRefreshingGoogle)
                    } else {
                        Button("Grant read access") { Task { await health.connect() } }
                    }
                }
                Text(health.googleListStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !health.googleDrinks.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(health.googleDrinks) { drink in
                                HStack {
                                    Text(drink.at.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                    Text("\(drink.ml) ml")
                                    Text(drink.confidence == .confirmed ? "Confirmed" : "Possible match")
                                        .foregroundStyle(drink.confidence == .confirmed ? .green : .orange)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .privacySensitive()
                }
                if health.queuedCount > 0 || health.uncertainCount > 0 {
                    Text("Local: \(health.queuedCount) queued, \(health.uncertainCount) need verification. Possible matches are not confirmed uploads; do not retry them blindly.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Button("Export earlier timed drinks…") { confirmBackfill = true }
                    if health.needsReview {
                        Button("Review and retry…") { confirmRetry = true }
                    }
                    if health.hasRejectedUploads {
                        Button("Retry rejected uploads") { Task { await health.retryRejected() } }
                    }
                }
                .font(.caption)
                .disabled(health.syncing)
            }
        }
        .padding(.top, 8)
        .confirmationDialog("Upload earlier timed drinks? Existing Google entries may be duplicated.",
                            isPresented: $confirmBackfill) {
            Button("Upload historical drinks") { Task { await health.backfill() } }
        }
        .confirmationDialog("Have you checked Google Health for duplicates? A timed-out upload may have succeeded; retrying can duplicate it.",
                            isPresented: $confirmRetry) {
            Button("I checked; retry unresolved uploads") { Task { await health.retryReviewed() } }
        }
    }
}
