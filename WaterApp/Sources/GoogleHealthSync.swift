import Combine
import Foundation

/// Local files are authoritative. The ledger stores Google's server-assigned IDs separately
/// because the Python CLI discards unknown top-level daily-file fields on rewrite.
@MainActor
final class GoogleHealthSync: ObservableObject {
    struct Entry: Codable {
        let at: String
        let ml: Int
        var remoteName: String?
        var operationName: String?
        var operationType: String?
        var uncertain = false
    }

    struct Ledger: Codable {
        var cutoff: Date
        var entries: [String: Entry] = [:]
    }

    @Published private(set) var account: String?
    @Published private(set) var hasClientSecret = false
    @Published private(set) var status = "Not connected"
    @Published private(set) var syncing = false
    @Published private(set) var needsReview = false

    private let repository: WaterRepository
    private let auth = GoogleHealthAuth()
    private var timer: Timer?
    private var running = false

    init(repository: WaterRepository = WaterRepository()) {
        self.repository = repository
        account = auth.credentials?.email
        hasClientSecret = auth.hasClientSecret
        if account != nil { status = "Ready to sync" }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sync() }
        }
        Task { await sync() }
    }

    @discardableResult
    func saveClientSecret(_ value: String) -> Bool {
        guard !running else { return false }
        do {
            try auth.saveClientSecret(value)
            hasClientSecret = true
            status = "OAuth client secret saved in Keychain"
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    func connect() async {
        guard !running else { return }
        running = true
        status = "Opening Google sign-in…"
        do {
            try await auth.connect()
            account = auth.credentials?.email
            status = "Connected; syncing new drinks"
            running = false
            await sync()
        } catch {
            status = error.localizedDescription
            running = false
        }
    }

    /// Only after the user explicitly confirms the risk of duplicating pre-existing Google data.
    func backfill() async {
        guard !running, let subject = auth.credentials?.subject else { return }
        do {
            var ledger = try loadLedger(subject: subject)
            ledger.cutoff = .distantPast
            try save(ledger, subject: subject)
            await sync()
        } catch {
            status = "Could not enable historical export: \(error.localizedDescription)"
        }
    }

    /// Call only after checking Google Health for duplicates. An unknown create may
    /// have succeeded; resetting it can upload the same drink again.
    func retryReviewed() async {
        guard !running, let subject = auth.credentials?.subject else { return }
        do {
            var ledger = try loadLedger(subject: subject)
            for (id, var entry) in ledger.entries where entry.uncertain {
                entry.uncertain = false
                entry.operationName = nil
                entry.operationType = nil
                ledger.entries[id] = entry
            }
            try save(ledger, subject: subject)
            needsReview = false
            await sync()
        } catch { status = "Could not retry: \(error.localizedDescription)" }
    }

    /// Keeps the ledger: reconnecting must not upload previously exported drinks twice.
    func disconnect() {
        guard !running else { return }
        auth.disconnect()
        account = nil
        hasClientSecret = false
        status = "Disconnected (local credentials removed; Google records were not deleted)"
    }

    func sync() async {
        guard !running, let subject = auth.credentials?.subject else { return }
        running = true
        syncing = true
        defer { running = false; syncing = false }
        do {
            var ledger = try loadLedger(subject: subject)
            try repository.assignDrinkIDs(since: ledger.cutoff)
            let drinks = try repository.exportableDrinks(since: ledger.cutoff)
            var local: [String: WaterRepository.Drink] = [:]
            for drink in drinks {
                guard let id = drink.id, local.updateValue(drink, forKey: id) == nil else {
                    throw SyncError.invalidLocalData
                }
            }
            for (id, drink) in local where ledger.entries[id] == nil {
                ledger.entries[id] = Entry(at: drink.at, ml: drink.ml)
            }
            try save(ledger, subject: subject)

            for id in ledger.entries.keys.sorted() {
                guard var entry = ledger.entries[id] else { continue }
                // Do not re-send a request whose outcome is unknown: duplicate health
                // records are worse than an explicit manual-reconciliation error.
                if entry.uncertain { continue }
                let exists = local[id] != nil
                if let operation = entry.operationName {
                    let result = try await request("GET", path: operation)
                    if result["done"] as? Bool != true { continue }
                    if let error = result["error"] {
                        entry.uncertain = true
                        ledger.entries[id] = entry
                        try save(ledger, subject: subject)
                        status = "Google operation failed: \(error). Review sync before retrying."
                        continue
                    }
                    if entry.operationType == "delete" {
                        ledger.entries.removeValue(forKey: id)
                        try save(ledger, subject: subject)
                        continue
                    }
                    guard let name = Self.dataPointName(in: result["response"] ?? result) else {
                        entry.uncertain = true
                        ledger.entries[id] = entry
                        try save(ledger, subject: subject)
                        continue
                    }
                    entry.remoteName = name
                    entry.operationName = nil
                    entry.operationType = nil
                    ledger.entries[id] = entry
                    try save(ledger, subject: subject)
                }
                guard var current = ledger.entries[id] else { continue }
                if !exists {
                    if let remote = current.remoteName {
                        do {
                            let result = try await request("POST", path:
                                "users/me/dataTypes/hydration-log/dataPoints:batchDelete",
                                body: ["names": [remote]])
                            guard let operation = result["name"] as? String else { throw SyncError.invalidResponse }
                            current.operationName = operation
                            current.operationType = "delete"
                            ledger.entries[id] = current
                        } catch {
                            current.uncertain = true
                            ledger.entries[id] = current
                            status = "Deletion needs review: \(error.localizedDescription)"
                        }
                    } else {
                        ledger.entries.removeValue(forKey: id) // unsent drink was undone
                    }
                } else if current.remoteName == nil && current.operationName == nil {
                    do {
                        let result = try await request("POST", path:
                            "users/me/dataTypes/hydration-log/dataPoints",
                            body: try Self.hydrationPayload(for: current))
                        guard let operation = result["name"] as? String else { throw SyncError.invalidResponse }
                        current.operationName = operation
                        current.operationType = "create"
                        ledger.entries[id] = current
                    } catch {
                        current.uncertain = true
                        ledger.entries[id] = current
                        status = "Upload outcome unknown; review Google data before retrying. \(error.localizedDescription)"
                    }
                }
                try save(ledger, subject: subject)
            }
            let reviews = ledger.entries.values.filter(\.uncertain).count
            needsReview = reviews > 0
            let pending = ledger.entries.values.filter { $0.operationName != nil }.count
            if reviews > 0 { status = "\(reviews) drink(s) need manual review; no automatic duplicate uploads" }
            else { status = "Sync checked • \(pending) operation(s) pending" }
        } catch {
            status = "Sync paused: \(error.localizedDescription)"
        }
    }

    private enum SyncError: LocalizedError {
        case invalidLocalData, invalidResponse, http(Int)
        var errorDescription: String? {
            switch self {
            case .invalidLocalData: return "Invalid or duplicate local drink IDs."
            case .invalidResponse: return "Unexpected Google Health response."
            case .http(let code): return "Google Health returned HTTP \(code)."
            }
        }
    }

    private func request(_ method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard !path.contains(".."),
              let url = URL(string: "https://health.googleapis.com/v4/\(path)") else {
            throw SyncError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.invalidResponse
        }
        return json
    }

    static func hydrationPayload(for entry: Entry) throws -> [String: Any] {
        guard let date = ISO8601DateFormatter().date(from: entry.at), entry.ml > 0 else {
            throw SyncError.invalidLocalData
        }
        let start = ISO8601DateFormatter().string(from: date)
        let end = ISO8601DateFormatter().string(from: date.addingTimeInterval(1))
        return ["hydrationLog": ["interval": ["startTime": start, "endTime": end],
                                 "amountConsumed": ["milliliters": entry.ml]]]
    }

    static func dataPointName(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let name = dictionary["name"] as? String,
               name.contains("/dataTypes/hydration-log/dataPoints/") { return name }
            for child in dictionary.values {
                if let result = dataPointName(in: child) { return result }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let result = dataPointName(in: child) { return result }
            }
        }
        return nil
    }

    private func ledgerURL(subject: String) throws -> URL {
        guard !subject.isEmpty, subject.allSatisfy({ $0.isNumber || $0.isLetter }) else {
            throw SyncError.invalidResponse
        }
        return repository.directory.appendingPathComponent("google-health-\(subject).json")
    }

    private func loadLedger(subject: String) throws -> Ledger {
        let url = try ledgerURL(subject: subject)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Ledger(cutoff: Date()) // Never silently backfill existing local history.
        }
        return try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
    }

    private func save(_ ledger: Ledger, subject: String) throws {
        let url = try ledgerURL(subject: subject)
        try FileManager.default.createDirectory(at: repository.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }
}
