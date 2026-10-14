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
        var rejectedStatus: Int? // A definite HTTP rejection; unlike a lost response, safe to retry later.
        var lastFailure: String? // Safe diagnostic only; never store response bodies or credentials.
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
    @Published private(set) var hasRejectedUploads = false
    @Published private(set) var hasReadPermission = false
    @Published private(set) var googleDrinks: [GoogleHealthRemoteDrink] = []
    @Published private(set) var googleListStatus = "Connect to see Google records"
    @Published private(set) var isRefreshingGoogle = false
    @Published private(set) var queuedCount = 0
    @Published private(set) var uncertainCount = 0

    private let repository: WaterRepository
    private let auth = GoogleHealthAuth()
    private var timer: Timer?
    private var running = false

    init(repository: WaterRepository = WaterRepository()) {
        self.repository = repository
        account = auth.credentials?.email
        hasClientSecret = auth.hasClientSecret
        hasReadPermission = auth.hasReadPermission
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
            hasReadPermission = auth.hasReadPermission
            googleDrinks = [] // Never display another account's previously fetched health data.
            googleListStatus = "Reading Google hydration logs…"
            status = "Connected; syncing new drinks"
            running = false
            await sync()
            await refreshGoogleDrinks()
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
                entry.lastFailure = nil
                entry.operationName = nil
                entry.operationType = nil
                ledger.entries[id] = entry
            }
            try save(ledger, subject: subject)
            needsReview = false
            await sync()
        } catch { status = "Could not retry: \(error.localizedDescription)" }
    }

    /// Definite 400/401/403 responses did not create records. Retry only after fixing access.
    func retryRejected() async {
        guard !running, let subject = auth.credentials?.subject else { return }
        do {
            var ledger = try loadLedger(subject: subject)
            for (id, var entry) in ledger.entries where entry.rejectedStatus != nil {
                entry.rejectedStatus = nil
                ledger.entries[id] = entry
            }
            try save(ledger, subject: subject)
            hasRejectedUploads = false
            await sync()
        } catch { status = "Could not retry rejected uploads: \(error.localizedDescription)" }
    }

    /// Keeps the ledger: reconnecting must not upload previously exported drinks twice.
    func disconnect() {
        guard !running else { return }
        auth.disconnect()
        account = nil
        hasClientSecret = false
        hasReadPermission = false
        googleDrinks = []
        googleListStatus = "Connect to see Google records"
        queuedCount = 0
        uncertainCount = 0
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
            updateCounts(ledger)
            if let code = ledger.entries.values.compactMap(\.rejectedStatus).first {
                hasRejectedUploads = true
                needsReview = ledger.entries.values.contains(where: \.uncertain)
                status = "Google Health rejected an upload (HTTP \(code)). Export paused; check API access, then retry."
                return
            }
            let unresolved = ledger.entries.values.filter(\.uncertain)
            if !unresolved.isEmpty {
                needsReview = true
                status = Self.reviewStatus(for: unresolved)
                return // Never submit more drinks while an earlier outcome is unknown.
            }

            for id in ledger.entries.keys.sorted() {
                guard var entry = ledger.entries[id] else { continue }
                // Do not re-send a request whose outcome is unknown: duplicate health
                // records are worse than an explicit manual-reconciliation error.
                if entry.uncertain { continue }
                let exists = local[id] != nil
                if let operation = entry.operationName {
                    let result = try await request("GET", path: operation)
                    if result["done"] as? Bool != true { continue }
                    if result["error"] != nil {
                        entry.uncertain = true
                        entry.lastFailure = "Google reported a failed operation"
                        ledger.entries[id] = entry
                        try save(ledger, subject: subject)
                        break
                    }
                    if entry.operationType == "delete" {
                        ledger.entries.removeValue(forKey: id)
                        try save(ledger, subject: subject)
                        continue
                    }
                    guard let name = Self.dataPointName(in: result["response"] ?? result) else {
                        entry.uncertain = true
                        entry.lastFailure = "Google operation completed without a data-point ID"
                        ledger.entries[id] = entry
                        try save(ledger, subject: subject)
                        break
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
                            current.lastFailure = Self.safeSyncError(error)
                            ledger.entries[id] = current
                            try save(ledger, subject: subject)
                            break
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
                    } catch let SyncError.http(code) where Self.isDefinitiveRejection(code) {
                        current.rejectedStatus = code
                        ledger.entries[id] = current
                        try save(ledger, subject: subject)
                        break // Do not try every historical drink against the same rejected API.
                    } catch {
                        current.uncertain = true
                        current.lastFailure = Self.safeSyncError(error)
                        ledger.entries[id] = current
                        try save(ledger, subject: subject)
                        break // Do not submit the remaining historical drinks after one unknown result.
                    }
                }
                try save(ledger, subject: subject)
            }
            let reviews = ledger.entries.values.filter(\.uncertain).count
            updateCounts(ledger)
            hasRejectedUploads = ledger.entries.values.contains { $0.rejectedStatus != nil }
            needsReview = reviews > 0
            let pending = ledger.entries.values.filter { $0.operationName != nil }.count
            if let code = ledger.entries.values.compactMap(\.rejectedStatus).first {
                status = "Google Health rejected an upload (HTTP \(code)). Export paused; check API access, then retry."
            } else if reviews > 0 {
                status = Self.reviewStatus(for: ledger.entries.values.filter(\.uncertain))
            } else { status = "Sync checked • \(pending) operation(s) pending" }
        } catch {
            status = "Sync paused: \(error.localizedDescription)"
        }
    }

    /// Query Google without writing anything. Show only matches to Water's own local
    /// exports; a timestamp/volume match without a saved remote ID is marked possible.
    func refreshGoogleDrinks() async {
        guard !isRefreshingGoogle, let subject = auth.credentials?.subject else { return }
        guard auth.hasReadPermission else {
            hasReadPermission = false
            googleListStatus = "Google nutrition read permission needed. Add it to the OAuth app and choose Grant read access."
            return
        }
        isRefreshingGoogle = true
        googleListStatus = "Reading Google hydration logs…"
        defer { isRefreshingGoogle = false }
        do {
            var all: [GoogleHealthRemote.Record] = []
            var pageToken: String?
            var more = false
            for _ in 0..<10 { // bounded: no unbounded health-history download
                var components = URLComponents()
                components.queryItems = [URLQueryItem(name: "pageSize", value: "100")]
                if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                let path = "users/me/dataTypes/hydration-log/dataPoints?\(components.percentEncodedQuery ?? "")"
                let page = try GoogleHealthRemote.page(try await request("GET", path: path))
                all += page.records
                pageToken = page.nextPageToken
                more = pageToken?.isEmpty == false
                if !more { break }
            }
            let ledger = try loadLedger(subject: subject)
            googleDrinks = GoogleHealthRemote.matchingWaterDrinks(all, entries: Array(ledger.entries.values))
            let possible = googleDrinks.filter { $0.confidence == .possible }.count
            googleListStatus = "Google returned \(all.count) hydration record(s); \(googleDrinks.count - possible) confirmed Water, \(possible) possible Water match(es)\(more ? "; more pages exist" : "")"
        } catch let SyncError.http(code) {
            googleListStatus = "Google hydration list failed (HTTP \(code)). Check nutrition read permission and API access."
        } catch {
            googleListStatus = "Could not read Google hydration logs: \(error.localizedDescription)"
        }
    }

    private func updateCounts(_ ledger: Ledger) {
        uncertainCount = ledger.entries.values.filter(\.uncertain).count
        queuedCount = ledger.entries.values.filter { !$0.uncertain && $0.remoteName == nil && $0.operationName == nil }.count
    }

    static func isDefinitiveRejection(_ status: Int) -> Bool {
        [400, 401, 403, 404, 405].contains(status)
    }

    static func reviewStatus(for entries: [Entry]) -> String {
        let detail = entries.compactMap(\.lastFailure).first ?? "no error saved by the earlier version"
        return "\(entries.count) drink(s) need manual review. Last failure: \(detail). Check Google for duplicates before retrying."
    }

    private static func safeSyncError(_ error: Error) -> String {
        if let error = error as? SyncError { return error.localizedDescription }
        if let error = error as? URLError { return "Network error (\(error.code.rawValue))" }
        return "Upload outcome unknown (network or response error)"
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
