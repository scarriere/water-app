import Darwin
import Foundation

/// Uses the same dated JSON files as water.py so the two apps share daily totals.
struct WaterRepository {
    static let glassML = 355
    static let goalML = 2_700
    static let bottleML = 3_000
    static let hourlyMinimumML = 250

    struct Drink: Codable, Equatable {
        let at: String // ISO-8601 UTC timestamp, shared with water.py
        let ml: Int
        let id: String? // UUID; nil for drinks created before Google Health sync existed

        init(at: String, ml: Int, id: String? = nil) {
            self.at = at
            self.ml = ml
            self.id = id
        }
    }

    struct DayRecord: Codable, Equatable {
        let date: String
        let ml: Int
        let drinks: [Drink]

        init(date: String, ml: Int, drinks: [Drink] = []) {
            self.date = date
            self.ml = ml
            self.drinks = drinks
        }

        // Older CLI files only have date + ml; retain their total without inventing timestamps.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(String.self, forKey: .date)
            ml = try container.decode(Int.self, forKey: .ml)
            drinks = try container.decodeIfPresent([Drink].self, forKey: .drinks) ?? []
        }
    }

    enum WaterError: LocalizedError {
        case invalidData(URL)

        var errorDescription: String? {
            switch self {
            case .invalidData(let url):
                return "Invalid water data in \(url.path). The file was not changed."
            }
        }
    }

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let environment = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            let base = environment.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/state", isDirectory: true)
            self.directory = base.appendingPathComponent("water-cli", isDirectory: true)
        }
    }

    func dayKey(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    func fileURL(for day: Date) -> URL {
        directory.appendingPathComponent("\(dayKey(for: day)).json")
    }

    func loadRecord(on day: Date) throws -> DayRecord {
        let url = fileURL(for: day)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DayRecord(date: dayKey(for: day), ml: 0)
        }
        let data = try Data(contentsOf: url)
        guard let record = try? JSONDecoder().decode(DayRecord.self, from: data),
              record.date == dayKey(for: day), record.ml >= 0 else {
            throw WaterError.invalidData(url)
        }
        let parser = ISO8601DateFormatter()
        var logged = 0
        var ids = Set<String>()
        for drink in record.drinks {
            guard drink.ml > 0, drink.ml <= record.ml - logged,
                  parser.date(from: drink.at) != nil else {
                throw WaterError.invalidData(url)
            }
            if let id = drink.id {
                guard UUID(uuidString: id) != nil, ids.insert(id).inserted else {
                    throw WaterError.invalidData(url)
                }
            }
            logged += drink.ml
        }
        return record
    }

    func load(on day: Date) throws -> Int {
        try loadRecord(on: day).ml
    }

    /// Sum logged drinks in a time interval, including an interval spanning midnight.
    /// Legacy totals have no timestamps, so they cannot be attributed to a particular hour.
    func consumed(from start: Date, to end: Date) throws -> Int {
        guard end > start else { return 0 }
        let first = try loadRecord(on: start)
        let lastDay = end.addingTimeInterval(-0.001)
        let records = dayKey(for: start) == dayKey(for: lastDay)
            ? [first] : [first, try loadRecord(on: lastDay)]
        let parser = ISO8601DateFormatter()
        return records.flatMap(\.drinks).reduce(0) { total, drink in
            guard let at = parser.date(from: drink.at), at >= start, at < end else { return total }
            return total + drink.ml
        }
    }

    func needsReminder(at now: Date) throws -> Bool {
        try consumed(from: now.addingTimeInterval(-3_600), to: now) < Self.hourlyMinimumML
    }

    /// Re-read before adding in case the Python CLI updated today's file while the app was open.
    @discardableResult
    func addGlass(on day: Date) throws -> Int {
        try withDayLock(on: day) {
            let record = try loadRecord(on: day)
            guard record.ml <= Int.max - Self.glassML else {
                throw WaterError.invalidData(fileURL(for: day))
            }
            let newTotal = record.ml + Self.glassML
            let drink = Drink(at: ISO8601DateFormatter().string(from: day), ml: Self.glassML,
                              id: UUID().uuidString.lowercased())
            let updated = DayRecord(date: record.date, ml: newTotal, drinks: record.drinks + [drink])
            try save(updated, on: day)
            return newTotal
        }
    }

    /// Undo the most recent logged 355 ml glass, falling back to untimed legacy water.
    /// Never remove a different-sized drink or write a negative total.
    @discardableResult
    func removeGlass(on day: Date) throws -> Int? {
        try withDayLock(on: day) {
            let record = try loadRecord(on: day)
            guard record.ml >= Self.glassML else { return nil }
            var drinks = record.drinks
            if let index = drinks.lastIndex(where: { $0.ml == Self.glassML }) {
                drinks.remove(at: index)
            } else {
                let logged = drinks.reduce(0) { $0 + $1.ml }
                guard record.ml - logged >= Self.glassML else { return nil }
            }
            let newTotal = record.ml - Self.glassML
            try save(DayRecord(date: record.date, ml: newTotal, drinks: drinks), on: day)
            return newTotal
        }
    }

    /// Give eligible old CLI/app drinks identities under the same cross-process day lock.
    /// Untimed legacy totals cannot be assigned a real time and remain local-only.
    func assignDrinkIDs(since start: Date) throws {
        for date in try datedFiles() {
            try withDayLock(on: date) {
                let record = try loadRecord(on: date)
                var changed = false
                let drinks = record.drinks.map { drink -> Drink in
                    guard drink.id == nil, let at = ISO8601DateFormatter().date(from: drink.at),
                          at >= start else { return drink }
                    changed = true
                    return Drink(at: drink.at, ml: drink.ml, id: UUID().uuidString.lowercased())
                }
                if changed {
                    try save(DayRecord(date: record.date, ml: record.ml, drinks: drinks), on: date)
                }
            }
        }
    }

    /// Re-read every dated file so CLI changes and removals are picked up even while Water is open.
    func exportableDrinks(since start: Date) throws -> [Drink] {
        var result: [Drink] = []
        for date in try datedFiles() {
            let record = try loadRecord(on: date)
            result += record.drinks.filter { $0.id != nil &&
                (ISO8601DateFormatter().date(from: $0.at) ?? .distantPast) >= start }
        }
        return result
    }

    private func datedFiles() throws -> [Date] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return names.compactMap { name in
            guard name.range(of: #"^\d{4}-\d{2}-\d{2}\.json$"#,
                             options: .regularExpression) != nil else { return nil }
            let key = String(name.dropLast(5))
            guard let date = formatter.date(from: key), dayKey(for: date) == key else { return nil }
            return date
        }
    }

    private func withDayLock<T>(on day: Date, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = fileURL(for: day).deletingPathExtension().appendingPathExtension("lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func save(_ record: DayRecord, on day: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL(for: day), options: .atomic)
    }
}
